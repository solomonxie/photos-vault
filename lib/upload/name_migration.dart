import 'package:path/path.dart' as p;

import '../settings/backup_targets_store.dart';
import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import '../vault/object_key.dart';
import 'bucket_ops.dart';

/// Gives photos backed up under the old `photo_<id>` names a protocol name,
/// a few at a time, so the bucket ends up with one naming scheme.
///
/// Per object: copy inside the bucket, check the size, point the database
/// at the new key, and only then delete the old. Interrupted anywhere, the
/// old name still works and the next run carries on.
class NameMigration {
  NameMigration({
    required this.store,
    required this.targetsStore,
    BucketOps? ops,
  }) : _ops = ops ?? BucketOps();

  final AssetRecordStore store;
  final BackupTargetsStore targetsStore;
  final BucketOps _ops;

  /// Records migrated this run; zero means there is nothing left to do.
  Future<int> run({int limit = 25}) async {
    final targets = {for (final t in await targetsStore.loadAll()) t.id: t};
    if (targets.isEmpty) return 0;
    var done = 0;
    for (final record in await store.listAll()) {
      if (done >= limit) break;
      // Hidden photos migrate with their album, and a deleted one may still
      // have its old key queued for removal.
      if (record.passcodeHash != null || record.deletedAt != null) continue;
      if (!_stale(record)) continue;
      if (await _migrate(record, targets)) done++;
    }
    return done;
  }

  bool _stale(AssetRecord record) {
    for (final kind in DerivativeKind.values) {
      final key = record.stateOf(kind).destinationKey;
      if (key != null && !fitsProtocol(p.basename(key))) return true;
    }
    return false;
  }

  Future<bool> _migrate(
    AssetRecord record,
    Map<String, dynamic> targets,
  ) async {
    final base = ordinaryBaseName(record);
    var allMoved = true;
    for (final kind in DerivativeKind.values) {
      final state = record.stateOf(kind);
      final firstKey = state.destinationKey;
      if (firstKey == null || fitsProtocol(p.basename(firstKey))) continue;
      final held = await store.targetsHolding(record.localId, kind);
      if (held.isEmpty) allMoved = false;
      String? newFirst;
      for (final entry in held.entries) {
        final target = targets[entry.key];
        if (target == null) {
          allMoved = false;
          continue;
        }
        final oldKey = entry.value;
        final newKey = '${p.dirname(oldKey)}/$base${p.extension(oldKey)}';
        final size = await _ops.sizeOf(target, oldKey);
        if (size == null) {
          allMoved = false;
          continue;
        }
        final there = await _ops.sizeOf(target, newKey) == size;
        if (!there &&
            !await _ops.copy(
              target: target,
              from: oldKey,
              to: newKey,
              expectedSize: size,
            )) {
          allMoved = false;
          continue;
        }
        await store.renameUploadKey(
          localId: record.localId,
          kind: kind,
          targetId: entry.key,
          destinationKey: newKey,
        );
        await _ops.delete(target, oldKey);
        if (oldKey == firstKey) newFirst = newKey;
      }
      if (newFirst != null) {
        await store.updateDerivative(
          record.localId,
          kind,
          state.copyWith(destinationKey: newFirst),
        );
      }
    }
    return allMoved;
  }
}
