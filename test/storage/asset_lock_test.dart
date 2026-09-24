import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/photos/storage_advice.dart';
import 'package:photos_vault/storage/asset_record.dart';
import 'package:photos_vault/storage/asset_record_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

AssetRecordStore _store() => AssetRecordStore(
  databaseFactory: databaseFactoryFfi,
  path: inMemoryDatabasePath,
);

AssetRecord _record({bool isLocked = false, bool localOptimized = false}) =>
    AssetRecord(
      localId: 'manual:a',
      contentHash: 'a',
      platform: 'ios',
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
      sourceType: AssetSourceType.manualFile,
      sourcePath: '/tmp/a.jpg',
      isLocked: isLocked,
      localOptimized: localOptimized,
    );

void main() {
  test('a photo starts unlocked and unoptimised', () async {
    final store = _store();
    addTearDown(store.close);

    await store.upsert(
      localId: 'manual:a',
      contentHash: 'a',
      platform: 'ios',
      sourceType: AssetSourceType.manualFile,
      sourcePath: '/tmp/a.jpg',
    );

    final record = (await store.listAll()).single;
    expect(record.isLocked, isFalse);
    expect(record.localOptimized, isFalse);
  });

  test('the lock and the optimised mark round-trip independently', () async {
    final store = _store();
    addTearDown(store.close);

    await store.upsert(
      localId: 'manual:a',
      contentHash: 'a',
      platform: 'ios',
      sourceType: AssetSourceType.manualFile,
      sourcePath: '/tmp/a.jpg',
    );

    await store.setLocked('manual:a', true);
    expect((await store.listAll()).single.isLocked, isTrue);
    expect((await store.listAll()).single.localOptimized, isFalse);

    await store.setLocalOptimized('manual:a', true);
    expect((await store.listAll()).single.isLocked, isTrue);
    expect((await store.listAll()).single.localOptimized, isTrue);

    await store.setLocked('manual:a', false);
    expect((await store.listAll()).single.isLocked, isFalse);
    expect((await store.listAll()).single.localOptimized, isTrue);
  });

  test('Optimize Storage never looks at a locked photo', () {
    expect(worthMeasuring(_record()), isTrue);
    expect(worthMeasuring(_record(isLocked: true)), isFalse);
  });

  test('a locked photo is offered no fix, whatever its size', () {
    final item = adviseOn(
      record: _record(isLocked: true),
      bytes: 80 * 1024 * 1024,
      name: 'a.jpg',
      appOwned: true,
    );
    expect(item, isNull);
  });

  test('withLocked leaves everything else alone', () {
    final locked = _record(localOptimized: true).withLocked(true);
    expect(locked.isLocked, isTrue);
    expect(locked.localOptimized, isTrue);
    expect(locked.localId, 'manual:a');
    expect(locked.sourcePath, '/tmp/a.jpg');
  });
}
