import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:photo_manager/photo_manager.dart';

import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import '../upload/backup_verifier.dart';
import 'asset_removal.dart' show originalStands;
import 'asset_takeover.dart';
import 'file_hash.dart';
import 'image_pipeline.dart';
import 'photo_library_service.dart';
import 'smaller_export.dart';
import 'storage_advice.dart';
import 'thumbnail_cache.dart';

/// What a fix is doing right now, for the line under the progress bar.
enum FixAction {
  optimizing,
  downloading,
  uploading,
  deleting,
  renaming,
  adding,
  converting,

  /// Waiting on the iOS prompt that deletes from Photos.
  confirming,
}

/// What one round of fixes actually did. Separate counts rather than a
/// single "done": queuing a backup frees nothing today, and an asset that
/// couldn't be touched has to say so rather than quietly not appear.
class StorageFixResult {
  const StorageFixResult({
    this.freedBytes = 0,
    this.queuedForBackup = 0,
    this.skipped = 0,
    this.unverified = 0,
  });

  final int freedBytes;
  final int queuedForBackup;
  final int skipped;

  /// Left alone because the bucket could not confirm it has the photo —
  /// separate from [skipped], because this one is news: either the backup
  /// isn't what this app believed, or it couldn't be reached to ask.
  final int unverified;
}

/// How one item of an [StorageOptimizer.apply] round ended.
enum StorageItemOutcome { freed, queued, skipped, unverified }

/// Carries out what `storage_advice.dart` suggested.
///
/// The two re-encodes replace the local copy in place. That is only safe
/// because they're offered for backed-up assets alone — the bucket keeps
/// the full-quality original, and "Download Original" pulls it back. It's
/// the same trade as Remove from Device, just keeping something viewable
/// on the phone.
class StorageOptimizer {
  StorageOptimizer({
    required this.store,
    required this.thumbnails,
    required this.library,
    required this.backUp,
    this.verifier,
    Future<(Uint8List, int, int)?> Function(Uint8List bytes, int? maxEdge)?
    encode,
    LibraryWriter? writer,
  }) : _encode = encode ?? _defaultEncode,
       _writer = writer ?? const LibraryWriter();

  final LibraryWriter _writer;

  static const _rewrites = {StorageFix.optimize};

  final AssetRecordStore store;
  final ThumbnailCache thumbnails;
  final PhotoLibraryService library;

  /// Queues uploads through the library screen's own sync queue, so a
  /// backup started here is the same backup as any other.
  final Future<void> Function(List<AssetRecord> records) backUp;

  /// Asked once per [apply], not once per photo: a [BackupVerifier.reconcile]
  /// over a library of thirty thousand is thirty listings, where a HEAD each
  /// would be thirty thousand requests.
  ///
  /// Null skips the check — for tests, and only for tests. Anything holding
  /// somebody's photos passes one, because every fix below either deletes
  /// the local original or overwrites it with a smaller one, on the strength
  /// of a backup this app has never confirmed exists.
  final BackupVerifier? verifier;

  /// Overridable for tests so they never decode a real image.
  final Future<(Uint8List, int, int)?> Function(Uint8List bytes, int? maxEdge)
  _encode;

  static Future<(Uint8List, int, int)?> _defaultEncode(
    Uint8List bytes,
    int? maxEdge,
  ) => Isolate.run(() => optimizeStill(bytes, maxEdge: maxEdge));

  /// [onItem] hears each item's own outcome as it lands, for a caller that
  /// shows a queue draining rather than one answer at the end.
  ///
  /// [onPrepared] fires as each smaller copy is made, before the batch's one
  /// iOS prompt decides it — the slow part, which would otherwise show no
  /// progress at all.
  Future<StorageFixResult> apply(
    List<StorageItem> items, {
    void Function(String localId, StorageItemOutcome outcome)? onItem,
    void Function(String localId)? onPrepared,
    void Function(String localId, FixAction action)? onStep,
    bool deferDeletes = false,
  }) async {
    _onStep = onStep;
    _onPrepared = onPrepared;
    _defer = deferDeletes;
    var freed = 0;
    var skipped = 0;
    var unverified = 0;
    void report(StorageItem item, StorageItemOutcome outcome) =>
        onItem?.call(item.record.localId, outcome);

    final work = <StorageItem>[];
    for (final item in items) {
      if (_offLimits(item.record)) {
        skipped++;
        report(item, StorageItemOutcome.skipped);
      } else {
        work.add(item);
      }
    }

    final toBackUp = [
      for (final item in work)
        if (item.fix == StorageFix.backUpFirst) item,
    ];
    if (toBackUp.isNotEmpty) {
      await backUp([for (final item in toBackUp) item.record]);
      for (final item in toBackUp) {
        report(item, StorageItemOutcome.queued);
      }
    }

    final unconfirmed = await _unconfirmed(work);

    final inLibrary = <StorageItem>[];
    for (final item in work) {
      if (!_rewrites.contains(item.fix)) continue;
      // The re-encodes replace the local copy, which is only safe while the
      // bucket holds the full-quality original they're throwing away.
      if (_requeued.contains(item.record.localId)) {
        report(item, StorageItemOutcome.queued);
        continue;
      }
      if (unconfirmed.contains(item.record.localId)) {
        unverified++;
        report(item, StorageItemOutcome.unverified);
        continue;
      }
      if (item.record.sourcePath == null) {
        inLibrary.add(item);
        continue;
      }
      _step(item, FixAction.optimizing);
      final saved = _compressesVideo(item)
          ? await _compressOwned(item)
          : await _rewrite(item);
      if (saved == null) {
        skipped++;
        report(item, StorageItemOutcome.skipped);
      } else {
        freed += saved;
        report(item, StorageItemOutcome.freed);
      }
    }
    for (var i = 0; i < inLibrary.length; i += deleteChunk) {
      final replaced = await _replaceInLibrary(
        inLibrary.skip(i).take(deleteChunk).toList(),
        report,
        onPrepared,
      );
      freed += replaced.freedBytes;
      skipped += replaced.skipped;
    }

    final removable = <StorageItem>[];
    for (final item in work) {
      if (item.fix != StorageFix.removeFromDevice) continue;
      if (unconfirmed.contains(item.record.localId)) {
        unverified++;
        report(item, StorageItemOutcome.unverified);
      } else {
        removable.add(item);
      }
    }
    final removal = await _removeFromDevice(removable, report);
    freed += removal.freedBytes;
    skipped += removal.skipped;

    final dupes = await _removeDuplicates([
      for (final item in work)
        if (item.fix == StorageFix.removeDuplicate) item,
    ], report);
    freed += dupes.freedBytes;
    skipped += dupes.skipped;
    unverified += dupes.unverified;

    return StorageFixResult(
      freedBytes: freed,
      queuedForBackup: toBackUp.length,
      skipped: skipped,
      unverified: unverified,
    );
  }

  /// Which of [items]' photos the bucket could not be shown to hold.
  ///
  /// An unreachable bucket puts *every* destructive fix in here rather than
  /// none: "we couldn't check" and "it's fine" are not the same answer, and
  /// freeing space is never urgent enough to guess. Only the two fixes that
  /// destroy a local original are asked about — queueing a backup is safe
  /// whatever the bucket says.
  Set<String> _requeued = const {};

  Future<Set<String>> _unconfirmed(List<StorageItem> items) async {
    _requeued = const {};
    final verifier = this.verifier;
    if (verifier == null) return const {};
    final atRisk = {
      for (final item in items)
        if (item.fix == StorageFix.removeFromDevice ||
            _rewrites.contains(item.fix))
          item.record.localId,
    };
    if (atRisk.isEmpty) return const {};
    try {
      final report = await verifier.reconcile();
      if (!report.reachedBucket) return atRisk;
      // Missing from the bucket: back in the queue now, not on the next
      // daily check, or it is offered again and refused again meanwhile.
      if (!report.isClean) {
        await verifier.repair(report);
        _requeued = {
          for (final id in report.missingLocalIds)
            if (atRisk.contains(id)) id,
        };
      }
      // A removal leaves the bucket's thumbnail as the only picture once the
      // cache is gone, so a missing one blocks it too; the re-encodes keep a
      // local file and don't care.
      final removing = {
        for (final item in items)
          if (item.fix == StorageFix.removeFromDevice) item.record.localId,
      };
      return {
        ...atRisk.intersection(report.missingLocalIds.toSet()),
        ...removing.intersection(report.missingThumbnailIds.toSet()),
      };
    } catch (_) {
      return atRisk;
    }
  }

  /// Returns the bytes saved, or null if nothing was written.
  Future<int?> _rewrite(StorageItem item) async {
    final path = item.record.sourcePath;
    if (path == null) return null;
    try {
      final file = File(path);
      final before = await file.length();
      final encoded = await _encode(
        await file.readAsBytes(),
        item.fix == StorageFix.optimize ? optimizedMaxEdge : null,
      );
      if (encoded == null) return null;
      final (bytes, width, height) = encoded;
      // A re-encode that grew the file isn't an optimization.
      if (bytes.length >= before) return null;

      final hash = hashBytes(bytes);
      final target = File(p.join(p.dirname(path), '$hash.webp'));
      await target.writeAsBytes(bytes);
      if (target.path != path) {
        try {
          await file.delete();
        } catch (_) {
          // Already gone; the record points at the new file either way.
        }
      }

      await store.setSourcePath(item.record.localId, target.path);
      // What is on the device is no longer the original. The backed-up hash
      // is left as it was, so the next change check sees the smaller file
      // and sends it to the bucket too — optimized is optimized everywhere.
      await store.setLocalOptimized(item.record.localId, true);
      await store.setLibraryMetadata(
        item.record.localId,
        width: width,
        height: height,
      );
      return before - bytes.length;
    } catch (_) {
      // Undecodable, unwritable, or the file moved mid-pass — the asset
      // keeps the copy it had.
      return null;
    }
  }

  /// One iOS confirmation takes this many originals out of Photos.
  static const deleteChunk = PhotoLibraryService.deleteBatchLimit;

  /// Exact copies into Recently Deleted, like any delete: the kept copy is
  /// untouched and the bin can still bring one back. Camera-roll ones leave
  /// Photos too, one iOS prompt per batch.
  ///
  /// Only where the kept copy is shown, live, to still have its original;
  /// the rest are reported unverified and left alone.
  Future<StorageFixResult> _removeDuplicates(
    List<StorageItem> candidates,
    void Function(StorageItem item, StorageItemOutcome outcome) report,
  ) async {
    var freed = 0;
    var skipped = 0;
    final items = await _withKeeper(candidates, report);
    bool inLibrary(StorageItem i) =>
        i.record.sourceType == AssetSourceType.photoManager &&
        !i.record.localDeleted &&
        PhotoLibraryService.libraryIdOf(i.record) != null;
    final fromLibrary = items.where(inLibrary).toList();
    if (_defer && fromLibrary.isNotEmpty) {
      for (final item in fromLibrary) {
        await store.fileSwap(
          PendingSwap(
            localId: item.record.localId,
            oldAsset: item.record.libraryId!,
            keeperId: item.keptId,
            oldBytes: item.bytes,
          ),
        );
        _onPrepared?.call(item.record.localId);
      }
      fromLibrary.clear();
    }
    if (fromLibrary.isNotEmpty) _step(fromLibrary.first, FixAction.confirming);
    final gone = <String>{};
    for (var i = 0; i < fromLibrary.length; i += deleteChunk) {
      try {
        gone.addAll(
          await library.deleteManyFromLibrary([
            for (final item in fromLibrary.skip(i).take(deleteChunk))
              item.record,
          ]),
        );
      } catch (_) {
        // Declined or failed: those stay, and are listed again.
      }
    }
    for (final item in items) {
      if (inLibrary(item) && _defer) continue;
      if (inLibrary(item) && !gone.contains(item.record.localId)) {
        skipped++;
        report(item, StorageItemOutcome.skipped);
        continue;
      }
      await store.softDelete(item.record.localId);
      freed += item.bytes;
      report(item, StorageItemOutcome.freed);
    }
    return StorageFixResult(
      freedBytes: freed,
      skipped: skipped,
      unverified: candidates.length - items.length,
    );
  }

  Future<List<StorageItem>> _withKeeper(
    List<StorageItem> items,
    void Function(StorageItem item, StorageItemOutcome outcome) report,
  ) async {
    if (items.isEmpty) return items;
    final kept = await store.getByLocalIds(items.map((i) => i.keptId).nonNulls);
    final proven = <String, bool>{};
    final out = <StorageItem>[];
    for (final item in items) {
      final keeper = kept[item.keptId];
      final stands =
          keeper != null &&
          (proven[keeper.localId] ??= await originalStands(
            keeper,
            library: library,
            verifier: verifier,
          ));
      if (stands) {
        out.add(item);
      } else {
        report(item, StorageItemOutcome.unverified);
      }
    }
    return out;
  }

  /// A camera-roll asset can't be rewritten in place — PhotoKit owns its
  /// bytes. So the smaller copy goes into Photos with the original's date,
  /// a Live Photo with its own `.mov`, and the original is deleted in one
  /// prompt for the batch. The record moves over to the new asset, so its
  /// tags, people and backup stay attached. Declined at the prompt: the new
  /// copies are taken back out, and nothing changed.
  Future<StorageFixResult> _replaceInLibrary(
    List<StorageItem> items,
    void Function(StorageItem item, StorageItemOutcome outcome) report,
    void Function(String localId)? onPrepared,
  ) async {
    var freed = 0;
    var skipped = 0;
    final made = <StorageItem, (AssetEntity, File)>{};
    // One swap per photo: a second copy would be left in Photos unclaimed,
    // and sync would bring it back as a new photo.
    final filed = _defer ? await _filedIds() : <String>{};
    for (final item in items) {
      if (filed.contains(item.record.localId)) {
        onPrepared?.call(item.record.localId);
        continue;
      }
      if (item.record.libraryId == null) {
        skipped++;
        report(item, StorageItemOutcome.skipped);
        continue;
      }
      _step(item, FixAction.optimizing);
      final result = await _smallerCopyInLibrary(item);
      if (result == null) {
        skipped++;
        report(item, StorageItemOutcome.skipped);
      } else {
        made[item] = result;
        filed.add(item.record.localId);
        // Filed the moment the copy exists: a run cut short must not leave
        // it in Photos beside its original with nothing to say so.
        if (_defer) {
          final (asset, file) = result;
          final filedNow = await store.fileSwap(
            PendingSwap(
              localId: item.record.localId,
              oldAsset: item.record.libraryId!,
              newAsset: asset.id,
              width: asset.width,
              height: asset.height,
              oldBytes: item.bytes,
              newBytes: await file.length(),
            ),
          );
          // Filed meanwhile by another run: one copy per photo.
          if (!filedNow) await _writer.delete([asset.id]);
        }
        onPrepared?.call(item.record.localId);
      }
    }
    if (made.isEmpty) return StorageFixResult(skipped: skipped);
    if (_defer) {
      for (final (_, file) in made.values) {
        try {
          await file.delete();
        } catch (_) {}
      }
      return StorageFixResult(skipped: skipped);
    }

    Set<String> gone;
    _step(made.keys.first, FixAction.confirming);
    try {
      gone = await library.deleteManyFromLibrary([
        for (final item in made.keys) item.record,
      ]);
    } catch (_) {
      gone = const {};
    }
    final orphans = <String>[];
    for (final MapEntry(key: item, value: (asset, file)) in made.entries) {
      final id = item.record.localId;
      if (!gone.contains(id)) {
        orphans.add(asset.id);
        skipped++;
        report(item, StorageItemOutcome.skipped);
        continue;
      }
      final size = await file.length();
      await takeOverAsset(
        store,
        id,
        asset.id,
        width: asset.width,
        height: asset.height,
        optimized: true,
      );
      freed += item.bytes > size ? item.bytes - size : 0;
      report(item, StorageItemOutcome.freed);
    }
    if (orphans.isNotEmpty) await _writer.delete(orphans);
    for (final (_, file) in made.values) {
      try {
        await file.delete();
      } catch (_) {
        // Temp; the OS reclaims it.
      }
    }
    return StorageFixResult(freedBytes: freed, skipped: skipped);
  }

  void Function(String localId, FixAction action)? _onStep;

  /// Set by [apply]: the originals a run replaces or removes from Photos
  /// are filed (`pending_swap`) rather than deleted, and [finishSwaps] asks
  /// for all of them in one iOS prompt.
  bool _defer = false;
  void Function(String localId)? _onPrepared;

  /// Originals waiting on that one prompt. A row each, so a quit keeps
  /// them and two jobs filing at once can't drop each other's.
  Future<List<PendingSwap>> pendingSwaps() => store.pendingSwaps();

  Future<Set<String>> _filedIds() async => {
    for (final s in await store.pendingSwaps()) s.localId,
  };

  /// Not to be touched by a fix, whatever the scan said: hidden, locked or
  /// binned since.
  static bool _offLimits(AssetRecord r) =>
      r.isDeleted || r.isLocked || r.isHidden || r.passcodeHash != null;

  /// The one prompt: every filed original out of Photos at once. A
  /// replaced photo moves over to its smaller copy; a duplicate goes to
  /// Recently Deleted.
  ///
  /// Each swap is checked again right before: the record still on the
  /// asset it was filed with and not hidden, locked or binned; never an
  /// asset another swap moves onto or a kept copy holds; a replacement's
  /// copy still in Photos and its original live in a bucket; a removal's
  /// kept copy still standing. A bucket that doesn't answer leaves the swap
  /// filed for later. Each one done is closed in the same write that moves
  /// the record, so a kill anywhere resumes forward.
  Future<StorageFixResult> finishSwaps({
    void Function(PendingSwap swap, StorageItemOutcome outcome)? onItem,
  }) async {
    final swaps = await store.pendingSwaps();
    if (swaps.isEmpty) return const StorageFixResult();
    final records = await store.getByLocalIds([
      for (final s in swaps) ...[s.localId, ?s.keeperId],
    ]);
    final movingOnto = {for (final s in swaps) ?s.newAsset};
    final kept = {for (final s in swaps) ?records[s.keeperId]?.libraryId};
    final orphans = <String>[];
    final closed = <String>[];
    final ready = <PendingSwap>[];
    var unverified = 0;
    var skipped = 0;

    void close(PendingSwap s, StorageItemOutcome outcome) {
      closed.add(s.localId);
      if (s.newAsset case final copy? when !s.keepNew) orphans.add(copy);
      onItem?.call(s, outcome);
    }

    final asking = <PendingSwap>[];
    for (final s in swaps) {
      final r = records[s.localId];
      if (r == null ||
          _offLimits(r) ||
          r.libraryId != s.oldAsset ||
          s.newAsset == s.oldAsset ||
          movingOnto.contains(s.oldAsset) ||
          kept.contains(s.oldAsset)) {
        skipped++;
        close(s, StorageItemOutcome.skipped);
      } else {
        asking.add(s);
      }
    }
    // A few round trips at a time, not one after another.
    for (var i = 0; i < asking.length; i += _proveAtOnce) {
      final chunk = asking.skip(i).take(_proveAtOnce).toList();
      final proofs = await Future.wait([
        for (final s in chunk) _proveSwap(s, records[s.localId]!, records),
      ]);
      for (final (j, s) in chunk.indexed) {
        switch (proofs[j]) {
          case CopyProof.present:
            ready.add(s);
          case CopyProof.unreachable:
            unverified++;
            onItem?.call(s, StorageItemOutcome.unverified);
          case _:
            unverified++;
            close(s, StorageItemOutcome.unverified);
        }
      }
    }
    if (ready.isNotEmpty) {
      await store.markSwapsProved([for (final s in ready) s.localId]);
    }

    Set<String> gone;
    try {
      gone = ready.isEmpty
          ? <String>{}
          : {
              ...await library.deleteManyFromLibrary([
                for (final s in ready) records[s.localId]!,
              ], limit: ready.length + 1),
            };
    } catch (_) {
      gone = <String>{};
    }
    // Deleted before a kill: Photos no longer has it, which only full
    // access can say.
    final left = [
      for (final s in ready)
        if (!gone.contains(s.localId)) s,
    ];
    if (left.isNotEmpty && await library.hasFullAccess()) {
      for (final s in left) {
        if (await library.hasAsset(s.oldAsset) == false) gone.add(s.localId);
      }
    }

    var freed = 0;
    for (final s in ready) {
      if (!gone.contains(s.localId)) {
        skipped++;
        close(s, StorageItemOutcome.skipped);
        continue;
      }
      if (s.newAsset case final copy?) {
        final moved = await takeOverAsset(
          store,
          s.localId,
          copy,
          width: s.width,
          height: s.height,
          optimized: true,
          closeSwap: true,
        );
        if (!moved) {
          // The copy is held by a hidden or locked photo: the original is
          // gone, its bucket copy proven; sync makes it cloud-only.
          closed.add(s.localId);
          skipped++;
          onItem?.call(s, StorageItemOutcome.skipped);
          continue;
        }
        if (s.oldBytes > s.newBytes) freed += s.oldBytes - s.newBytes;
      } else {
        await store.binSwapped(s.localId);
        freed += s.oldBytes;
      }
      onItem?.call(s, StorageItemOutcome.freed);
    }
    if (closed.isNotEmpty) await store.dropSwaps(closed);
    // Never an asset some record is on: that one is a photo, not a spare.
    final spare = [
      for (final id in orphans.toSet())
        if (await store.getByLibraryId(id) == null) id,
    ];
    if (spare.isNotEmpty) await _writer.delete(spare);
    return StorageFixResult(
      freedBytes: freed,
      skipped: skipped,
      unverified: unverified,
    );
  }

  static const _proveAtOnce = 8;

  /// Whether a verified copy stands right now, for [s]'s delete to be safe.
  /// [CopyProof.unreachable] when that can't be told.
  Future<CopyProof> _proveSwap(
    PendingSwap s,
    AssetRecord r,
    Map<String, AssetRecord> records,
  ) async {
    if (s.newAsset case final copy?) {
      switch (await library.hasAsset(copy)) {
        case false:
          return CopyProof.missing;
        case null:
          return CopyProof.unreachable;
        case true:
      }
      return _proveOriginal(r);
    }
    final keeperId = s.keeperId;
    if (keeperId == null) return _proveOriginal(r);
    final keeper = records[keeperId];
    if (keeper == null || keeper.libraryId == s.oldAsset) {
      return CopyProof.missing;
    }
    return await originalStands(keeper, library: library, verifier: verifier)
        ? CopyProof.present
        : CopyProof.missing;
  }

  Future<CopyProof> _proveOriginal(AssetRecord r) async {
    final verifier = this.verifier;
    if (verifier == null) return CopyProof.unreachable;
    try {
      return switch (await verifier.proveOriginal(r)) {
        CopyProof.notRecorded => CopyProof.missing,
        final proof => proof,
      };
    } catch (_) {
      return CopyProof.unreachable;
    }
  }

  /// Files the Photos copy [copy] of [keeper] (the record moves onto it,
  /// the original goes) and [extras], more copies of it, for [finishSwaps].
  /// [flag] is the fix-queue flag the outcome is reported under. Returns
  /// how many are filed, counting any filed before.
  Future<int> fileFoundCopies(
    AssetRecord keeper, {
    AssetRecord? copy,
    List<AssetRecord> extras = const [],
    String? flag,
  }) async {
    var count = 0;
    // Refused only when that record has a swap filed already: filed either
    // way, and one swap per record.
    Future<void> file(PendingSwap swap) async {
      await store.fileSwap(swap);
      count++;
    }

    final from = keeper.libraryId;
    if (copy?.libraryId case final to? when from != null && to != from) {
      await file(
        PendingSwap(
          localId: keeper.localId,
          oldAsset: from,
          newAsset: to,
          flag: flag,
          keepNew: true,
          width: copy!.width,
          height: copy.height,
        ),
      );
    }
    for (final e in extras) {
      final asset = e.libraryId;
      if (asset == null || asset == from || asset == copy?.libraryId) continue;
      await file(
        PendingSwap(
          localId: e.localId,
          oldAsset: asset,
          keeperId: keeper.localId,
          flag: flag,
        ),
      );
    }
    return count;
  }

  void _step(StorageItem item, FixAction action) =>
      _onStep?.call(item.record.localId, action);

  /// Why the last [smallerFile] came back empty, in a few words.
  String? smallerFileProblem;

  /// What goes to the bucket for Optimize in the bucket, in a temp file the
  /// caller owns, and never by touching the phone's own copy:
  ///
  /// 1. the phone's copy is already optimized — that file, as it is;
  /// 2. the phone has the original — a smaller copy made from it;
  /// 3. it hasn't — [fromBucket] downloads the bucket's, and the smaller
  ///    copy is made from that.
  ///
  /// The last [smallerFile] made a copy no smaller: already as compact as
  /// it gets, nothing to retry.
  bool smallestAlready = false;

  /// Null when nothing smaller can be had; [smallerFileProblem] says why.
  Future<File?> smallerFile(
    AssetRecord record, {
    Future<File?> Function(String toPath)? fromBucket,
  }) async {
    smallerFileProblem = null;
    smallestAlready = false;
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final temps = <File>[];
    File temp(String ext) {
      final f = File(p.join(Directory.systemTemp.path, 'remote_$stamp$ext'));
      temps.add(f);
      return f;
    }

    try {
      final local = await _localCopy(record);
      if (local != null && record.localOptimized) {
        return await local.copy(temp(p.extension(local.path)).path);
      }
      var source = local;
      if (source == null) {
        final key = record.stateOf(DerivativeKind.original).destinationKey;
        final download = fromBucket == null
            ? null
            : await fromBucket(temp('_in${p.extension(key ?? '')}').path);
        if (download == null || !await download.exists()) {
          smallerFileProblem =
              'no copy on this iPhone, and the download failed';
          return await _cleanUp(temps);
        }
        source = download;
      }
      final out = temp(record.isVideo ? '.mov' : '.heic');
      final wrote = record.isVideo
          ? await _writer.compressVideo(source.path, out.path)
          : await _writer.encodeStill(source.path, out.path, optimizedMaxEdge);
      if (wrote && await out.length() < await source.length() * _worthKeeping) {
        temps.remove(out);
        await _cleanUp(temps);
        return out;
      }
      smallerFileProblem = wrote || !record.isVideo
          ? 'not smaller'
          : lastVideoCompressError ?? 'video not compressed';
      smallestAlready =
          wrote || (smallerFileProblem?.startsWith('not smaller') ?? false);
    } catch (e) {
      smallerFileProblem = '$e';
    }
    return _cleanUp(temps);
  }

  /// The file on this phone, without fetching anything: an app-owned file,
  /// or a library asset that is downloaded already. Never an iCloud pull.
  Future<File?> _localCopy(AssetRecord record) async {
    if (record.localDeleted) return null;
    final path = record.sourcePath;
    if (path != null) {
      final file = File(path);
      return await file.exists() ? file : null;
    }
    return library.localFileFor(record);
  }

  static Future<File?> _cleanUp(List<File> files) async {
    for (final f in files) {
      try {
        await f.delete();
      } catch (_) {}
    }
    return null;
  }

  /// The smaller copy, saved into Photos — the asset and the temp file it
  /// was made from. Null when there was nothing smaller to make, or a Live
  /// Photo's `.mov` couldn't be had (a silent copy is not a smaller one).
  /// Largest share of the original a copy may be and still replace it.
  static const _worthKeeping = 0.9;

  /// Photos the last runs couldn't make worth-while smaller.
  final notSmaller = <String>{};

  Future<(AssetEntity, File)?> _smallerCopyInLibrary(StorageItem item) async {
    final record = item.record;
    File? out;
    try {
      final source = await _writer.original(library, record);
      if (source == null) return null;
      final video = _compressesVideo(item);
      out = File(
        p.join(
          Directory.systemTemp.path,
          'smaller_${DateTime.now().microsecondsSinceEpoch}'
          '${video ? '.mov' : '.heic'}',
        ),
      );
      final wrote = video
          ? await _writer.compressVideo(source.path, out.path)
          : await _writer.encodeStill(source.path, out.path, optimizedMaxEdge);
      if (!wrote) {
        if (video &&
            (lastVideoCompressError?.startsWith('not smaller') ?? false)) {
          notSmaller.add(record.localId);
        }
        return null;
      }
      // A copy barely smaller is a second file in Photos for nothing.
      if (await out.length() > await source.length() * _worthKeeping) {
        notSmaller.add(record.localId);
        await out.delete();
        return null;
      }
      File? motion;
      if (record.isLivePhoto) {
        motion = await PhotoLibraryService.resolveLivePhotoVideo(record);
        if (motion == null) return null;
      }
      final title = p.setExtension(
        item.name.isEmpty ? p.basename(source.path) : item.name,
        video ? '.MOV' : '.HEIC',
      );
      final asset = await _writer.save(
        file: out,
        motion: motion,
        isVideo: video,
        title: title,
        createdAt: record.createdAt,
      );
      if (asset == null) return null;
      if (record.isFavorite) await _writer.favorite(asset);
      return (asset, out);
    } catch (_) {
      try {
        await out?.delete();
      } catch (_) {}
      return null;
    }
  }

  static bool _compressesVideo(StorageItem item) =>
      item.fix == StorageFix.optimize && item.record.isVideo;

  /// An app-owned video, replaced by its 1080p HEVC copy.
  Future<int?> _compressOwned(StorageItem item) async {
    final path = item.record.sourcePath;
    if (path == null) return null;
    try {
      final file = File(path);
      final before = await file.length();
      final temp = p.join(
        Directory.systemTemp.path,
        'smaller_${DateTime.now().microsecondsSinceEpoch}.mov',
      );
      if (!await _writer.compressVideo(path, temp)) return null;
      final hash = await hashFile(temp);
      final target = File(p.join(p.dirname(path), '$hash.mov'));
      await File(temp).rename(target.path);
      final after = await target.length();
      if (target.path != path) await file.delete();
      await store.setSourcePath(item.record.localId, target.path);
      await store.setLocalOptimized(item.record.localId, true);
      return before - after;
    } catch (_) {
      return null;
    }
  }

  Future<StorageFixResult> _removeFromDevice(
    List<StorageItem> items,
    void Function(StorageItem item, StorageItemOutcome outcome) report,
  ) async {
    var freed = 0;
    var skipped = 0;
    final fromLibrary = <StorageItem>[];

    for (final item in items) {
      // The grid draws this once the original is gone; without one the
      // photo would vanish rather than go cloud-only.
      if (!await _hasThumbnail(item.record)) {
        skipped++;
        report(item, StorageItemOutcome.skipped);
        continue;
      }
      final path = item.record.sourcePath;
      if (path == null) {
        fromLibrary.add(item);
        continue;
      }
      try {
        await File(path).delete();
      } catch (_) {
        skipped++;
        report(item, StorageItemOutcome.skipped);
        continue;
      }
      await store.setLocalDeleted(item.record.localId, true);
      freed += item.bytes;
      report(item, StorageItemOutcome.freed);
    }

    if (fromLibrary.isNotEmpty) {
      // One iOS confirmation for the whole batch, not one per photo.
      final gone = await library.deleteManyFromLibrary([
        for (final item in fromLibrary) item.record,
      ]);
      for (final item in fromLibrary) {
        if (!gone.contains(item.record.localId)) {
          skipped++;
          report(item, StorageItemOutcome.skipped);
          continue;
        }
        await store.setLocalDeleted(item.record.localId, true);
        freed += item.bytes;
        report(item, StorageItemOutcome.freed);
      }
    }

    return StorageFixResult(freedBytes: freed, skipped: skipped);
  }

  Future<bool> _hasThumbnail(AssetRecord record) async {
    final existing = record.thumbnailPath;
    if (existing != null && File(existing).existsSync()) return true;
    // A video's poster frame comes from the photo library; exporting the
    // whole movie to make a picture of it would be absurd.
    final path = record.isVideo ? null : await _localPathOf(record);
    if (path == null && !record.isVideo) return false;
    return await thumbnails.ensureFor(record, path) != null;
  }

  Future<String?> _localPathOf(AssetRecord record) async {
    final path = record.sourcePath;
    if (path != null && File(path).existsSync()) return path;
    if (record.sourceType != AssetSourceType.photoManager) return null;
    try {
      return (await library.fileFor(record))?.path;
    } catch (_) {
      return null;
    }
  }
}

/// What the optimizer asks of iOS to make and file a smaller copy.
/// Overridable for tests, which have no encoder and no photo library.
class LibraryWriter {
  const LibraryWriter();

  /// May bring the original down from iCloud first.
  Future<File?> original(PhotoLibraryService library, AssetRecord record) =>
      library.fileFor(record);

  Future<bool> encodeStill(String input, String output, int maxEdge) =>
      encodeFileNatively(
        input: input,
        output: output,
        format: 'heic',
        maxEdge: maxEdge,
      );

  Future<bool> compressVideo(String input, String output) =>
      compressVideoNatively(input: input, output: output);

  Future<AssetEntity?> save({
    required File file,
    File? motion,
    required bool isVideo,
    required String title,
    required DateTime createdAt,
  }) async {
    if (motion != null) {
      final saved = await PhotoManager.editor.darwin.saveLivePhoto(
        imageFile: file,
        videoFile: motion,
        title: title,
      );
      try {
        return await PhotoManager.editor.darwin.updateCreationDate(
          entity: saved,
          creationDate: createdAt,
        );
      } catch (_) {
        return saved;
      }
    }
    return isVideo
        ? PhotoManager.editor.saveVideo(
            file,
            title: title,
            creationDate: createdAt,
          )
        : PhotoManager.editor.saveImageWithPath(
            file.path,
            title: title,
            creationDate: createdAt,
          );
  }

  Future<void> favorite(AssetEntity asset) async {
    try {
      await PhotoManager.editor.darwin.favoriteAsset(
        entity: asset,
        favorite: true,
      );
    } catch (_) {
      // A nicety; the record keeps its own heart.
    }
  }

  Future<void> delete(List<String> ids) async {
    try {
      await PhotoManager.editor.deleteWithIds(ids);
    } catch (_) {
      // Declined again: both copies stay, and the next scan lists the new one.
    }
  }
}
