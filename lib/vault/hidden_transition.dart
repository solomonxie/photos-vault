import 'dart:convert';

import '../photos/ai_analysis_store.dart';
import '../photos/face_identity.dart';
import '../photos/thumbnail_cache.dart';
import '../settings/backup_targets_store.dart';
import '../settings/s3_backup_target.dart';
import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import '../upload/object_keys.dart';
import '../upload/pending_deletes.dart';
import 'bucket.dart';
import 'hidden_removal.dart';
import 'keys.dart';
import 'object_key.dart';

/// The one owner of a photo going into or out of hiding.
///
/// Each step is journaled (`hidden_transition` in sqlite) with what it
/// still owes, so a kill part-way is finished by [resume] on the next
/// launch, never left half done:
///
/// ```text
/// hide    0 hidden (same write as the journal row)
///           → faces and thumbnail dropped, plain bucket copies computed
///         1 uploads reset (one write) → copies held until the carrier
///           is in every bucket ([DeferredDeletes.untilCarrier]) → closed
/// unhide  0 carriers computed (before anything changes)
///           → carriers deferred until the plain copy is up, hide holds
///             dropped
///         1 uploads reset and hash cleared (one write) → closed
/// ```
///
/// Nothing here deletes from a bucket. What it queues goes through the
/// guarded drain, each task with the copy that has to be there first.
class HiddenTransition {
  HiddenTransition({
    required this.store,
    this.loadTargets,
    PendingDeletes? pendingDeletes,
    this.analysisStore,
    ThumbnailCache? thumbnails,
  }) : _pending = pendingDeletes ?? PendingDeletes(store: store),
       _thumbnails = thumbnails ?? ThumbnailCache(store: store);

  final AssetRecordStore store;
  final Future<List<S3BackupTarget>> Function()? loadTargets;
  final PendingDeletes _pending;
  final AiAnalysisStore? analysisStore;
  final ThumbnailCache _thumbnails;

  static const hide = 'hide';
  static const unhide = 'unhide';

  late final _holds = DeferredDeletes.untilCarrier(
    store: store,
    pending: _pending,
  );
  late final _deferred = DeferredDeletes(store: store, pending: _pending);

  /// Hidden at once, each in the same write as its journal row. Until
  /// [settleHide], nothing about its backup has changed.
  Future<void> markHidden(
    Iterable<String> localIds,
    String passcodeHash,
  ) async {
    for (final id in localIds) {
      await store.openTransition(id, hide, passcodeHash: passcodeHash);
    }
  }

  /// A hide that didn't take (nothing was copied out): ordinary again,
  /// and its bucket copies untouched — they may be the only ones.
  Future<void> cancelHide(String localId) =>
      store.closeTransition(localId, unhide: true);

  /// The rest of a hide, once the photo is held here.
  Future<void> settleHide(String localId) async {
    final row = (await store.openTransitions())
        .where((r) => r.localId == localId && r.kind == hide)
        .firstOrNull;
    if (row != null) await _advance(row);
  }

  /// Un-hides [record]. [keys] (the album's) names carriers the record no
  /// longer does; [unlist] takes an adopted photo out of the album index
  /// first, and a false there leaves it hidden. False when it stays hidden.
  Future<bool> unhideRecord(
    AssetRecord record, {
    AlbumKeys? keys,
    Future<bool> Function(AssetRecord record)? unlist,
  }) async {
    final open = await _rowOf(record.localId);
    if (open != null && open.kind == hide && open.step == 0) {
      // Its backup never changed: what the rows name is still plain.
      await cancelHide(record.localId);
      return true;
    }
    if (unlist != null && !await unlist(record)) return false;
    // Its keys as they are now, not as the screen last read them.
    final fresh = await store.getByLocalId(record.localId) ?? record;
    final tasks = await _carrierTasks(fresh, keys);
    await store.openTransition(record.localId, unhide, payload: _encode(tasks));
    await _advance((await _rowOf(record.localId))!);
    return true;
  }

  /// Finishes every transition a kill interrupted. Returns how many.
  Future<int> resume() async {
    var done = 0;
    for (final row in await store.openTransitions()) {
      try {
        await _advance(row);
        done++;
      } catch (_) {
        // Still journaled; the next launch tries again.
      }
    }
    return done;
  }

  Future<TransitionRow?> _rowOf(String localId) async =>
      (await store.openTransitions())
          .where((r) => r.localId == localId)
          .firstOrNull;

  Future<void> _advance(TransitionRow row) async {
    var at = row;
    while (true) {
      final next = at.kind == hide
          ? await _hideStep(at)
          : await _unhideStep(at);
      if (next == null) return;
      at = next;
    }
  }

  /// One step of a hide; the row it moved to, or null once closed.
  Future<TransitionRow?> _hideStep(TransitionRow row) async {
    final id = row.localId;
    switch (row.step) {
      case 0:
        final record = await store.getByLocalId(id);
        if (record == null || record.passcodeHash == null) {
          await store.closeTransition(id);
          return null;
        }
        await forgetHiddenFaces([id], analysisStore: analysisStore);
        await _thumbnails.remove(record);
        // Read before the per-target rows go: they say which key each
        // bucket holds.
        final tasks = deletionTasksFor(
          record,
          await _targets(),
          await heldKeysOf(store, id),
        );
        final payload = _encode(tasks);
        await store.retractUploads(id, step: 1, payload: payload);
        return TransitionRow(
          localId: id,
          kind: hide,
          step: 1,
          payload: payload,
        );
      default:
        await _holds.add(id, _decode(row.payload));
        await store.closeTransition(id);
        return null;
    }
  }

  Future<TransitionRow?> _unhideStep(TransitionRow row) async {
    final id = row.localId;
    switch (row.step) {
      case 0:
        await _deferred.add(id, _decode(row.payload));
        // Its plain copies are its backup again.
        await _holds.take(id);
        await store.retractUploads(id, step: 1, unhide: true);
        return TransitionRow(localId: id, kind: unhide, step: 1);
      default:
        await store.closeTransition(id);
        return null;
    }
  }

  /// Every carrier [record] may have in a bucket: the keys its rows name,
  /// and the ones the album's protocol gives it — an adopted photo has the
  /// index's and a second one it was re-sent under.
  Future<List<PendingDelete>> _carrierTasks(
    AssetRecord record,
    AlbumKeys? keys,
  ) async {
    final targets = await _targets();
    return {
      for (final t in deletionTasksFor(
        record,
        targets,
        await heldKeysOf(store, record.localId),
      ))
        t.asCarrier(),
      ...carrierTasksFor(record, keys, targets),
    }.toList();
  }

  Future<List<S3BackupTarget>> _targets() async {
    try {
      return await (loadTargets ?? BackupTargetsStore().loadAll)();
    } catch (_) {
      // No keychain: tasks name no bucket and wait for one.
      return const [];
    }
  }

  static String _encode(List<PendingDelete> tasks) =>
      jsonEncode([for (final t in tasks) t.toJson()]);

  static List<PendingDelete> _decode(String payload) {
    if (payload.isEmpty) return const [];
    try {
      return [
        for (final e in jsonDecode(payload) as List)
          PendingDelete.fromJson(e as Map<String, dynamic>),
      ];
    } catch (_) {
      return const [];
    }
  }
}

/// The album-relative carrier keys [record] can be known by: its protocol
/// name under [keys], and the index key an adopted photo came in under,
/// with its motion twin.
Set<String> relativeCarrierKeys(AssetRecord record, AlbumKeys? keys) => {
  if (keys != null) vaultCarrierKey(record, keys.carrier),
  if (keys != null && record.isLivePhoto)
    vaultLiveCarrierKey(record, keys.carrier),
  for (final kind in const [DerivativeKind.original, DerivativeKind.livePhoto])
    if (_relative(record.stateOf(kind).destinationKey) case final key?)
      ...(isAdopted(record) ? HiddenRemoval.siblingKeys(key) : [key]),
};

/// A filed photo an earlier build turned back into a row.
bool isAdopted(AssetRecord record) =>
    record.localId.startsWith('manual:vault-');

/// [relativeCarrierKeys] as carrier deletes, one per bucket, or naming no
/// bucket when none can be read.
List<PendingDelete> carrierTasksFor(
  AssetRecord record,
  AlbumKeys? keys,
  List<S3BackupTarget> targets,
) => [
  for (final key in relativeCarrierKeys(record, keys))
    if (targets.isEmpty)
      PendingDelete(
        objectKey: key,
        targetId: '',
        localId: record.localId,
        carrier: true,
      )
    else
      for (final target in targets)
        PendingDelete(
          objectKey: VaultBucket.resolveKey(target, key),
          targetId: target.id,
          localId: record.localId,
          carrier: true,
        ),
];

String? _relative(String? key) {
  if (key == null) return null;
  final at = key.indexOf('originals/');
  return at == -1 ? null : key.substring(at);
}
