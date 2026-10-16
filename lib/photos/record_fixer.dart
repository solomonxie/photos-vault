import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import '../storage/bucket_object.dart';
import '../upload/bucket_flagged.dart' show BucketFlags, FixOutcome, FixResult;
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
    this.importCopies = const [],
  });

  final List<Flag> noThumbnail;
  final List<Flag> lost;

  /// Originals still in Photos beside the smaller copy Optimize made.
  final List<Flag> leftoverCopies;

  /// Bucket imports that are the same picture as a photo already here.
  final List<Flag> importCopies;
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
    this.durationOf,
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
  final Future<int> Function(
    AssetRecord keeper, {
    AssetRecord? copy,
    List<AssetRecord> extras,
    String? flag,
  })?
  fileCopies;

  /// `PhotoLibraryService.durationOf`: a video's copy must run as long as
  /// the original, or it is a clip of it, not a copy.
  final Future<Duration?> Function(AssetRecord record)? durationOf;

  /// `BucketFixer.liveOriginal`: the bucket itself, asked by name. A
  /// listing can be stale or cut short; this is what decides "lost".
  final Future<({String targetId, String key})?> Function(
    String stem,
    bool video,
  )?
  liveOriginal;

  /// From the last [scan]: each original's copy to keep, and any more
  /// copies of it. Kept in app state too, so a job resumed after a quit
  /// still knows which.
  Map<String, ({String? copy, List<String> extras})> _copies = {};
  bool _copiesLoaded = false;

  static const _copiesKey = 'found_copies_v1';

  Future<void> _saveCopies(
    Map<String, ({String? copy, List<String> extras})> found,
  ) async {
    _copies = found;
    _copiesLoaded = true;
    await store.setAppState(
      _copiesKey,
      jsonEncode({
        for (final MapEntry(key: id, value: (:copy, :extras)) in found.entries)
          id: {'c': copy, 'x': extras},
      }),
    );
  }

  Future<({String? copy, List<String> extras})?> _copiesOf(String id) async {
    if (!_copiesLoaded) {
      _copiesLoaded = true;
      try {
        final raw = await store.getAppState(_copiesKey);
        if (raw != null) {
          _copies = {
            for (final MapEntry(:key, :value)
                in (jsonDecode(raw) as Map<String, dynamic>).entries)
              key: (
                copy: (value as Map)['c'] as String?,
                extras: (value['x'] as List).cast<String>(),
              ),
          };
        }
      } catch (_) {
        // Unreadable: a rescan finds them again.
      }
    }
    return _copies[id];
  }

  /// [records] and [objects] are the caller's snapshot, when it has one.
  Future<RecordScan> scan({
    List<AssetRecord>? records,
    List<BucketObject>? objects,
  }) async {
    records ??= await store.listAll();
    objects ??= await store.listBucketObjects();
    final sizes = {for (final o in objects) o.key: o.size};
    // A key carries the prefix of the bucket it went to; the same file
    // under another prefix of a bucket set up now still counts.
    final originals = {
      for (final o in objects)
        if (o.directory == 'originals') o.fileName: o.size,
    };
    await _healKinds(records, objects);
    final holdings = await store.allHoldings();
    final lostIds = await LostOriginals(store).current();
    // Only rows still in the library: a binned twin is no reason to call
    // an import a copy.
    final holders = <String, Set<String>>{};
    for (final r in records) {
      if (r.isDeleted || r.isHidden || r.passcodeHash != null) continue;
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
      if (!r.localDeleted ||
          r.isDeleted ||
          r.isHidden ||
          r.passcodeHash != null) {
        continue;
      }
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
    final twins = <Flag>[];
    final byId = {for (final r in records) r.localId: r};
    for (final (r, keys) in confirmed) {
      final twin = r.localId.startsWith('bucket:')
          ? _twinOf(r, keys, holders)
          : null;
      if (twin != null) {
        // Imported from a listing older than a replace: the photo it names
        // is already in the library under its new format. Offered, never
        // dropped unasked: its tags and albums are the person's.
        twins.add(
          Flag.asset(
            r,
            problem: FlagProblem.duplicate,
            solutions: const [FlagSolution.removeImportCopy],
            name: switch (byId[twin]) {
              final t? => _nameOf(t, [
                ?t.stateOf(DerivativeKind.original).destinationKey,
              ]),
              null => _nameOf(r, keys),
            },
          ),
        );
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
      importCopies: [...twins, ...await _importCopies(records)],
    );
  }

  static const _importChecksKey = 'import_copies_v1';

  static bool _isImport(AssetRecord r) =>
      r.localId.startsWith('bucket:') &&
      !r.isDeleted &&
      !r.isHidden &&
      !r.isLocked &&
      r.passcodeHash == null &&
      r.thumbnailPath != null;

  static Future<Map<String, String?>> _importChecks(
    AssetRecordStore store,
  ) async {
    try {
      final raw = await store.getAppState(_importChecksKey);
      return raw == null
          ? {}
          : (jsonDecode(raw) as Map).map(
              (k, v) => MapEntry(k as String, v as String?),
            );
    } catch (_) {
      return {};
    }
  }

  static Future<void>? _checking;

  /// Compares each bucket import not yet compared against every thumbnail
  /// here, off the UI isolate, and keeps the answer. Slow on a big library
  /// (every thumbnail decoded), so it runs in the background after a sync
  /// and once per import, never while Flagged Items waits.
  static Future<void> checkImports(AssetRecordStore store) =>
      _checking ??= _checkImports(store).whenComplete(() => _checking = null);

  static Future<void> _checkImports(AssetRecordStore store) async {
    final records = await store.listAll();
    final known = await _importChecks(store);
    final asked = {
      for (final r in records)
        if (_isImport(r) && !known.containsKey(r.localId))
          r.localId: r.thumbnailPath!,
    };
    if (asked.isEmpty) return;
    final others = {
      for (final r in records)
        if (!r.isDeleted &&
            !r.localId.startsWith('bucket:') &&
            r.passcodeHash == null &&
            r.thumbnailPath != null)
          r.localId: r.thumbnailPath!,
    };
    final found = await Isolate.run(() {
      List<int>? grey(String path) {
        try {
          return greyPrint(File(path).readAsBytesSync());
        } catch (_) {
          return null;
        }
      }

      final mine = {for (final e in asked.entries) e.key: grey(e.value)};
      final near = {for (final id in asked.keys) id: <(double, String)>[]};
      for (final MapEntry(key: id, value: path) in others.entries) {
        final theirs = grey(path);
        if (theirs == null) continue;
        for (final MapEntry(key: a, value: print) in mine.entries) {
          if (print == null) continue;
          final d = printDistance(print, theirs);
          if (d <= _otherFrame) near[a]!.add((d, id));
        }
      }
      // Only the same frame, and only when nothing else comes close.
      return {
        for (final MapEntry(key: a, value: list) in near.entries)
          a: switch (list..sort((x, y) => x.$1.compareTo(y.$1))) {
            [final best] when best.$1 <= _sameFrame => best.$2,
            [final best, final next, ...]
                when best.$1 <= _sameFrame && next.$1 > _otherFrame =>
              best.$2,
            _ => null,
          },
      };
    });
    final latest = await _importChecks(store)
      ..addAll(found);
    await store.setAppState(_importChecksKey, jsonEncode(latest));
  }

  /// A bucket import the library already has: the same picture as a photo
  /// here, which keeps the real date the import's file never carried. Read
  /// from [checkImports]' answers; any import not compared yet starts it.
  Future<List<Flag>> _importCopies(List<AssetRecord> records) async {
    final known = await _importChecks(store);
    if (records.any((r) => _isImport(r) && !known.containsKey(r.localId))) {
      unawaited(checkImports(store).catchError((_) {}));
    }
    final byId = {for (final r in records) r.localId: r};
    final flags = <Flag>[];
    for (final r in records) {
      if (!_isImport(r)) continue;
      final kept = byId[known[r.localId]];
      if (kept == null || kept.isDeleted) continue;
      flags.add(
        Flag.asset(
          r,
          problem: FlagProblem.duplicate,
          solutions: const [FlagSolution.removeImportCopy],
          name: _nameOf(kept, [
            ?kept.stateOf(DerivativeKind.original).destinationKey,
          ]),
        ),
      );
    }
    return flags;
  }

  /// Into this app's Recently Deleted; the bucket file stays until that is
  /// emptied, and the library's own photo is untouched.
  Future<FixResult> removeImportCopy(AssetRecord record) async {
    await store.softDelete(record.localId);
    return const FixResult(FixOutcome.removed);
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
      await _saveCopies({});
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

    final found = <String, ({String? copy, List<String> extras})>{};
    final flags = <Flag>[];
    final claimed = <String>{};
    for (final (originals, copies) in groups) {
      final mine = <String, List<(double, AssetRecord)>>{};
      for (final c in copies) {
        final grey = prints[c.localId];
        final near = <(double, AssetRecord)>[
          for (final o in originals)
            // Both pictures, always: a lone original with the same time and
            // shape may still be another photo.
            if (sameShape(c, o) && (edge(o) ?? 0) > edge(c)!)
              (
                grey != null && prints[o.localId] != null
                    ? printDistance(grey, prints[o.localId]!)
                    : double.infinity,
                o,
              ),
        ]..sort((a, b) => a.$1.compareTo(b.$1));
        if (near.isNotEmpty &&
            near.first.$1 <= _sameFrame &&
            (near.length == 1 || near[1].$1 > _otherFrame) &&
            // A trimmed clip has the original's first frame; only the
            // length tells them apart. Asked here too, or the flag is
            // offered, refused at Finish, and offered again (04#16).
            await _sameLength(near.first.$2, c)) {
          // Claimed by the copy itself: the original was filed as its
          // own copy, and Finish Optimize had nothing to file.
          (mine[near.first.$2.localId] ??= []).add((near.first.$1, c));
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
          copy: claims.first.$2.localId,
          extras: [for (final (_, c) in claims.skip(1)) c.localId],
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
            (!r.localOptimized || r.isVideo) &&
            await _sameLength(near.first.$2, r);
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
        found[k.localId] = (
          copy: null,
          extras: [for (final e in mine) e.localId],
        );
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
    await _saveCopies(found);
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

  /// Files the swap; the queue's one iOS prompt deletes the original and
  /// moves the record onto its copy, and reports by [flag]. Every record is
  /// read again first: one hidden, locked or binned since, or no longer in
  /// Photos, is left alone.
  Future<FixResult> finishOptimize(AssetRecord record, {String? flag}) async {
    final file = fileCopies;
    final found = await _copiesOf(record.localId);
    if (file == null || found == null) {
      return const FixResult(FixOutcome.failed, detail: 'rescan first');
    }
    final fresh = await store.getByLocalIds([
      record.localId,
      ?found.copy,
      ...found.extras,
    ]);
    bool usable(AssetRecord? r) =>
        r != null &&
        !r.isDeleted &&
        !r.localDeleted &&
        !r.isHidden &&
        !r.isLocked &&
        r.passcodeHash == null &&
        r.libraryId != null;
    final keeper = fresh[record.localId];
    if (!usable(keeper)) {
      return const FixResult(FixOutcome.failed, detail: 'changed since');
    }
    var copy = fresh[found.copy];
    if (found.copy != null && !usable(copy)) {
      return const FixResult(FixOutcome.failed, detail: 'copy changed since');
    }
    final extras = [
      for (final id in found.extras)
        if (fresh[id] case final e? when usable(e)) e,
    ];
    if (copy != null && !await _sameLength(keeper!, copy)) copy = null;
    final same = [
      for (final e in extras)
        if (await _sameLength(keeper!, e)) e,
    ];
    if (copy == null && same.isEmpty) {
      return const FixResult(FixOutcome.failed, detail: 'not the same video');
    }
    final filed = await file(keeper!, copy: copy, extras: same, flag: flag);
    return filed == 0
        ? const FixResult(FixOutcome.failed, detail: 'nothing to file')
        : const FixResult(FixOutcome.filed);
  }

  /// A video and its copy run equally long; a still always does. Unknown
  /// is not the same.
  Future<bool> _sameLength(AssetRecord a, AssetRecord b) async {
    if (!a.isVideo && !b.isVideo) return true;
    final measure = durationOf;
    if (measure == null) return false;
    final (x, y) = (await measure(a), await measure(b));
    return x != null &&
        y != null &&
        (x - y).abs() <= const Duration(seconds: 1);
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
        final found = await ask(stem, r.isVideo);
        if (found == null) continue;
        await _pointAt(r, found);
        return false;
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// A still pointed at its Live Photo's `.MOV` (or the other way round)
  /// goes back to the file of its own kind, when the bucket lists one under
  /// the same name. Left as it was, the right file looks unclaimed and is
  /// offered for import.
  Future<void> _healKinds(
    List<AssetRecord> records,
    List<BucketObject> objects,
  ) async {
    bool isVideoKey(String k) => BucketFlags.videoExtensions.contains(
      p.posix.extension(k).replaceFirst('.', '').toLowerCase(),
    );
    final byStem = <String, List<BucketObject>>{};
    for (final o in objects) {
      if (o.directory != 'originals') continue;
      (byStem[p.posix.withoutExtension(o.key)] ??= []).add(o);
    }
    for (final r in records) {
      if (r.isDeleted) continue;
      final key = r.stateOf(DerivativeKind.original).destinationKey;
      if (key == null || isVideoKey(key) == r.isVideo) continue;
      final right = byStem[p.posix.withoutExtension(key)]
          ?.where((o) => isVideoKey(o.key) == r.isVideo)
          .firstOrNull;
      if (right == null) continue;
      await _pointAt(r, (targetId: right.targetId, key: right.key));
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

  static String? _twinOf(
    AssetRecord r,
    List<String> keys,
    Map<String, Set<String>> holders,
  ) {
    for (final k in keys) {
      for (final id in holders[p.posix.basenameWithoutExtension(k)] ?? {}) {
        if (id != r.localId) return id;
      }
    }
    return null;
  }

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
