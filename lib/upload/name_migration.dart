import 'package:path/path.dart' as p;

import '../settings/backup_targets_store.dart';
import '../settings/s3_backup_target.dart';
import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import '../storage/bucket_object.dart';
import '../vault/object_key.dart';
import 'bucket_ops.dart';
import 'object_keys.dart';

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

  static final _tail = RegExp(
    r'^(.*?)((?:originals|thumbnails|medium)/[^/]+)$',
  );

  /// Re-points a record whose key names another prefix (the bucket's folder
  /// was renamed, or the connection moved) at the object that really is in
  /// the bucket under this target's prefix. Returns how many keys were
  /// repaired.
  ///
  /// The listing only nominates. A key is re-pointed when a live HEAD says
  /// it is gone (404, not "no answer") and another says the new one is
  /// there; only to a file of the same kind (a Live Photo's `.mov` is never
  /// its still); and never to another format older than the upload it
  /// replaces. Call it only after a listing that fully succeeded.
  Future<int> healPrefixes() async {
    final targets = {for (final t in await targetsStore.loadAll()) t.id: t};
    if (targets.isEmpty) return 0;
    final listed = <String, Map<String, BucketObject>>{};
    for (final o in await store.listBucketObjects()) {
      (listed[o.targetId] ??= {})[o.key] = o;
    }
    if (listed.isEmpty) return 0;
    // Same folder and name, another format: what a re-encode in the bucket
    // leaves when a record kept the old extension.
    final byStem = <String, Map<String, List<BucketObject>>>{};
    for (final MapEntry(key: targetId, value: objects) in listed.entries) {
      for (final o in objects.values) {
        ((byStem[targetId] ??= {})[p.withoutExtension(o.key)] ??= []).add(o);
      }
    }
    // One query for every upload row, not one per record and kind.
    final rows = <String, Map<DerivativeKind, Map<String, int>>>{};
    final uploadRows = await store.uploadRows();
    final heldAll = groupUploads(uploadRows);
    for (final row in uploadRows) {
      final kind = DerivativeKind.values.asNameMap()[row['kind']];
      if (kind == null) continue;
      ((rows[row['local_id'] as String] ??= {})[kind] ??= {})[row['target_id']
              as String] =
          row['uploaded_at'] as int? ?? 0;
    }
    var healed = 0;
    for (final record in await store.listAll()) {
      if (record.passcodeHash != null) continue;
      for (final kind in DerivativeKind.values) {
        final state = record.stateOf(kind);
        final key = state.destinationKey;
        if (key == null) continue;
        final held = heldAll[record.localId]?[kind] ?? const <String, String>{};
        final firstTarget = held.isNotEmpty
            ? held.keys.first
            : targets.keys.first;
        final target = targets[firstTarget];
        final seen = listed[firstTarget];
        if (target == null || seen == null || seen.containsKey(key)) continue;
        final tail = _tail.firstMatch(key)?[2];
        if (tail == null) continue;
        final exact = '${target.prefix}$tail';
        final BucketObject? candidate;
        if (seen[exact] case final o?) {
          candidate = o;
        } else {
          final formats = byStem[firstTarget]?[p.withoutExtension(exact)];
          if (formats == null || formats.length != 1) continue;
          final other = formats.single;
          final uploadedAt = rows[record.localId]?[kind]?[firstTarget] ?? 0;
          if (other.lastModified.millisecondsSinceEpoch < uploadedAt) continue;
          candidate = other;
        }
        final rebased = candidate.key;
        if (rebased == key || isVideoKey(rebased) != isVideoKey(key)) continue;
        if ((await _ops.head(target, key)).state != Probe.absent) continue;
        if (!(await _ops.head(target, rebased)).isPresent) continue;
        for (final entry in held.entries) {
          await store.renameUploadKey(
            localId: record.localId,
            kind: kind,
            targetId: entry.key,
            destinationKey: rebased,
          );
        }
        await store.updateDerivative(
          record.localId,
          kind,
          state.copyWith(destinationKey: rebased),
        );
        healed++;
      }
    }
    return healed;
  }

  /// Records migrated this run; zero means there is nothing left to do.
  /// [listed] false when the listing just taken failed: then nothing is
  /// healed off it.
  Future<int> run({int limit = 25, bool listed = true}) async {
    final targets = {for (final t in await targetsStore.loadAll()) t.id: t};
    if (targets.isEmpty) return 0;
    if (listed) await healPrefixes();
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

  /// Per kind: copy to every bucket and check each, then move the rows,
  /// and only then retire the old keys, through the guard with the new
  /// copy as the keeper.
  Future<bool> _migrate(
    AssetRecord record,
    Map<String, S3BackupTarget> targets,
  ) async {
    final base = ordinaryBaseName(record);
    var allMoved = true;
    for (final kind in DerivativeKind.values) {
      final state = record.stateOf(kind);
      final firstKey = state.destinationKey;
      if (firstKey == null || fitsProtocol(p.basename(firstKey))) continue;
      final held = await store.targetsHolding(record.localId, kind);
      if (held.isEmpty) allMoved = false;
      final moved =
          <({S3BackupTarget target, String from, String to, int size})>[];
      for (final entry in held.entries) {
        final target = targets[entry.key];
        if (target == null) {
          allMoved = false;
          continue;
        }
        final oldKey = entry.value;
        final newKey = '${p.dirname(oldKey)}/$base${p.extension(oldKey)}';
        final size = (await _ops.head(target, oldKey)).size;
        if (size == null) {
          allMoved = false;
          continue;
        }
        final there = (await _ops.head(target, newKey)).size == size;
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
        moved.add((target: target, from: oldKey, to: newKey, size: size));
      }
      final newFirst = [
        for (final m in moved)
          if (m.from == firstKey) m.to,
      ].firstOrNull;
      if (newFirst != null) {
        await store.updateDerivative(
          record.localId,
          kind,
          state.copyWith(destinationKey: newFirst),
        );
      }
      for (final m in moved) {
        await _ops.deleteGuarded(
          m.target,
          m.from,
          store: store,
          keep: Keeper(m.to, size: m.size),
        );
      }
    }
    return allMoved;
  }
}
