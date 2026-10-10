import 'package:flutter/foundation.dart';

import '../settings/backup_targets_store.dart';
import '../settings/s3_backup_target.dart';
import '../storage/asset_record_store.dart';
import '../storage/bucket_object.dart';
import '../vault/keys.dart';
import 'bucket_flagged.dart';
import 'bucket_ops.dart';

/// Lists every bucket once and keeps the result in `bucket_object`, which is
/// what the flagged-items page and every hidden album scan read instead of
/// asking the bucket again.
class BucketIndexer {
  BucketIndexer({
    required this.targetsStore,
    required this.recordStore,
    BucketOps? ops,
  }) : _ops = ops ?? BucketOps();

  final BackupTargetsStore targetsStore;
  final AssetRecordStore recordStore;
  final BucketOps _ops;

  /// True when every bucket was listed. An unreachable one keeps its old
  /// rows rather than being emptied by a failed request. Progress is saved
  /// page by page, so a listing cut short by a kill or a dropped connection
  /// resumes where it stopped; the old rows are only replaced once both
  /// folders are fully listed.
  Future<bool> refresh() async {
    final targets = await targetsStore.loadAll();
    await _forgetRemoved(targets);
    // Every folder of every bucket at once: it is a plain `ls`, and the
    // pages inside one folder are what has to stay in order.
    final results = await Future.wait([
      for (final target in targets)
        Future.wait([
          for (final dir in const ['originals/', 'thumbnails/'])
            _listDir(target, dir),
        ]).then((listed) => listed.every((ok) => ok)),
    ]);
    var all = true;
    for (var i = 0; i < targets.length; i++) {
      if (results[i]) {
        await recordStore.commitBucketScan(targets[i].id);
      } else {
        all = false;
      }
    }
    return all;
  }

  /// Drops the listing of any bucket no longer set up. Its files can't be
  /// fixed, imported or even read without its credentials, so offering
  /// them only fails.
  Future<void> forgetRemovedBuckets() async =>
      _forgetRemoved(await targetsStore.loadAll());

  Future<void> _forgetRemoved(List<S3BackupTarget> targets) async {
    // An empty answer is as likely a keychain hiccup as no buckets at all;
    // a listing left behind costs nothing, a lost one a full re-list.
    if (targets.isEmpty) return;
    final live = {for (final t in targets) t.id};
    for (final id in await recordStore.bucketTargetIds()) {
      if (live.contains(id)) continue;
      await recordStore.replaceBucketObjects(id, const []);
      await recordStore.discardBucketScan(id);
    }
  }

  Future<bool> _listDir(S3BackupTarget target, String dir) async {
    final progress = await recordStore.bucketScanProgress(target.id, dir);
    if (progress?.done ?? false) return true;
    return _ops.listFolderPages(
      target,
      dir,
      startToken: progress?.token,
      onPage: (page, next) =>
          recordStore.stageBucketPage(target.id, dir, next, [
            for (final o in page)
              BucketObject(
                targetId: target.id,
                key: o.key,
                size: o.size,
                lastModified: o.lastModified,
              ),
          ]),
    );
  }
}

/// What a scan found that the user can import, kept in `app_state` so the
/// Cloud settings row can say so without listing anything. Found, never
/// imported: bringing files in is always the user's tap.
class ImportOffer {
  const ImportOffer({required this.importable, required this.duplicates});

  static const none = ImportOffer(importable: 0, duplicates: 0);
  static const _key = 'bucket_import_offer';

  final int importable;
  final int duplicates;

  static Future<ImportOffer> read(AssetRecordStore store) async {
    final parts = (await store.getAppState(_key))?.split('|');
    if (parts == null || parts.length != 2) return none;
    return ImportOffer(
      importable: int.tryParse(parts[0]) ?? 0,
      duplicates: int.tryParse(parts[1]) ?? 0,
    );
  }

  Future<void> save(AssetRecordStore store) =>
      store.setAppState(_key, '$importable|$duplicates');
}

class ImportResult {
  const ImportResult({
    required this.imported,
    required this.unreachable,
    required this.left,
    this.duplicates = 0,
    this.importedIds = const [],
  });

  /// The records the batch created, so the caller can fetch just their
  /// thumbnails.
  final List<String> importedIds;

  final int imported;

  /// Objects left for the flagged page because an original of the same
  /// size is already known. Never imported or deleted automatically.
  final int duplicates;
  final bool unreachable;

  /// Flagged objects the batch could not fix on its own.
  final int left;
}

/// "Import from Bucket": refresh the listing, then rename-and-import every
/// flagged object that is a plain photo or video. The same Rename a person
/// would press on the flagged page, applied to all of them.
class BucketImport {
  BucketImport({
    required this.targetsStore,
    required this.recordStore,
    required Future<List<PassphraseEntry>> Function() passphrases,
    BucketOps? ops,
  }) : _indexer = BucketIndexer(
         targetsStore: targetsStore,
         recordStore: recordStore,
         ops: ops,
       ),
       _flags = BucketFlags(store: recordStore),
       _fixer = BucketFixer(
         store: recordStore,
         targetsStore: targetsStore,
         passphrases: passphrases,
         ops: ops,
       );

  final BackupTargetsStore targetsStore;
  final AssetRecordStore recordStore;
  final BucketIndexer _indexer;
  final BucketFlags _flags;
  final BucketFixer _fixer;

  /// Lists the buckets and records what could be imported, changing
  /// nothing. Run after the periodic listing; the Cloud row reads the result.
  Future<ImportOffer> scan({bool refresh = false}) async {
    if (refresh) await _indexer.refresh();
    final offer = _offerOf(await _flags.detect(inspect: _fixer.inspect));
    await offer.save(recordStore);
    return offer;
  }

  static ImportOffer _offerOf(List<FlaggedObject> flagged) {
    var importable = 0;
    var duplicates = 0;
    for (final f in flagged) {
      // Leftovers are listed on the flagged page, never offered as new.
      if (f.kind == FlagKind.orphanThumbnail ||
          f.kind == FlagKind.likelyLeftover) {
        continue;
      }
      f.likelyDuplicateOf == null ? importable++ : duplicates++;
    }
    return ImportOffer(importable: importable, duplicates: duplicates);
  }

  /// Progress of the import in flight, or null. Held on the class rather
  /// than a screen so leaving the page doesn't lose it, and a second tap
  /// can't start a second import over the first.
  static final ValueNotifier<({int done, int total})?> running = ValueNotifier(
    null,
  );

  /// [relist] false when the caller has just listed the buckets (the scan
  /// that found these files), so the same `ls` isn't paid for twice.
  Future<ImportResult> run({bool relist = true}) async {
    if (running.value != null) {
      return const ImportResult(imported: 0, unreachable: false, left: 0);
    }
    running.value = (done: 0, total: 0);
    try {
      return await _run(relist);
    } finally {
      running.value = null;
    }
  }

  Future<ImportResult> _run(bool relist) async {
    final listed = relist ? await _indexer.refresh() : true;
    final flaggedNow = await _flags.detect(inspect: _fixer.inspect);
    final todo = [
      for (final f in flaggedNow)
        if (f.kind != FlagKind.orphanThumbnail &&
            f.kind != FlagKind.likelyLeftover &&
            f.likelyDuplicateOf == null)
          f,
    ];
    final duplicates = flaggedNow
        .where(
          (f) =>
              f.kind != FlagKind.orphanThumbnail &&
              f.kind != FlagKind.likelyLeftover &&
              f.likelyDuplicateOf != null,
        )
        .length;
    var imported = 0;
    var left = 0;
    final importedIds = <String>[];
    running.value = (done: 0, total: todo.length);
    for (var i = 0; i < todo.length; i += fixConcurrency) {
      final results = await Future.wait(
        todo
            .skip(i)
            .take(fixConcurrency)
            .map(
              (f) => f.kind == FlagKind.unclaimed
                  ? _fixer.adopt(f)
                  : _fixer.rename(f),
            ),
      );
      for (final result in results) {
        if (result.outcome == FixOutcome.imported) {
          imported++;
          final id = result.localId;
          if (id != null) importedIds.add(id);
        } else if (!result.ok) {
          left++;
        }
      }
      final done = (i + fixConcurrency).clamp(0, todo.length);
      running.value = (done: done, total: todo.length);
      // The count the Cloud page shows falls as files land, so leaving and
      // coming back mid-way shows what is left, not what there was.
      await ImportOffer(
        importable: todo.length - done + left,
        duplicates: duplicates,
      ).save(recordStore);
    }
    return ImportResult(
      imported: imported,
      unreachable: !listed,
      left: left,
      duplicates: duplicates,
      importedIds: importedIds,
    );
  }

  static const fixConcurrency = 6;
}
