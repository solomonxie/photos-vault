import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import '../upload/pending_deletes.dart';

/// [localId] takes Photos asset [asset] over: `AssetRecordStore.adoptAsset`,
/// after queueing the bucket copies of any record sync already made of it.
/// Queued first, with that record named: a kill before the adopt leaves
/// tasks the drain drops, since the record still holds its keys.
Future<bool> takeOverAsset(
  AssetRecordStore store,
  String localId,
  String asset, {
  int? width,
  int? height,
  bool optimized = false,
  bool closeSwap = false,
}) async {
  final stray = await store.getByLibraryId(asset);
  if (stray != null &&
      stray.localId != localId &&
      stray.libraryId == asset &&
      stray.passcodeHash == null &&
      !stray.isLocked) {
    final keys = <PendingDelete>[
      for (final kind in DerivativeKind.values)
        for (final MapEntry(key: target, value: key)
            in (await store.targetsHolding(stray.localId, kind)).entries)
          PendingDelete(
            objectKey: key,
            targetId: target,
            localId: stray.localId,
          ),
    ];
    if (keys.isNotEmpty) await PendingDeletes(store: store).add(keys);
  }
  return store.adoptAsset(
    localId,
    asset,
    width: width,
    height: height,
    optimized: optimized,
    closeSwap: closeSwap,
  );
}
