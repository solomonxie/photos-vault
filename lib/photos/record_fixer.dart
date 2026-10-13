import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import '../upload/bucket_flagged.dart' show FixOutcome, FixResult;
import '../upload/cloud_thumbnails.dart';
import '../upload/lost_originals.dart';
import 'fix_queue.dart';

/// Cloud-only records with something wrong that only the record can fix:
/// no picture of themselves on this phone, or no original anywhere a
/// bucket set up now can reach.
class RecordScan {
  const RecordScan({this.noThumbnail = const [], this.lost = const []});

  final List<Flag> noThumbnail;
  final List<Flag> lost;
}

/// Finds and fixes [RecordScan]'s flags for [FixQueue].
class RecordFixer {
  RecordFixer({
    required this.store,
    required this.thumbnail,
    required this.inPhotos,
    required this.remove,
  });

  final AssetRecordStore store;

  /// `OriginalRestore.restoreThumbnail`: the bucket's thumbnail, else one
  /// made without downloading the whole original.
  final Future<String?> Function(AssetRecord record) thumbnail;

  /// Whether the OS library still resolves the record's asset.
  final Future<bool> Function(AssetRecord record) inPhotos;

  /// `AssetRemoval.deletePermanently`.
  final Future<bool> Function(AssetRecord record) remove;

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
    return RecordScan(noThumbnail: noThumbnail, lost: lost);
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
