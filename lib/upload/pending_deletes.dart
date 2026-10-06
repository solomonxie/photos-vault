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
  const PendingDelete({
    required this.objectKey,
    required this.targetId,
    this.localId,
  });

  factory PendingDelete.fromJson(Map<String, dynamic> json) => PendingDelete(
    objectKey: json['k'] as String,
    targetId: json['t'] as String,
    localId: json['l'] as String?,
  );

  final String objectKey;

  /// Empty means "whichever bucket is configured": the task was made with
  /// none, and runs against every one once there is one.
  final String targetId;

  /// The photo whose upload may come to hold [objectKey] again — a hidden
  /// photo un-hidden before its retraction has run. A drain leaves a key
  /// alone while that photo's own upload holds it.
  final String? localId;

  PendingDelete forTarget(String id) =>
      PendingDelete(objectKey: objectKey, targetId: id, localId: localId);

  Map<String, dynamic> toJson() => {
    'k': objectKey,
    't': targetId,
    'l': ?localId,
  };

  @override
  bool operator ==(Object other) =>
      other is PendingDelete &&
      other.objectKey == objectKey &&
      other.targetId == targetId;

  @override
  int get hashCode => Object.hash(objectKey, targetId);
}

/// A bucket whose deletions keep failing — revoked key, deleted bucket.
class BlockedTarget {
  const BlockedTarget({required this.target, required this.waiting});

  final S3BackupTarget target;
  final int waiting;
}

/// Serialises read-modify-write on one `app_state` string: two concurrent
/// adds (a hide and a drain, two screens) would otherwise each write back
/// the list they read, and one task would be lost.
class _Lock {
  Future<void> _tail = Future.value();

  Future<T> run<T>(Future<T> Function() body) {
    final result = _tail.then((_) => body());
    _tail = result.then<void>((_) {}, onError: (_) {});
    return result;
  }
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
  static const _failsKey = 'pending_object_delete_fails';
  static final _lock = _Lock();

  /// Drain passes in a row on which every attempt at one bucket failed,
  /// before it is called blocked.
  static const blockedAfter = 3;

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

  Future<void> add(Iterable<PendingDelete> tasks) => _lock.run(() async {
    final all = {...await pending(), ...tasks};
    await _write(all);
  });

  Future<void> _write(Iterable<PendingDelete> tasks) =>
      store.setAppState(_key, jsonEncode([for (final t in tasks) t.toJson()]));

  Future<Map<String, int>> _fails() async {
    final raw = await store.getAppState(_failsKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      return (jsonDecode(raw) as Map<String, dynamic>).cast<String, int>();
    } catch (_) {
      return {};
    }
  }

  /// Buckets that have failed every deletion for [blockedAfter] passes.
  /// Their tasks stay queued; this is what lets the screen say so, and
  /// offer [forgetTarget], instead of leaving a delete silently pending.
  Future<List<BlockedTarget>> blocked(List<S3BackupTarget> targets) async {
    final fails = await _fails();
    final tasks = await pending();
    return [
      for (final target in targets)
        if ((fails[target.id] ?? 0) >= blockedAfter)
          BlockedTarget(
            target: target,
            waiting: tasks
                .where((t) => t.targetId == target.id || t.targetId.isEmpty)
                .length,
          ),
    ];
  }

  /// Gives up on what is still owed to [targetId]: the bucket is dead and
  /// the user says so. The objects stay wherever they are.
  Future<void> forgetTarget(String targetId) => _lock.run(() async {
    await _write([
      for (final t in await pending())
        if (t.targetId != targetId) t,
    ]);
    final fails = await _fails()
      ..remove(targetId);
    await store.setAppState(_failsKey, jsonEncode(fails));
  });

  /// Whether the photo's own upload holds [task]'s key right now.
  Future<bool> _heldNow(PendingDelete task) async {
    final id = task.localId;
    if (id == null) return false;
    for (final kind in DerivativeKind.values) {
      final held = await store.targetsHolding(id, kind);
      if (task.targetId.isEmpty
          ? held.containsValue(task.objectKey)
          : held[task.targetId] == task.objectKey) {
        return true;
      }
    }
    return false;
  }

  /// Tries every task whose target is still configured. Returns how many
  /// are left, including the dormant ones.
  ///
  /// A task made with no bucket configured is expanded into one per bucket
  /// the first time there is one.
  Future<int> drain(List<S3BackupTarget> targets) async {
    final tasks = await pending();
    if (tasks.isEmpty) return 0;
    final byId = {for (final t in targets) t.id: t};
    final wildcards = targets.isEmpty
        ? const <PendingDelete>[]
        : [
            for (final t in tasks)
              if (t.targetId.isEmpty) t,
          ];
    final work = [
      for (final t in tasks)
        if (t.targetId.isEmpty)
          for (final target in targets) t.forTarget(target.id)
        else
          t,
    ];
    final done = <PendingDelete>{};
    final attempted = <String, int>{};
    final succeeded = <String, int>{};
    for (final task in work) {
      final target = byId[task.targetId];
      if (target == null) continue; // Dormant, not dropped.
      if (await _heldNow(task)) {
        done.add(task); // A fresh upload owns this key now.
        continue;
      }
      attempted[target.id] = (attempted[target.id] ?? 0) + 1;
      if (await _delete(target: target, key: task.objectKey)) {
        done.add(task);
        succeeded[target.id] = (succeeded[target.id] ?? 0) + 1;
      }
    }
    // Re-read, under the lock, rather than write back what was read before
    // the network round trips: a task added meanwhile (a hide, another
    // drain) would otherwise be overwritten and never run.
    return _lock.run(() async {
      final expanded = {for (final t in wildcards) t};
      final left = <PendingDelete>[];
      for (final t in await pending()) {
        if (expanded.contains(t)) {
          left.addAll([
            for (final target in targets)
              if (!done.contains(t.forTarget(target.id)))
                t.forTarget(target.id),
          ]);
        } else if (!done.contains(t)) {
          left.add(t);
        }
      }
      await _write(left);
      final fails = await _fails();
      for (final MapEntry(key: id, value: n) in attempted.entries) {
        if ((succeeded[id] ?? 0) > 0) {
          fails.remove(id);
        } else if (n > 0) {
          fails[id] = (fails[id] ?? 0) + 1;
        }
      }
      await store.setAppState(_failsKey, jsonEncode(fails));
      return left.length;
    });
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
  static final _lock = _Lock();

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
    await _lock.run(() async {
      final all = {...await waiting()};
      all[localId] = {...?all[localId], ...tasks}.toList();
      await _write(all);
    });
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
    await _lock.run(() async {
      final left = {...await waiting()}
        ..removeWhere((id, _) => released.contains(id));
      await _write(left);
    });
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
