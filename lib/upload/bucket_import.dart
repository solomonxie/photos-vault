import '../settings/backup_targets_store.dart';
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
  /// rows rather than being emptied by a failed request.
  Future<bool> refresh() async {
    var all = true;
    for (final target in await targetsStore.loadAll()) {
      final originals = await _ops.listFolder(target, 'originals/');
      final thumbnails = await _ops.listFolder(target, 'thumbnails/');
      if (originals == null || thumbnails == null) {
        all = false;
        continue;
      }
      await recordStore.replaceBucketObjects(target.id, [
        for (final o in [...originals, ...thumbnails])
          BucketObject(
            targetId: target.id,
            key: o.key,
            size: o.size,
            lastModified: o.lastModified,
          ),
      ]);
    }
    return all;
  }
}

class ImportResult {
  const ImportResult({
    required this.imported,
    required this.unreachable,
    required this.left,
  });

  final int imported;
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

  Future<ImportResult> run() async {
    final listed = await _indexer.refresh();
    var imported = 0;
    var left = 0;
    for (final flagged in await _flags.detect()) {
      if (flagged.kind != FlagKind.offProtocol) continue;
      final result = await _fixer.rename(flagged);
      if (result.outcome == FixOutcome.imported) {
        imported++;
      } else if (!result.ok) {
        left++;
      }
    }
    return ImportResult(imported: imported, unreachable: !listed, left: left);
  }
}
