import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:photo_manager/photo_manager.dart';

import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import '../upload/backup_verifier.dart';
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

    final toBackUp = [
      for (final item in items)
        if (item.fix == StorageFix.backUpFirst) item,
    ];
    if (toBackUp.isNotEmpty) {
      await backUp([for (final item in toBackUp) item.record]);
      for (final item in toBackUp) {
        report(item, StorageItemOutcome.queued);
      }
    }

    final unconfirmed = await _unconfirmed(items);

    final inLibrary = <StorageItem>[];
    for (final item in items) {
      if (!_rewrites.contains(item.fix)) continue;
      // The re-encodes replace the local copy, which is only safe while the
      // bucket holds the full-quality original they're throwing away.
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
    for (final item in items) {
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
      for (final item in items)
        if (item.fix == StorageFix.removeDuplicate) item,
    ], report);
    freed += dupes.freedBytes;
    skipped += dupes.skipped;

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
  Future<Set<String>> _unconfirmed(List<StorageItem> items) async {
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
  Future<StorageFixResult> _removeDuplicates(
    List<StorageItem> items,
    void Function(StorageItem item, StorageItemOutcome outcome) report,
  ) async {
    var freed = 0;
    var skipped = 0;
    bool inLibrary(StorageItem i) =>
        i.record.sourceType == AssetSourceType.photoManager &&
        !i.record.localDeleted &&
        PhotoLibraryService.libraryIdOf(i.record) != null;
    final fromLibrary = items.where(inLibrary).toList();
    if (_defer && fromLibrary.isNotEmpty) {
      await _addSwaps([
        for (final item in fromLibrary)
          {'id': item.record.localId, 'old': item.bytes},
      ]);
      for (final item in fromLibrary) {
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
    return StorageFixResult(freedBytes: freed, skipped: skipped);
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
    for (final item in items) {
      _step(item, FixAction.optimizing);
      final result = await _smallerCopyInLibrary(item);
      if (result == null) {
        skipped++;
        report(item, StorageItemOutcome.skipped);
      } else {
        made[item] = result;
        onPrepared?.call(item.record.localId);
      }
    }
    if (made.isEmpty) return StorageFixResult(skipped: skipped);
    if (_defer) {
      await _addSwaps([
        for (final MapEntry(key: item, value: (asset, file)) in made.entries)
          {
            'id': item.record.localId,
            'asset': asset.id,
            'w': asset.width,
            'h': asset.height,
            'old': item.bytes,
            'new': await file.length(),
          },
      ]);
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
      await store.setLibraryId(id, asset.id);
      await store.setLocalOptimized(id, true);
      await store.setLibraryMetadata(
        id,
        width: asset.width,
        height: asset.height,
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
  /// are filed in [_swapsKey] rather than deleted, and [finishSwaps] asks
  /// for all of them in one iOS prompt when the run is over.
  bool _defer = false;
  void Function(String localId)? _onPrepared;

  static const _swapsKey = 'pending_swaps_v1';

  /// Originals waiting on that one prompt. Kept in app state, so a run cut
  /// short by a quit still asks on the next launch instead of leaving both
  /// copies in Photos.
  Future<List<Map<String, dynamic>>> pendingSwaps() async {
    try {
      final raw = await store.getAppState(_swapsKey);
      return raw == null
          ? []
          : [
              for (final e in jsonDecode(raw) as List)
                (e as Map).cast<String, dynamic>(),
            ];
    } catch (_) {
      return [];
    }
  }

  Future<void> _addSwaps(Iterable<Map<String, dynamic>> swaps) async {
    final all = [...await pendingSwaps(), ...swaps];
    await store.setAppState(_swapsKey, jsonEncode(all));
  }

  /// The one prompt: every filed original out of Photos at once. A
  /// replaced photo moves over to its smaller copy; a duplicate goes to
  /// Recently Deleted. Declined, the smaller copies are taken back out and
  /// nothing has changed.
  Future<StorageFixResult> finishSwaps({
    void Function(String localId, StorageItemOutcome outcome)? onItem,
  }) async {
    final swaps = await pendingSwaps();
    if (swaps.isEmpty) return const StorageFixResult();
    final records = <String, AssetRecord>{};
    for (final s in swaps) {
      final r = await store.getByLocalId(s['id'] as String);
      if (r != null) records[r.localId] = r;
    }
    Set<String> gone;
    try {
      gone = await library.deleteManyFromLibrary([
        ...records.values,
      ], limit: records.length + 1);
    } catch (_) {
      gone = const {};
    }
    var freed = 0;
    var skipped = 0;
    final orphans = <String>[];
    for (final s in swaps) {
      final id = s['id'] as String;
      final asset = s['asset'] as String?;
      if (!gone.contains(id)) {
        if (asset != null) orphans.add(asset);
        skipped++;
        onItem?.call(id, StorageItemOutcome.skipped);
        continue;
      }
      if (asset == null) {
        await store.softDelete(id);
        freed += s['old'] as int;
      } else {
        await store.setLibraryId(id, asset);
        await store.setLocalOptimized(id, true);
        await store.setLibraryMetadata(
          id,
          width: s['w'] as int?,
          height: s['h'] as int?,
        );
        final saved = (s['old'] as int) - (s['new'] as int);
        if (saved > 0) freed += saved;
      }
      onItem?.call(id, StorageItemOutcome.freed);
    }
    await store.setAppState(_swapsKey, '[]');
    if (orphans.isNotEmpty) await _writer.delete(orphans);
    return StorageFixResult(freedBytes: freed, skipped: skipped);
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
  /// Null when nothing smaller can be had; [smallerFileProblem] says why.
  Future<File?> smallerFile(
    AssetRecord record, {
    Future<File?> Function(String toPath)? fromBucket,
  }) async {
    smallerFileProblem = null;
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
      if (wrote && await out.length() < await source.length()) {
        temps.remove(out);
        await _cleanUp(temps);
        return out;
      }
      smallerFileProblem = record.isVideo
          ? lastVideoCompressError ?? 'video not compressed'
          : 'not smaller';
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
      if (!wrote) return null;
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
