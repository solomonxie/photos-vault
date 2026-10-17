import 'dart:convert';

import '../settings/s3_backup_target.dart';
import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import '../vault/bucket.dart';
import 'bucket_ops.dart';

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
/// reports itself clean (the raw DELETE already draws that line: it accepts
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
    this.carrier = false,
    this.keep,
    this.untilWhole = false,
  });

  factory PendingDelete.fromJson(Map<String, dynamic> json) => PendingDelete(
    objectKey: json['k'] as String,
    targetId: json['t'] as String,
    localId: json['l'] as String?,
    carrier: json['c'] == true,
    keep: json['p'] as String?,
    untilWhole: json['w'] == true,
  );

  final String objectKey;

  /// Empty means "whichever bucket is configured": the task was made with
  /// none, and runs against every one once there is one.
  final String targetId;

  /// The photo whose upload may come to hold [objectKey] again — a hidden
  /// photo un-hidden before its retraction has run. A drain leaves a key
  /// alone while that photo's own upload holds it.
  final String? localId;

  /// A hidden photo's carrier the vault retired (a permanent delete, or an
  /// un-hide whose plain copy is up). Every other task that finds a carrier
  /// under its key is refused.
  final bool carrier;

  /// The copy that stays in its place, in the same bucket: proven live
  /// (`BucketOps.deleteGuarded`'s keeper) right before this one goes.
  final String? keep;

  /// An older copy an upload superseded: waits while [localId] isn't
  /// backed up whole (`AssetRecord.isFullyBackedUp`), so a photo's old
  /// render never goes before its new original *and* edit are both up.
  final bool untilWhole;

  PendingDelete forTarget(String id, {String? key}) => PendingDelete(
    objectKey: key ?? objectKey,
    targetId: id,
    localId: localId,
    carrier: carrier,
    keep: keep,
    untilWhole: untilWhole,
  );

  PendingDelete asCarrier() => PendingDelete(
    objectKey: objectKey,
    targetId: targetId,
    localId: localId,
    carrier: true,
    keep: keep,
    untilWhole: untilWhole,
  );

  PendingDelete keeping(String key, {required bool carrier}) => PendingDelete(
    objectKey: objectKey,
    targetId: targetId,
    localId: localId,
    carrier: carrier,
    keep: key,
    untilWhole: untilWhole,
  );

  Map<String, dynamic> toJson() => {
    'k': objectKey,
    't': targetId,
    'l': ?localId,
    if (carrier) 'c': true,
    'p': ?keep,
    if (untilWhole) 'w': true,
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
  PendingDeletes({required this.store, BucketOps? ops})
    : _ops = ops ?? BucketOps();

  final AssetRecordStore store;
  final BucketOps _ops;

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

  /// A carrier task made with no bucket names the album's relative key;
  /// each bucket has it under its own prefix.
  static String keyIn(S3BackupTarget target, PendingDelete task) =>
      task.carrier && _relative.hasMatch(task.objectKey)
      ? VaultBucket.resolveKey(target, task.objectKey)
      : task.objectKey;

  static final _relative = RegExp(r'^(originals|thumbnails|medium)/');

  /// An upload that landed on [key] between the checks and the DELETE
  /// (an un-hide re-upload) lost its object: its row goes, and the photo
  /// is sent again. Rare, so one pass over the rows is fine here.
  Future<void> _requeueIfTaken(S3BackupTarget target, String key) async {
    if (!await store.keyHeldByOthers(key, null)) return;
    for (final row in await store.uploadRows()) {
      if (row['destination_key'] != key) continue;
      final id = row['local_id'] as String;
      final kind = DerivativeKind.values.asNameMap()[row['kind']];
      final rowTarget = row['target_id'] as String;
      if (kind == null || (rowTarget != target.id && rowTarget.isNotEmpty)) {
        continue;
      }
      await store.forgetTargetUpload(id, kind, rowTarget);
      final record = await store.getByLocalId(id);
      if (record == null) continue;
      await store.updateDerivative(
        id,
        kind,
        record.stateOf(kind).copyWith(status: UploadStatus.pending),
      );
    }
  }

  /// [localId] backed up whole, or gone (its keeper still has to prove
  /// itself live).
  Future<bool> _whole(String? localId) async {
    if (localId == null) return true;
    final record = await store.getByLocalId(localId);
    return record == null || record.isFullyBackedUp;
  }

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

  /// Tries every task whose target is still configured, each through
  /// [BucketOps.deleteGuarded]. Returns how many are left, including the
  /// dormant ones.
  ///
  /// A task made with no bucket configured is expanded into one per bucket
  /// the first time there is one.
  ///
  /// Dropped, not deleted: a key a record holds, and a carrier the vault
  /// did not ask for. Kept: anything a check couldn't answer.
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
          for (final target in targets)
            (task: t.forTarget(target.id), key: keyIn(target, t))
        else
          (task: t, key: t.objectKey),
    ];
    final done = <PendingDelete>{};
    final attempted = <String, int>{};
    final succeeded = <String, int>{};
    for (final (:task, :key) in work) {
      final target = byId[task.targetId];
      if (target == null) continue; // Dormant, not dropped.
      if (await _heldNow(task)) {
        done.add(task); // Someone's backup still: never this delete's.
        continue;
      }
      if (task.untilWhole && !await _whole(task.localId)) continue;
      final keep = task.keep;
      final outcome = await _ops.deleteGuarded(
        target,
        key,
        store: store,
        keep: keep == null ? null : Keeper(keep),
        carrierProof: task.carrier,
      );
      switch (outcome) {
        case DeleteOutcome.deleted || DeleteOutcome.gone:
          done.add(task);
          attempted[target.id] = (attempted[target.id] ?? 0) + 1;
          succeeded[target.id] = (succeeded[target.id] ?? 0) + 1;
          if (outcome == DeleteOutcome.deleted) {
            await _requeueIfTaken(target, key);
          }
        case DeleteOutcome.held || DeleteOutcome.carrier:
          done.add(task);
        case DeleteOutcome.keeperUnproven:
          // Waits for its keeper; not the bucket failing.
          break;
        case _:
          attempted[target.id] = (attempted[target.id] ?? 0) + 1;
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

/// Deletes held back until another copy of the photo is in every bucket,
/// keyed by the `localId` of the photo whose upload that copy is. Each is
/// released with that copy as its keeper, proven live by the drain.
///
/// Two lists, one rule:
///
/// - the default: carriers an un-hide (or a hidden photo's replaced
///   original) leaves behind, waiting for the plain copy (or the new
///   copy's carrier). Until then the carrier is the only remote copy.
/// - [DeferredDeletes.untilCarrier]: plain copies a hide retracts, waiting
///   for the photo's carrier. Dropped, not deleted, if the photo is
///   un-hidden first: they are its backup again.
///
/// A photo that never comes back (its record gone) leaves its group
/// waiting: an unused object, never a lost photo.
class DeferredDeletes {
  DeferredDeletes({required this.store, PendingDeletes? pending})
    : _pending = pending ?? PendingDeletes(store: store),
      _key = 'deferred_object_deletes',
      _forHide = false;

  DeferredDeletes.untilCarrier({required this.store, PendingDeletes? pending})
    : _pending = pending ?? PendingDeletes(store: store),
      _key = 'hide_held_deletes',
      _forHide = true;

  final AssetRecordStore store;
  final PendingDeletes _pending;
  final String _key;
  final bool _forHide;

  static final _locks = <String, _Lock>{};
  _Lock get _lock => _locks[_key] ??= _Lock();

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

  /// Takes [localId]'s group out without deleting anything, and returns it.
  Future<List<PendingDelete>> take(String localId) async {
    if (!(await waiting()).containsKey(localId)) return const [];
    return _lock.run(() async {
      final all = {...await waiting()};
      final group = all.remove(localId);
      if (group != null) await _write(all);
      return group ?? const [];
    });
  }

  /// Hands every task whose keeper is up to [PendingDeletes], each naming
  /// that keeper. A key the photo itself now holds is dropped, not
  /// deleted: an upload landed on it. A task made with no bucket is
  /// expanded over [targets], and waits while there are none. Returns how
  /// many tasks were released.
  ///
  /// One lookup per waiting photo — bounded by photos in transition, never
  /// by library size.
  Future<int> release([List<S3BackupTarget> targets = const []]) async {
    final groups = await waiting();
    if (groups.isEmpty) return 0;
    final ready = <PendingDelete>[];
    final settled = <String, List<PendingDelete>>{};
    for (final MapEntry(key: localId, value: tasks) in groups.entries) {
      final record = await store.getByLocalId(localId);
      if (record == null) continue;
      if (_forHide && record.passcodeHash == null) {
        settled[localId] = const [];
        continue;
      }
      if (!record.isFullyBackedUp) continue;
      final keepers = await store.targetsHolding(
        localId,
        DerivativeKind.original,
      );
      final held = <String>{
        for (final kind in DerivativeKind.values) ...[
          ...(await store.targetsHolding(localId, kind)).values,
          ?record.stateOf(kind).destinationKey,
        ],
      };
      final left = <PendingDelete>[];
      for (final task in tasks) {
        final each = task.targetId.isNotEmpty
            ? [task]
            : [
                for (final t in targets)
                  task.forTarget(t.id, key: PendingDeletes.keyIn(t, task)),
              ];
        if (each.isEmpty) left.add(task);
        for (final t in each) {
          if (held.contains(t.objectKey)) continue;
          final keep =
              keepers[t.targetId] ??
              keepers[''] ??
              record.stateOf(DerivativeKind.original).destinationKey;
          if (keep == null || keep == t.objectKey) {
            left.add(t);
            continue;
          }
          // Un-hide groups are carriers by construction; hide groups are
          // plain copies, which the guard refuses if they turn out not to be.
          ready.add(t.keeping(keep, carrier: !_forHide));
        }
      }
      settled[localId] = left;
    }
    if (settled.isEmpty) return 0;
    if (ready.isNotEmpty) await _pending.add(ready);
    // Re-read: a group added meanwhile must survive this write.
    await _lock.run(() async {
      final all = {...await waiting()};
      for (final MapEntry(key: id, value: left) in settled.entries) {
        final added = {...?all[id]}.difference({...?groups[id]});
        final rest = [...left, ...added];
        if (rest.isEmpty) {
          all.remove(id);
        } else {
          all[id] = rest;
        }
      }
      await _write(all);
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
