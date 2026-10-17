import 'dart:convert';

import 'package:photos_vault/backup/change_log.dart';
import 'package:photos_vault/storage/asset_record_store.dart';
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

  test('clearing the database clears the record of what was in it', () async {
    final store = newStore();

    await store.upsert(localId: 'a', contentHash: 'h', platform: 'ios');
    await store.setDescription('a', 'a day at the beach');

    await store.clearAll();

    // A delete trigger writes the whole row it removed. Left behind, the
    // log would be a verbatim copy of the library the wipe just promised
    // to erase.
    expect(await store.changeLogRows(), isEmpty);
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

  group('triggers on open', () {
    Future<int> schemaVersion(Database db) async =>
        (await db.rawQuery('PRAGMA schema_version')).first.values.first as int;

    test('left alone when they already match', () async {
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      addTearDown(db.close);
      await db.execute('CREATE TABLE t (id TEXT PRIMARY KEY, a TEXT)');
      await installChangeLog(
        db,
        const ['t'],
        quiet: const {
          't': {'a'},
        },
      );
      final installed = await schemaVersion(db);

      await installChangeLog(
        db,
        const ['t'],
        quiet: const {
          't': {'a'},
        },
      );

      expect(await schemaVersion(db), installed, reason: 'no DDL ran');
      await db.insert('t', {'id': '1', 'a': 'x'});
      expect(await db.query(changeLogTable), hasLength(1));
    });

    test('rebuilt when a column or a rule moved', () async {
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      addTearDown(db.close);
      await db.execute('CREATE TABLE t (id TEXT PRIMARY KEY, a TEXT)');
      await installChangeLog(db, const ['t']);
      await db.execute('ALTER TABLE t ADD COLUMN b TEXT');

      await installChangeLog(
        db,
        const ['t'],
        private: const {'t': '{row}.b = 1'},
      );
      await db.insert('t', {'id': '1', 'a': 'x', 'b': 'y'});

      final row = (await db.query(changeLogTable)).single;
      expect(row['after'] as String, contains('"b":"y"'));
      final names = [
        for (final r in await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type = 'trigger'",
        ))
          r['name'],
      ];
      expect(names, contains('change_log_t_insert_private'));
    });
  });

  group('PW5: diffs, prune, slim', () {
    test('an update logs only the columns it changed', () async {
      final store = newStore();
      await store.upsert(localId: 'a', contentHash: 'h', platform: 'ios');
      await store.setDescription('a', 'first');
      await store.setDescription('a', 'second');

      final last = (await store.changeLogRows()).last;
      // `updated_at` is silent: a bookkeeping column.
      expect(last['before'], {'description': 'first'});
      expect(last['after'], {'description': 'second'});
    });

    test('a delete keeps the whole row it removed', () async {
      final store = newStore();
      await store.upsert(localId: 'a', contentHash: 'h', platform: 'ios');
      await store.setDescription('a', 'kept');
      await store.remove('a');

      final last = (await store.changeLogRows()).last;
      expect(last['op'], 'delete');
      expect((last['before'] as Map)['description'], 'kept');
      expect((last['before'] as Map)['content_hash'], 'h');
    });

    Future<Database> table() async {
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      addTearDown(db.close);
      await db.execute('CREATE TABLE t (id TEXT PRIMARY KEY, a TEXT, b TEXT)');
      await installChangeLog(db, const ['t']);
      return db;
    }

    test('the prune keeps the newest, the mark, and puts secure_delete '
        'back', () async {
      final db = await table();
      await db.rawQuery('PRAGMA secure_delete = ON');
      for (var i = 0; i < 30; i++) {
        await db.insert('t', {'id': '$i', 'a': 'x'});
      }
      final mark = await changeLogMark(db);

      await pruneChangeLog(db, keep: 10, fast: true);

      final left = await db.query(changeLogTable, orderBy: 'seq');
      expect(left.map((r) => r['row_key']), [
        for (var i = 20; i < 30; i++) '$i',
      ]);
      expect(await changeLogMark(db), mark);
      final mode = await db.rawQuery('PRAGMA secure_delete');
      expect(mode.first.values.first, 1);
      expect(changeLogKeep, 5000, reason: 'what the zip ships');
    });

    test('old whole-row entries slim to what changed, once', () async {
      final db = await table();
      await db.insert('t', {'id': '1', 'a': 'x', 'b': 'same'});
      await db.insert(changeLogTable, {
        'table_name': 't',
        'row_key': '1',
        'op': 'update',
        'before': '{"id":"1","a":"x","b":"same","c":null}',
        'after': '{"id":"1","a":"y","b":"same","c":"new"}',
        'at': '',
      });
      await db.insert(changeLogTable, {
        'table_name': 't',
        'row_key': '1',
        'op': 'update',
        'before': 'not json',
        'after': '{}',
        'at': '',
      });
      final mark = await changeLogMark(db);

      expect(
        await slimChangeLog(db, 't', below: mark + 1, silent: {'c'}),
        isTrue,
      );
      final rows = await changeLogTail(db);
      expect(rows.first['after'], {
        'id': '1',
        'a': 'x',
        'b': 'same',
      }, reason: 'inserts keep the row');
      expect(rows[1]['before'], {'a': 'x'});
      expect(rows[1]['after'], {'a': 'y'});
      expect(rows[2]['before'], 'not json', reason: 'left as it was');

      await slimChangeLog(db, 't', below: mark + 1, silent: {'c'});
      expect(jsonEncode(await changeLogTail(db)), jsonEncode(rows));
      expect(await changeLogMark(db), mark);
    });
  });
}
