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
    this.liveOriginal,
  });

  final AssetRecordStore store;

  /// `OriginalRestore.restoreThumbnail`: the bucket's thumbnail, else one
  /// made without downloading the whole original.
  final Future<String?> Function(AssetRecord record) thumbnail;

  /// Whether the OS library still resolves the record's asset.
  final Future<bool> Function(AssetRecord record) inPhotos;

  /// Drops the record and its files on this phone; never the bucket's.
  final Future<bool> Function(AssetRecord record) remove;

  /// `StorageOptimizer.fileFoundCopies`.
  final Future<void> Function(
    List<({AssetRecord original, AssetRecord copy})> pairs,
    List<AssetRecord> extras,
  )?
  fileCopies;

  /// `BucketFixer.liveOriginal`: the bucket itself, asked by name. A
  /// listing can be stale or cut short; this is what decides "lost".
  final Future<({String targetId, String key})?> Function(String stem)?
  liveOriginal;

  /// From the last [scan]: each original's copy to keep, and any more
  /// copies of it.
  Map<String, ({AssetRecord? copy, List<AssetRecord> extras})> _copies = {};

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
    final suspects = <(AssetRecord, List<String>)>[];
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
      if (gone) {
        suspects.add((r, keys));
      } else {
        bare.add((r, keys));
      }
    }

    // The listing only nominates; each is asked of the bucket before it is
    // called lost. Found, the record is pointed at what is there.
    final confirmed = <(AssetRecord, List<String>)>[];
    for (var i = 0; i < suspects.length; i += _askAtOnce) {
      final batch = suspects.skip(i).take(_askAtOnce).toList();
      final answers = await Future.wait([
        for (final (r, keys) in batch) _confirmLost(r, keys),
      ]);
      for (var j = 0; j < batch.length; j++) {
        if (answers[j]) confirmed.add(batch[j]);
      }
    }
    for (final (r, keys) in confirmed) {
      if (r.localId.startsWith('bucket:') && _twinned(r, keys, holders)) {
        // Imported from a listing older than a replace: the photo it names
        // is already in the library under its new format.
        await store.remove(r.localId);
        continue;
      }
      // One library lookup per lost record: a handful, not the library.
      {
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
    // Already optimized, with more copies of it beside: a swap filed twice,
    // or a copy sync found before the swap moved the record onto another.
    final optimizedGroups = <(List<AssetRecord>, List<AssetRecord>)>[];
    for (final group in byTime.values) {
      if (group.length < 2) continue;
      final copies = group.where(isCopy).toList();
      final optimized = [
        for (final o in group)
          if (o.localOptimized) o,
      ];
      final originals = [
        for (final o in group)
          if (!copies.contains(o) && !o.localOptimized) o,
      ];
      if (copies.isNotEmpty && originals.isNotEmpty) {
        groups.add((originals, copies));
      }
      if (optimized.isNotEmpty && optimized.length + copies.length > 1) {
        optimizedGroups.add((optimized, copies));
      }
    }
    if (groups.isEmpty && optimizedGroups.isEmpty) {
      _copies = {};
      return const [];
    }

    final printPaths = {
      for (final (originals, copies) in [...groups, ...optimizedGroups])
        for (final r in [...originals, ...copies]) r.localId: ?r.thumbnailPath,
    };
    final prints = printPaths.isEmpty
        ? const <String, List<int>>{}
        : await Isolate.run(() {
            final out = <String, List<int>>{};
            for (final MapEntry(key: id, value: path) in printPaths.entries) {
              try {
                final grey = greyPrint(File(path).readAsBytesSync());
                if (grey != null) out[id] = grey;
              } catch (_) {}
            }
            return out;
          });

    bool sameShape(AssetRecord a, AssetRecord b) {
      final (aw, ah, bw, bh) = (a.width!, a.height!, b.width, b.height);
      if (bw == null || bh == null || ah == 0 || bh == 0) return false;
      return ((aw / ah) - (bw / bh)).abs() < 0.02;
    }

    final found = <String, ({AssetRecord? copy, List<AssetRecord> extras})>{};
    final flags = <Flag>[];
    final claimed = <String>{};
    for (final (originals, copies) in groups) {
      final mine = <String, List<(double, AssetRecord)>>{};
      for (final c in copies) {
        final grey = prints[c.localId];
        final near = <(double, AssetRecord)>[
          for (final o in originals)
            if (sameShape(c, o) && (edge(o) ?? 0) > edge(c)!)
              (
                grey != null && prints[o.localId] != null
                    ? printDistance(grey, prints[o.localId]!)
                    : originals.length == 1
                    ? _sameFrame
                    : double.infinity,
                o,
              ),
        ]..sort((a, b) => a.$1.compareTo(b.$1));
        if (near.isNotEmpty &&
            near.first.$1 <= _sameFrame &&
            (near.length == 1 || near[1].$1 > _otherFrame)) {
          (mine[near.first.$2.localId] ??= []).add(near.first);
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
        claimed.addAll([for (final (_, c) in claims) c.localId]);
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
    for (final (optimized, copies) in optimizedGroups) {
      optimized.sort((a, b) {
        if (a.isFavorite != b.isFavorite) return a.isFavorite ? -1 : 1;
        return a.addedAt.compareTo(b.addedAt);
      });
      final keepers = <AssetRecord>[];
      final extras = <String, List<AssetRecord>>{};
      for (final r in [
        ...optimized,
        for (final c in copies)
          if (!claimed.contains(c.localId)) c,
      ]) {
        final mine = prints[r.localId];
        final near = <(double, AssetRecord)>[
          for (final k in keepers)
            if (mine != null &&
                prints[k.localId] != null &&
                sameShape(r, k) &&
                (edge(k) ?? 0) >= (edge(r) ?? 0))
              (printDistance(mine, prints[k.localId]!), k),
        ]..sort((a, b) => a.$1.compareTo(b.$1));
        // Only the same frame, and only when no other is close: a burst's
        // next frame can come within a few levels.
        final sure =
            near.isNotEmpty &&
            near.first.$1 <= _sameFrame &&
            (near.length == 1 || near[1].$1 > _otherFrame) &&
            (!r.localOptimized || r.isVideo);
        if (sure) {
          (extras[near.first.$2.localId] ??= []).add(r);
        } else if (r.localOptimized) {
          keepers.add(r);
        }
      }
      for (final k in keepers) {
        final key = k.stateOf(DerivativeKind.original).destinationKey;
        final kept = key == null ? null : listed[key];
        if (!k.isFullyBackedUp || kept == null) continue;
        // Never lets go of a bigger bucket file than the one kept.
        final mine = [
          for (final e in extras[k.localId] ?? const <AssetRecord>[])
            if (_bucketSize(e, listed) <= kept * 1.01) e,
        ];
        if (mine.isEmpty) continue;
        found[k.localId] = (copy: null, extras: mine);
        flags.add(
          Flag.asset(
            k,
            problem: FlagProblem.extraCopies,
            solutions: const [FlagSolution.removeExtraCopies],
            name: _nameOf(k, [key!]),
          ),
        );
      }
    }
    _copies = found;
    return flags;
  }

  static int _bucketSize(AssetRecord r, Map<String, int> listed) {
    final key = r.stateOf(DerivativeKind.original).destinationKey;
    return key == null ? 0 : listed[key] ?? 0;
  }

  /// [printDistance] bounds. Copies of one frame measured ≤ 1.2 on a real
  /// library; distinct burst frames ≥ 4.9.
  static const _sameFrame = 2.0;
  static const _otherFrame = 4.0;

  /// Files the swap; the queue's one iOS prompt at the end of the run
  /// deletes the original and moves the record onto its copy.
  Future<FixResult> finishOptimize(AssetRecord record) async {
    final file = fileCopies;
    final found = _copies[record.localId];
    if (file == null || found == null) {
      return const FixResult(FixOutcome.failed, detail: 'rescan first');
    }
    await file([
      if (found.copy case final copy?) (original: record, copy: copy),
    ], found.extras);
    return const FixResult(FixOutcome.removed);
  }

  static const _askAtOnce = 8;

  /// True only when every bucket set up now answered and none has the
  /// original under its name, in any format. Found: the record is pointed
  /// at it and it is not lost. No answer: not lost either; unsure is never
  /// gone.
  Future<bool> _confirmLost(AssetRecord r, List<String> keys) async {
    final ask = liveOriginal;
    if (ask == null) return false;
    try {
      for (final stem in {
        for (final k in keys) p.posix.basenameWithoutExtension(k),
      }) {
        final found = await ask(stem);
        if (found == null) continue;
        await _pointAt(r, found);
        return false;
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _pointAt(
    AssetRecord r,
    ({String targetId, String key}) found,
  ) async {
    await store.recordUpload(
      localId: r.localId,
      kind: DerivativeKind.original,
      targetId: found.targetId,
      destinationKey: found.key,
    );
    await store.updateDerivative(
      r.localId,
      DerivativeKind.original,
      r
          .stateOf(DerivativeKind.original)
          .copyWith(status: UploadStatus.uploaded, destinationKey: found.key),
    );
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

  /// The record only. Asked of the bucket once more first: a file found
  /// is linked back instead, and a bucket that doesn't answer stops it.
  Future<FixResult> removeFromLibrary(AssetRecord record) async {
    final keys = [
      ?record.stateOf(DerivativeKind.original).destinationKey,
      ...(await store.targetsHolding(
        record.localId,
        DerivativeKind.original,
      )).values,
    ];
    if (!await _confirmLost(record, keys)) {
      return const FixResult(
        FixOutcome.failed,
        detail: 'still in the bucket, or the bucket did not answer',
      );
    }
    return await remove(record)
        ? const FixResult(FixOutcome.removed)
        : const FixResult(FixOutcome.failed, detail: 'locked');
  }
}
