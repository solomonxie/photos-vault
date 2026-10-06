import 'dart:convert';
import 'dart:io';

import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import 'bucket_flagged.dart';
import 'capture_date.dart';

/// Bucket keys the user (or the leftover sweep) has said are not photos to
/// import. The bucket keeps them; detection just stops offering them.
class IgnoredBucketKeys {
  IgnoredBucketKeys(this.store);

  final AssetRecordStore store;
  static const _key = 'bucket_ignored_keys';

  Future<Set<String>> read() async {
    final raw = await store.getAppState(_key);
    if (raw == null) return {};
    try {
      return {...(jsonDecode(raw) as List).cast<String>()};
    } catch (_) {
      return {};
    }
  }

  Future<void> addAll(Iterable<String> keys) async {
    final next = {...await read(), ...keys};
    await store.setAppState(_key, jsonEncode(next.toList()));
  }
}

/// Once, after the upgrade that brought [isLikelyLeftover]: takes back out
/// of the library the bucket imports that were really old copies — dated by
/// an upload or rename stamp, untouched since. Only the library rows go;
/// nothing in any bucket is touched, and their keys are never offered
/// again.
class LeftoverSweep {
  LeftoverSweep({
    required this.store,
    required this.albumMemberships,
    required this.personMemberships,
  });

  final AssetRecordStore store;
  final Future<Map<String, List<String>>> Function() albumMemberships;
  final Future<Map<String, List<String>>> Function() personMemberships;

  static const doneKey = 'leftover_sweep_v1';

  /// How many records were taken out; 0 when it has already run.
  Future<int> runOnce() async {
    if (await store.getAppState(doneKey) != null) return 0;
    final removed = await _sweep();
    await store.setAppState(doneKey, '1');
    return removed;
  }

  Future<int> _sweep() async {
    final imported = [
      for (final r in await store.listAll())
        if (r.localId.startsWith('bucket:')) r,
    ];
    if (imported.isEmpty) return 0;
    final lastModified = {
      for (final o in await store.listBucketObjects()) o.key: o.lastModified,
    };
    final grouped = <String>{
      for (final ids in (await albumMemberships()).values) ...ids,
      for (final ids in (await personMemberships()).values) ...ids,
    };
    final ignored = <String>[];
    var removed = 0;
    for (final record in imported) {
      if (_touched(record) || grouped.contains(record.localId)) continue;
      final original = record.stateOf(DerivativeKind.original).destinationKey;
      final listed = original == null ? null : lastModified[original];
      // The import's own copy moved LastModified to the import time, so
      // whichever is earlier is the closer to when the object arrived.
      final reference = listed != null && listed.isBefore(record.addedAt)
          ? listed
          : record.addedAt;
      if (!isLikelyLeftover(
        nameStamp: takenAtFromName(record.localId),
        reference: reference,
        captureDate: null,
      )) {
        continue;
      }
      await store.remove(record.localId);
      final thumbnail = record.thumbnailPath;
      if (thumbnail != null) {
        try {
          await File(thumbnail).delete();
        } catch (_) {
          // Already gone.
        }
      }
      for (final kind in const [
        DerivativeKind.original,
        DerivativeKind.livePhoto,
      ]) {
        final key = record.stateOf(kind).destinationKey;
        if (key != null) ignored.add(key);
      }
      removed++;
    }
    if (ignored.isNotEmpty) await IgnoredBucketKeys(store).addAll(ignored);
    return removed;
  }

  static bool _touched(AssetRecord r) =>
      r.isFavorite ||
      r.tags.isNotEmpty ||
      r.description.isNotEmpty ||
      (r.location?.isNotEmpty ?? false) ||
      r.isLocked ||
      r.passcodeHash != null;
}
