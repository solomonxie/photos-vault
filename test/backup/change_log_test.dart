import 'package:bring_your_own_photos/storage/asset_record_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  AssetRecordStore newStore() {
    final store = AssetRecordStore(
      databaseFactory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    addTearDown(store.close);
    return store;
  }

  test('every write lands in the log without anyone recording it', () async {
    final store = newStore();

    await store.upsert(localId: 'a', contentHash: 'h', platform: 'ios');
    await store.setDescription('a', 'a day at the beach');
    await store.setTags('a', const ['beach']);

    final rows = await store.changeLogRows();
    expect(rows, hasLength(3));
    expect(rows.map((row) => row['op']), ['insert', 'update', 'update']);
    expect(rows.every((row) => row['row_key'] == 'a'), isTrue);
  });

  test('an update carries both sides of the change', () async {
    final store = newStore();

    await store.upsert(localId: 'a', contentHash: 'h', platform: 'ios');
    await store.setDescription('a', 'first');
    await store.setDescription('a', 'second');

    final last = (await store.changeLogRows()).last;
    expect((last['before'] as Map)['description'], 'first');
    expect((last['after'] as Map)['description'], 'second');
  });

  test('the mark moves on a write and holds still otherwise', () async {
    final store = newStore();

    final before = await store.changeMark();
    await store.upsert(localId: 'a', contentHash: 'h', platform: 'ios');
    final after = await store.changeMark();

    expect(after, greaterThan(before));
    expect(await store.changeMark(), after);
  });

  test("bookkeeping doesn't count as a change", () async {
    final store = newStore();
    await store.upsert(localId: 'a', contentHash: 'h', platform: 'ios');
    final mark = await store.changeMark();

    // What a finished backup writes. If this moved the mark, the gate would
    // see a change every day forever and never skip an unchanged library.
    await store.setAppState('icloud_backup_at', DateTime.now().toString());

    expect(await store.changeMark(), mark);
  });

  test('the log describes the current schema, column for column', () async {
    // The triggers are built from `PRAGMA table_info` on every open, so a
    // column added by a migration shows up without anyone editing them.
    final store = newStore();
    await store.upsert(localId: 'a', contentHash: 'h', platform: 'ios');

    final logged = ((await store.changeLogRows()).single['after'] as Map).keys;
    final columns = [
      // Same path, so `singleInstance` hands back the store's own handle.
      for (final column in await (await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
      )).rawQuery('PRAGMA table_info(asset_record)'))
        column['name'],
    ];
    expect(logged, columns);
  });
}
