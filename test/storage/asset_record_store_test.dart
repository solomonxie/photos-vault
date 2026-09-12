import 'package:back_your_own_photos/storage/asset_record.dart';
import 'package:back_your_own_photos/storage/asset_record_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  AssetRecordStore newStore() =>
      AssetRecordStore(databaseFactory: databaseFactoryFfi, path: inMemoryDatabasePath);

  test('upsert creates a record with all derivatives pending', () async {
    final store = newStore();

    final record = await store.upsert(localId: 'asset-1', contentHash: 'hash-1', platform: 'ios');

    expect(record.localId, 'asset-1');
    for (final kind in DerivativeKind.values) {
      expect(record.stateOf(kind).status, UploadStatus.pending);
      expect(record.stateOf(kind).destinationKey, isNull);
    }
  });

  test('upsert is idempotent for an already-tracked localId', () async {
    final store = newStore();
    final first = await store.upsert(localId: 'asset-1', contentHash: 'hash-1', platform: 'ios');

    final second = await store.upsert(localId: 'asset-1', contentHash: 'different-hash', platform: 'ios');

    expect(second.contentHash, first.contentHash);
    expect(await store.listAll(), hasLength(1));
  });

  test('updateDerivative persists status and destination key for that derivative only', () async {
    final store = newStore();
    await store.upsert(localId: 'asset-1', contentHash: 'hash-1', platform: 'ios');

    await store.updateDerivative(
      'asset-1',
      DerivativeKind.thumbnail,
      const DerivativeState(status: UploadStatus.uploaded, destinationKey: 'thumbnails/asset-1.jpg'),
    );

    final record = await store.getByLocalId('asset-1');
    expect(record!.stateOf(DerivativeKind.thumbnail).status, UploadStatus.uploaded);
    expect(record.stateOf(DerivativeKind.thumbnail).destinationKey, 'thumbnails/asset-1.jpg');
    expect(record.stateOf(DerivativeKind.medium).status, UploadStatus.pending);
  });

  test('listAll returns records ordered by creation', () async {
    final store = newStore();
    await store.upsert(localId: 'asset-1', contentHash: 'h1', platform: 'ios');
    await store.upsert(localId: 'asset-2', contentHash: 'h2', platform: 'ios');

    final all = await store.listAll();
    expect(all.map((r) => r.localId), ['asset-1', 'asset-2']);
  });

  test('getByLocalId returns null when untracked', () async {
    final store = newStore();

    expect(await store.getByLocalId('missing'), isNull);
  });
}
