import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import '../upload/bucket_flagged.dart' show FixOutcome, FixResult;
import '../upload/cloud_thumbnails.dart';
import '../upload/lost_originals.dart';
import 'fix_queue.dart';
import 'image_pipeline.dart';
import 'storage_advice.dart' show compressedVideoEdge, optimizedMaxEdge;

/// Cloud-only records with something wrong that only the record can fix:
/// no picture of themselves on this phone, or no original anywhere a
/// bucket set up now can reach.
class RecordScan {
  const RecordScan({
    this.noThumbnail = const [],
    this.lost = const [],
    this.leftoverCopies = const [],
  });

  final List<Flag> noThumbnail;
  final List<Flag> lost;

  /// Originals still in Photos beside the smaller copy Optimize made.
  final List<Flag> leftoverCopies;
}

/// Finds and fixes [RecordScan]'s flags for [FixQueue].
class RecordFixer {
  RecordFixer({
    required this.store,
    required this.thumbnail,
    required this.inPhotos,
    required this.remove,
    this.fileCopies,
  });

  final AssetRecordStore store;

  /// `OriginalRestore.restoreThumbnail`: the bucket's thumbnail, else one
  /// made without downloading the whole original.
  final Future<String?> Function(AssetRecord record) thumbnail;

  /// Whether the OS library still resolves the record's asset.
  final Future<bool> Function(AssetRecord record) inPhotos;

  /// `AssetRemoval.deletePermanently`.
  final Future<bool> Function(AssetRecord record) remove;

  /// `StorageOptimizer.fileFoundCopies`.
  final Future<void> Function(
    List<({AssetRecord original, AssetRecord copy})> pairs,
    List<AssetRecord> extras,
  )?
  fileCopies;

  /// From the last [scan]: each original's copy to keep, and any more
  /// copies of it.
  Map<String, ({AssetRecord copy, List<AssetRecord> extras})> _copies = {};

  Future<RecordScan> scan() async {
    final records = await store.listAll();
    final objects = await store.listBucketObjects();
    final sizes = {for (final o in objects) o.key: o.size};
    // A key carries the prefix of the bucket it went to; the same file
    // under another prefix of a bucket set up now still counts.
    final originals = {
      for (final o in objects)
        if (o.directory == 'originals') o.fileName: o.size,
    };
    final holdings = await store.allHoldings();
    final lostIds = await LostOriginals(store).current();
    final holders = <String, Set<String>>{};
    for (final r in records) {
      for (final k in [
        ?r.stateOf(DerivativeKind.original).destinationKey,
        ...?holdings[r.localId]?[DerivativeKind.original]?.values,
      ]) {
        (holders[p.posix.basenameWithoutExtension(k)] ??= {}).add(r.localId);
      }
    }

    final lost = <Flag>[];
    final bare = <(AssetRecord, List<String>)>[];
    for (final r in records) {
      if (!r.localDeleted || r.isDeleted || r.passcodeHash != null) continue;
      final keys = [
        ?r.stateOf(DerivativeKind.original).destinationKey,
        ...?holdings[r.localId]?[DerivativeKind.original]?.values,
      ];
      final gone =
          lostIds.contains(r.localId) ||
          (objects.isNotEmpty &&
              keys.isNotEmpty &&
              !keys.any(
                (k) =>
                    sizes.containsKey(k) ||
                    originals.containsKey(p.posix.basename(k)),
              ));
      if (gone &&
          r.localId.startsWith('bucket:') &&
          _twinned(r, keys, holders)) {
        // Imported from a listing older than a replace: the photo it names
        // is already in the library under its new format.
        await store.remove(r.localId);
        continue;
      }
      if (gone) {
        // One library lookup per lost record: a handful, not the library.
        final photos = r.libraryId != null && await _inPhotos(r);
        lost.add(
          Flag.asset(
            r,
            problem: FlagProblem.missingFromBucket,
            solutions: [
              photos
                  ? FlagSolution.getFromPhotos
                  : FlagSolution.removeFromLibrary,
            ],
            name: _nameOf(r, keys),
          ),
        );
      } else {
        bare.add((r, keys));
      }
    }

    // Every check in one isolate hop, never a stat per record on the UI
    // isolate.
    final paths = [for (final (r, _) in bare) ?r.thumbnailPath];
    final missing = paths.isEmpty
        ? const <String>{}
        : await Isolate.run(
            () => {
              for (final path in paths)
                if (!File(path).existsSync()) path,
            },
          );

    final noThumbnail = [
      for (final (r, keys) in bare)
        if (r.thumbnailPath == null || missing.contains(r.thumbnailPath))
          Flag.asset(
            r,
            problem: FlagProblem.noThumbnail,
            solutions: const [FlagSolution.makeThumbnail],
            name: _nameOf(r, keys),
            bytes: _sizeOf(keys, sizes, originals),
          ),
    ];
    return RecordScan(
      noThumbnail: noThumbnail,
      lost: lost,
      leftoverCopies: await _leftoverCopies(records, sizes),
    );
  }

  /// A copy has the original's capture time, the shape Optimize gives,
  /// and arrived in Photos long after it was taken. A burst shares the
  /// time and the size, so the picture itself decides which is whose.
  Future<List<Flag>> _leftoverCopies(
    List<AssetRecord> records,
    Map<String, int> listed,
  ) async {
    bool inPhotos(AssetRecord r) =>
        !r.isDeleted &&
        !r.localDeleted &&
        r.passcodeHash == null &&
        !r.isLocked &&
        r.libraryId != null &&
        r.sourceType == AssetSourceType.photoManager;
    int? edge(AssetRecord r) => switch ((r.width, r.height)) {
      (final w?, final h?) => w > h ? w : h,
      _ => null,
    };
    bool isCopy(AssetRecord r) {
      final e = edge(r);
      return !r.localOptimized &&
          e != null &&
          r.addedAt.difference(r.createdAt) > const Duration(days: 1) &&
          (r.isVideo ? e == compressedVideoEdge : e == optimizedMaxEdge);
    }

    final byTime = <(int, bool), List<AssetRecord>>{};
    for (final r in records) {
      if (!inPhotos(r)) continue;
      (byTime[(r.createdAt.millisecondsSinceEpoch, r.isVideo)] ??= []).add(r);
    }
    final groups = <(List<AssetRecord>, List<AssetRecord>)>[];
    for (final group in byTime.values) {
      if (group.length < 2) continue;
      final copies = group.where(isCopy).toList();
      if (copies.isEmpty) continue;
      final originals = [
        for (final o in group)
          if (!copies.contains(o) && !o.localOptimized) o,
      ];
      if (originals.isNotEmpty) groups.add((originals, copies));
    }
    if (groups.isEmpty) {
      _copies = {};
      return const [];
    }

    final paths = {
      for (final (originals, copies) in groups)
        for (final r in [...originals, ...copies]) r.localId: ?r.thumbnailPath,
    };
    final hashes = await Isolate.run(() {
      final out = <String, int>{};
      for (final MapEntry(key: id, value: path) in paths.entries) {
        try {
          final hash = differenceHash(File(path).readAsBytesSync());
          if (hash != null) out[id] = hash;
        } catch (_) {}
      }
      return out;
    });

    bool sameShape(AssetRecord a, AssetRecord b) {
      final (aw, ah, bw, bh) = (a.width!, a.height!, b.width, b.height);
      if (bw == null || bh == null || ah == 0 || bh == 0) return false;
      return ((aw / ah) - (bw / bh)).abs() < 0.02;
    }

    final found = <String, ({AssetRecord copy, List<AssetRecord> extras})>{};
    final flags = <Flag>[];
    for (final (originals, copies) in groups) {
      final mine = <String, List<(int, AssetRecord)>>{};
      for (final c in copies) {
        AssetRecord? best;
        var bestDistance = 1 << 30;
        for (final o in originals) {
          if (!sameShape(c, o) || (edge(o) ?? 0) <= edge(c)!) continue;
          final (hc, ho) = (hashes[c.localId], hashes[o.localId]);
          final d = hc != null && ho != null
              ? hashDistance(hc, ho)
              : originals.length == 1
              ? _maxDistance
              : 1 << 30;
          if (d < bestDistance) (best, bestDistance) = (o, d);
        }
        if (best != null && bestDistance <= _maxDistance) {
          (mine[best.localId] ??= []).add((bestDistance, c));
        }
      }
      for (final o in originals) {
        final claims = mine[o.localId];
        if (claims == null) continue;
        // Gone from Photos only when the full-size file is safe elsewhere.
        final key = o.stateOf(DerivativeKind.original).destinationKey;
        if (!o.isFullyBackedUp || key == null || !listed.containsKey(key)) {
          continue;
        }
        claims.sort((a, b) => a.$1.compareTo(b.$1));
        found[o.localId] = (
          copy: claims.first.$2,
          extras: [for (final (_, c) in claims.skip(1)) c],
        );
        flags.add(
          Flag.asset(
            o,
            problem: FlagProblem.leftoverCopy,
            solutions: const [FlagSolution.finishOptimize],
            name: _nameOf(o, [key]),
          ),
        );
      }
    }
    _copies = found;
    return flags;
  }

  static const _maxDistance = 10;

  /// Files the swap; the queue's one iOS prompt at the end of the run
  /// deletes the original and moves the record onto its copy.
  Future<FixResult> finishOptimize(AssetRecord record) async {
    final file = fileCopies;
    final found = _copies[record.localId];
    if (file == null || found == null) {
      return const FixResult(FixOutcome.failed, detail: 'rescan first');
    }
    await file([(original: record, copy: found.copy)], found.extras);
    return const FixResult(FixOutcome.removed);
  }

  static bool _twinned(
    AssetRecord r,
    List<String> keys,
    Map<String, Set<String>> holders,
  ) => keys.any(
    (k) =>
        holders[p.posix.basenameWithoutExtension(k)]?.any(
          (id) => id != r.localId,
        ) ??
        false,
  );

  Future<bool> _inPhotos(AssetRecord r) async {
    try {
      return await inPhotos(r);
    } catch (_) {
      return false;
    }
  }

  static String _nameOf(AssetRecord r, List<String> keys) {
    if (r.sourcePath case final path?) return p.basename(path);
    if (keys.firstOrNull case final key?) return p.posix.basename(key);
    return '';
  }

  static int _sizeOf(
    List<String> keys,
    Map<String, int> sizes,
    Map<String, int> originals,
  ) {
    for (final k in keys) {
      if (sizes[k] ?? originals[p.posix.basename(k)] case final size?) {
        return size;
      }
    }
    return 0;
  }

  Future<FixResult> makeThumbnail(AssetRecord record) async {
    final path = await thumbnail(record);
    if (path == null) {
      return const FixResult(FixOutcome.failed, detail: 'no bucket had it');
    }
    CloudThumbnails.instance?.landed(record.localId, path);
    return const FixResult(FixOutcome.imported);
  }

  /// Back to the Photos copy, cloud-only no more, and owed a backup: the
  /// bucket it was in is gone.
  Future<FixResult> getFromPhotos(AssetRecord record) async {
    if (!await _inPhotos(record)) {
      return const FixResult(FixOutcome.failed, detail: 'not in Photos');
    }
    await store.setLocalDeleted(record.localId, false);
    await store.updateDerivative(
      record.localId,
      DerivativeKind.original,
      record
          .stateOf(DerivativeKind.original)
          .copyWith(status: UploadStatus.pending),
    );
    return const FixResult(FixOutcome.imported);
  }

  Future<FixResult> removeFromLibrary(AssetRecord record) async =>
      await remove(record)
      ? const FixResult(FixOutcome.removed)
      : const FixResult(FixOutcome.failed, detail: 'locked');
}
