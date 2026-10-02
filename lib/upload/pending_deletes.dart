import 'dart:convert';

import '../settings/s3_backup_target.dart';
import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import 's3_object_delete.dart';

/// Objects that must leave the bucket, kept until they actually have.
///
/// Hiding a photo that was already backed up has to undo that backup, and
/// hiding happens offline constantly — on a plane, in a lift, with an
/// expired credential. So this is **not** best-effort: a task sits here and
/// retries on every sync for as long as it takes. It ends exactly two ways:
/// the object is gone, or the photo itself is gone and there is nothing
/// left to clean up after.
///
/// `404` counts as gone — the right bucket, no such key, somebody removed
/// it by hand. Nothing else does. Reading `403` as "not there" is precisely
/// how a plain copy of a hidden photo gets left in a bucket while the app
/// reports itself clean ([deleteObject] already draws that line: it accepts
/// 200/204/404 and refuses everything else).
///
/// A task names its target, and a target removed from the app leaves its
/// tasks **dormant** rather than dropping them: re-add that bucket and they
/// run. The only place they are dropped is when the bucket they name has
/// been forgotten *and* the user asks to forget it all.
class PendingDelete {
  const PendingDelete({required this.objectKey, required this.targetId});

  factory PendingDelete.fromJson(Map<String, dynamic> json) => PendingDelete(
    objectKey: json['k'] as String,
    targetId: json['t'] as String,
  );

  final String objectKey;
  final String targetId;

  Map<String, dynamic> toJson() => {'k': objectKey, 't': targetId};

  @override
  bool operator ==(Object other) =>
      other is PendingDelete &&
      other.objectKey == objectKey &&
      other.targetId == targetId;

  @override
  int get hashCode => Object.hash(objectKey, targetId);
}

class PendingDeletes {
  PendingDeletes({
    required this.store,
    Future<bool> Function({
      required S3BackupTarget target,
      required String key,
    })?
    delete,
  }) : _delete = delete ?? _defaultDelete;

  final AssetRecordStore store;
  final Future<bool> Function({
    required S3BackupTarget target,
    required String key,
  })
  _delete;

  static Future<bool> _defaultDelete({
    required S3BackupTarget target,
    required String key,
  }) => deleteObject(target: target, key: key);

  static const _key = 'pending_object_deletes';

  Future<List<PendingDelete>> pending() async {
    final raw = await store.getAppState(_key);
    if (raw == null || raw.isEmpty) return const [];
    try {
      return [
        for (final e in jsonDecode(raw) as List)
          PendingDelete.fromJson(e as Map<String, dynamic>),
      ];
    } catch (_) {
      // Unreadable row. Dropping the list would leave plain copies in a
      // bucket forever with nothing pointing at them, so treat it as empty
      // and let the next hide re-queue what it knows about.
      return const [];
    }
  }

  Future<int> count() async => (await pending()).length;

  Future<void> add(Iterable<PendingDelete> tasks) async {
    final all = {...await pending(), ...tasks};
    await store.setAppState(
      _key,
      jsonEncode([for (final t in all) t.toJson()]),
    );
  }

  /// Tries every task whose target is still configured. Returns how many
  /// are left, including the dormant ones.
  Future<int> drain(List<S3BackupTarget> targets) async {
    final tasks = await pending();
    if (tasks.isEmpty) return 0;
    final byId = {for (final t in targets) t.id: t};
    final done = <PendingDelete>{};
    for (final task in tasks) {
      final target = byId[task.targetId];
      if (target == null) continue; // Dormant, not dropped.
      if (await _delete(target: target, key: task.objectKey)) done.add(task);
    }
    // Re-read rather than write back what was read before the network
    // round trips: a task added meanwhile (a hide, another drain) would
    // otherwise be overwritten and never run.
    final left = [
      for (final t in await pending())
        if (!done.contains(t)) t,
    ];
    await store.setAppState(
      _key,
      jsonEncode([for (final t in left) t.toJson()]),
    );
    return left.length;
  }
}

/// Carrier copies an un-hidden photo leaves in the buckets, held back until
/// that photo's plain upload has reached every bucket. Until then the
/// carrier is the only remote copy, and deleting it first is a window in
/// which losing the phone loses the photo.
///
/// Keyed by the plain photo's `localId`. A photo that never comes back (its
/// record gone) leaves its group waiting: an unused object, never a lost
/// photo.
class DeferredDeletes {
  DeferredDeletes({required this.store, PendingDeletes? pending})
    : _pending = pending ?? PendingDeletes(store: store);

  final AssetRecordStore store;
  final PendingDeletes _pending;

  static const _key = 'deferred_object_deletes';

  Future<Map<String, List<PendingDelete>>> waiting() async {
    final raw = await store.getAppState(_key);
    if (raw == null || raw.isEmpty) return const {};
    try {
      return {
        for (final e in (jsonDecode(raw) as Map<String, dynamic>).entries)
          e.key: [
            for (final t in e.value as List)
              PendingDelete.fromJson(t as Map<String, dynamic>),
          ],
      };
    } catch (_) {
      return const {};
    }
  }

  Future<void> add(String localId, Iterable<PendingDelete> tasks) async {
    if (tasks.isEmpty) return;
    final all = {...await waiting()};
    all[localId] = {...?all[localId], ...tasks}.toList();
    await _write(all);
  }

  /// Hands every group whose photo is now fully backed up to
  /// [PendingDeletes]. A key the photo's own upload now holds is dropped,
  /// not deleted: a plain JPEG goes up under the name its carrier had, and
  /// overwrote it. Returns how many tasks were released.
  ///
  /// One lookup per waiting photo — bounded by photos un-hidden and not yet
  /// re-uploaded, never by library size.
  Future<int> release() async {
    final groups = await waiting();
    if (groups.isEmpty) return 0;
    final ready = <PendingDelete>[];
    final released = <String>{};
    for (final MapEntry(key: localId, value: tasks) in groups.entries) {
      final record = await store.getByLocalId(localId);
      if (record == null || !record.isFullyBackedUp) continue;
      final held = <String>{
        for (final kind in DerivativeKind.values) ...[
          ...(await store.targetsHolding(localId, kind)).values,
          ?record.stateOf(kind).destinationKey,
        ],
      };
      ready.addAll(tasks.where((t) => !held.contains(t.objectKey)));
      released.add(localId);
    }
    if (released.isEmpty) return 0;
    await _pending.add(ready);
    // Re-read: a group added meanwhile must survive this write.
    final left = {...await waiting()}
      ..removeWhere((id, _) => released.contains(id));
    await _write(left);
    return ready.length;
  }

  Future<void> _write(Map<String, List<PendingDelete>> groups) =>
      store.setAppState(
        _key,
        jsonEncode({
          for (final e in groups.entries)
            e.key: [for (final t in e.value) t.toJson()],
        }),
      );
}
