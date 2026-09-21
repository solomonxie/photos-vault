import 'dart:convert';

import '../settings/s3_backup_target.dart';
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
    final left = <PendingDelete>[];
    for (final task in tasks) {
      final target = byId[task.targetId];
      if (target == null) {
        left.add(task); // Dormant, not dropped.
        continue;
      }
      if (!await _delete(target: target, key: task.objectKey)) left.add(task);
    }
    await store.setAppState(
      _key,
      jsonEncode([for (final t in left) t.toJson()]),
    );
    return left.length;
  }
}
