import 'package:path/path.dart' as p;

import '../settings/s3_backup_target.dart';
import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import 'pending_deletes.dart';
import 'signing.dart';

const derivativeDirs = {
  DerivativeKind.thumbnail: 'thumbnails',
  DerivativeKind.medium: 'medium',
  DerivativeKind.original: 'originals',
  // Beside the still it belongs to: the two halves are one photo, sharing a
  // base name and differing only by extension.
  DerivativeKind.livePhoto: 'originals',
};

/// `targetId` → key, for one derivative. See `AssetRecordStore.targetsHolding`.
typedef HeldKeys = Map<DerivativeKind, Map<String, String>>;

/// Groups the rows of `AssetRecordStore.uploadRows` by photo, in one pass —
/// one query for the whole library rather than one per photo.
Map<String, HeldKeys> groupUploads(List<Map<String, Object?>> rows) {
  final out = <String, HeldKeys>{};
  for (final row in rows) {
    final kind = DerivativeKind.values.asNameMap()[row['kind'] as String?];
    if (kind == null) continue;
    final held = out.putIfAbsent(row['local_id'] as String, () => {});
    (held[kind] ??= {})[row['target_id'] as String] =
        row['destination_key'] as String;
  }
  return out;
}

/// What each bucket holds of one photo — four small reads, for the single
/// photo case; [groupUploads] is the bulk one.
Future<HeldKeys> heldKeysOf(AssetRecordStore store, String localId) async => {
  for (final kind in DerivativeKind.values)
    kind: await store.targetsHolding(localId, kind),
};

/// Where [kind] of [record] lives in [target]'s bucket, or null when the
/// record has no upload to name.
///
/// The key the row recorded for that very target wins. Without one, the key
/// is rebuilt from the protocol layout (`<prefix><dir>/<file name>`) with
/// *this* target's prefix: the record's single `destinationKey` carries the
/// first bucket's prefix, and used as-is against another bucket it is a 404
/// that reads as "gone" while the real object stays.
String? remoteKeyFor({
  required AssetRecord record,
  required DerivativeKind kind,
  required S3BackupTarget target,
  required Map<String, String> held,
}) {
  final exact = held[target.id];
  if (exact != null) return exact;
  final source =
      held[''] ??
      held.values.firstOrNull ??
      record.stateOf(kind).destinationKey;
  if (source == null) return null;
  return derivativeKey(
    prefix: target.prefix,
    derivativeDir: derivativeDirs[kind]!,
    fileName: p.posix.basename(source),
  );
}

/// Every object [record] has in a bucket, as deletions: one per derivative
/// per configured bucket, each under that bucket's own key.
///
/// A bucket the rows name but that is no longer configured gets a dormant
/// task of its own. With no bucket configured at all the tasks name no
/// target (`targetId` empty) and wait for one to be added, rather than
/// being skipped — dropping them orphans the objects with nothing left
/// pointing at them.
///
/// Names the photo ([PendingDelete.localId]) so a drain can tell that a
/// fresh upload now holds the same key and leave it alone.
List<PendingDelete> deletionTasksFor(
  AssetRecord record,
  List<S3BackupTarget> targets,
  HeldKeys held,
) {
  final tasks = <PendingDelete>{};
  for (final kind in DerivativeKind.values) {
    final heldKind = held[kind] ?? const <String, String>{};
    if (targets.isEmpty) {
      for (final MapEntry(key: id, value: key) in heldKind.entries) {
        tasks.add(
          PendingDelete(objectKey: key, targetId: id, localId: record.localId),
        );
      }
      final unnamed = record.stateOf(kind).destinationKey;
      if (unnamed != null && !heldKind.values.contains(unnamed)) {
        tasks.add(
          PendingDelete(
            objectKey: unnamed,
            targetId: '',
            localId: record.localId,
          ),
        );
      }
      continue;
    }
    for (final target in targets) {
      final key = remoteKeyFor(
        record: record,
        kind: kind,
        target: target,
        held: heldKind,
      );
      if (key == null) continue;
      tasks.add(
        PendingDelete(
          objectKey: key,
          targetId: target.id,
          localId: record.localId,
        ),
      );
    }
    final configured = {for (final t in targets) t.id};
    for (final MapEntry(key: id, value: key) in heldKind.entries) {
      if (id.isEmpty || configured.contains(id)) continue;
      tasks.add(
        PendingDelete(objectKey: key, targetId: id, localId: record.localId),
      );
    }
  }
  return tasks.toList();
}
