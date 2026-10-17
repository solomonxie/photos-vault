import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:photos_vault/storage/asset_record.dart';
import 'package:photos_vault/storage/asset_record_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// The first shipped schema (v1), as `asset_record_store.dart` created it.
const _v1 = '''
  CREATE TABLE asset_record (
    local_id TEXT PRIMARY KEY,
    content_hash TEXT NOT NULL,
    platform TEXT NOT NULL,
    source_type TEXT NOT NULL DEFAULT 'photoManager',
    source_path TEXT,
    thumbnail_status TEXT NOT NULL DEFAULT 'pending',
    thumbnail_key TEXT,
    medium_status TEXT NOT NULL DEFAULT 'pending',
    medium_key TEXT,
    original_status TEXT NOT NULL DEFAULT 'pending',
    original_key TEXT,
    is_favorite INTEGER NOT NULL DEFAULT 0,
    is_hidden INTEGER NOT NULL DEFAULT 0,
    deleted_at INTEGER,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
  )
''';

/// Tables with their columns, indexes and triggers: what a fresh install
/// gets, so an upgraded phone can be held against it.
Future<Map<String, Object>> _schemaOf(String path) async {
  final db = await databaseFactoryFfi.openDatabase(path);
  try {
    final master = await db.rawQuery(
      "SELECT type, name FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' "
      'ORDER BY name',
    );
    final tables = <String, Set<String>>{};
    final others = <String>{};
    for (final row in master) {
      final name = row['name'] as String;
      if (row['type'] == 'table') {
        tables[name] = {
          for (final c in await db.rawQuery('PRAGMA table_info("$name")'))
            [
              c['name'],
              '${c['type']}'.toUpperCase(),
              c['notnull'],
              c['dflt_value'],
              c['pk'],
            ].join('|'),
        };
      } else {
        others.add('${row['type']}:$name');
      }
    }
    return {'version': await db.getVersion(), 'tables': tables, 'rest': others};
  } finally {
    await db.close();
  }
}

void main() {
  setUpAll(sqfliteFfiInit);

  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('pv_up_'));
  tearDown(() => dir.delete(recursive: true));

  Future<AssetRecordStore> open(String path) async {
    final store = AssetRecordStore(
      databaseFactory: databaseFactoryFfi,
      path: path,
    );
    await store.listAll();
    await store.close();
    return store;
  }

  test('a v1 database upgrades to exactly what a fresh install creates, '
      'keeping its rows', () async {
    final freshPath = p.join(dir.path, 'fresh.db');
    await open(freshPath);

    final oldPath = p.join(dir.path, 'old.db');
    final old = await databaseFactoryFfi.openDatabase(oldPath);
    await old.execute(_v1);
    await old.insert('asset_record', {
      'local_id': 'photo:1',
      'content_hash': 'h1',
      'platform': 'ios',
      'original_status': 'uploaded',
      'original_key': 'originals/IMG_1.HEIC',
      'is_favorite': 1,
      'created_at': 1000,
      'updated_at': 2000,
    });
    await old.setVersion(1);
    await old.close();

    final upgraded = AssetRecordStore(
      databaseFactory: databaseFactoryFfi,
      path: oldPath,
    );
    final record = (await upgraded.getByLocalId('photo:1'))!;
    expect(record.contentHash, 'h1');
    expect(record.isFavorite, isTrue);
    expect(record.isDeleted, isFalse);
    final original = record.stateOf(DerivativeKind.original);
    expect(original.status, UploadStatus.uploaded);
    expect(original.destinationKey, 'originals/IMG_1.HEIC');
    // The upload a v1 row recorded still guards its key.
    expect(
      await upgraded.keyHeldByOthers('originals/IMG_1.HEIC', null),
      isTrue,
    );
    await upgraded.close();

    final fresh = await _schemaOf(freshPath);
    final after = await _schemaOf(oldPath);
    expect(after['version'], fresh['version']);
    final freshTables = fresh['tables']! as Map<String, Set<String>>;
    final afterTables = after['tables']! as Map<String, Set<String>>;
    expect(afterTables.keys.toSet(), freshTables.keys.toSet());
    for (final table in freshTables.keys) {
      expect(afterTables[table], freshTables[table], reason: table);
    }
    expect(after['rest'], fresh['rest']);
  });

  test('v25 gains the change-check table, keeping every row and owing each '
      'backed-up photo one check', () async {
    final path = p.join(dir.path, 'v25.db');
    final store = AssetRecordStore(
      databaseFactory: databaseFactoryFfi,
      path: path,
    );
    await store.upsert(localId: 'photo:1', contentHash: 'h1', platform: 'ios');
    await store.updateDerivative(
      'photo:1',
      DerivativeKind.original,
      const DerivativeState(
        status: UploadStatus.uploaded,
        destinationKey: 'originals/IMG_1.HEIC',
        backedUpHash: 'x',
      ),
    );
    await store.close();
    // What v25 had: everything but the table.
    final raw = await databaseFactoryFfi.openDatabase(path);
    await raw.execute('DROP TABLE change_check');
    await raw.setVersion(25);
    await raw.close();

    final upgraded = AssetRecordStore(
      databaseFactory: databaseFactoryFfi,
      path: path,
    );
    final record = (await upgraded.getByLocalId('photo:1'))!;
    expect(record.stateOf(DerivativeKind.original).backedUpHash, 'x');
    expect(await upgraded.changeChecksDue(), {'photo:1'});

    await upgraded.markChecked('photo:1', 100);
    expect(await upgraded.changeChecksDue(), isEmpty);
    await upgraded.noteModified({'photo:1': 100});
    expect(await upgraded.changeChecksDue(), isEmpty, reason: 'same date');
    await upgraded.noteModified({'photo:1': 160});
    expect(await upgraded.changeChecksDue(), {'photo:1'});
    expect(await upgraded.checkedModified('photo:1'), 100);
    await upgraded.remove('photo:1');
    expect(await upgraded.checkedModified('photo:1'), isNull);
    await upgraded.close();

    final fresh = p.join(dir.path, 'fresh26.db');
    await open(fresh);
    expect(
      (await _schemaOf(path))['tables'],
      (await _schemaOf(fresh))['tables'],
    );
  });

  test('v26 gains the edit columns: every backup stays as it was, owes no '
      'edit, and only one dated well before its upload is settled', () async {
    final path = p.join(dir.path, 'v26.db');
    final store = AssetRecordStore(
      databaseFactory: databaseFactoryFfi,
      path: path,
    );
    final now = DateTime.now();
    final old = now.subtract(const Duration(days: 30));
    for (final id in ['photo:old', 'photo:recent', 'photo:adopted']) {
      await store.upsert(localId: id, contentHash: id, platform: 'ios');
      await store.updateDerivative(
        id,
        DerivativeKind.original,
        DerivativeState(
          status: UploadStatus.uploaded,
          destinationKey: 'originals/$id.jpg',
          backedUpHash: 'render-$id',
        ),
      );
      await store.recordUpload(
        localId: id,
        kind: DerivativeKind.original,
        // An adopted row names no bucket, and its time is the adoption's.
        targetId: id == 'photo:adopted' ? '' : 't1',
        destinationKey: 'originals/$id.jpg',
        sourceHash: 'render-$id',
      );
    }
    await store.close();
    // What v26 had: everything but the PW3b columns.
    final raw = await databaseFactoryFfi.openDatabase(path);
    for (final row in await raw.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'trigger' "
      "AND sql LIKE '%has_edit%'",
    )) {
      await raw.execute('DROP TRIGGER "${row['name']}"');
    }
    await raw.execute('DROP INDEX asset_record_edited_key');
    for (final column in [
      'edited_status',
      'edited_key',
      'edited_hash',
      'original_source',
      'has_edit',
    ]) {
      await raw.execute('ALTER TABLE asset_record DROP COLUMN $column');
    }
    await raw.setVersion(26);
    await raw.close();

    final upgraded = AssetRecordStore(
      databaseFactory: databaseFactoryFfi,
      path: path,
    );
    for (final r in await upgraded.listAll()) {
      final original = r.stateOf(DerivativeKind.original);
      expect(original.status, UploadStatus.uploaded);
      expect(original.backedUpHash, 'render-${r.localId}');
      expect(original.fromResource, isFalse, reason: 'a render, compared so');
      expect(r.hasEdit, isFalse);
      expect(r.isFullyBackedUp, isTrue, reason: 'nothing new is owed');
    }
    await upgraded.noteModified({
      'photo:old': old.millisecondsSinceEpoch ~/ 1000,
      'photo:recent': now.millisecondsSinceEpoch ~/ 1000,
      'photo:adopted': old.millisecondsSinceEpoch ~/ 1000,
    });
    expect(await upgraded.rebaselineChangeChecks(), 1);
    expect(await upgraded.changeChecksDue(), {'photo:recent', 'photo:adopted'});
    expect(await upgraded.rebaselineChangeChecks(), 0, reason: 'idempotent');
    expect(
      await upgraded.backupPredates(
        'photo:recent',
        old.millisecondsSinceEpoch ~/ 1000,
      ),
      isTrue,
    );
    expect(
      await upgraded.backupPredates(
        'photo:adopted',
        old.millisecondsSinceEpoch ~/ 1000,
      ),
      isFalse,
    );

    // The new columns round-trip, and an edit's key is guarded.
    await upgraded.updateDerivative(
      'photo:old',
      DerivativeKind.original,
      const DerivativeState(
        status: UploadStatus.uploaded,
        destinationKey: 'originals/photo:old.HEIC',
        backedUpHash: 'base',
        fromResource: true,
      ),
    );
    await upgraded.updateDerivative(
      'photo:old',
      DerivativeKind.edited,
      const DerivativeState(
        status: UploadStatus.uploaded,
        destinationKey: 'edited/photo:old.heic',
      ),
    );
    await upgraded.setHasEdit('photo:old', true);
    final edited = (await upgraded.getByLocalId('photo:old'))!;
    expect(edited.stateOf(DerivativeKind.original).fromResource, isTrue);
    expect(edited.hasEdit, isTrue);
    expect(edited.isFullyBackedUp, isTrue);
    expect(
      await upgraded.keyHeldByOthers('edited/photo:old.heic', null),
      isTrue,
    );
    await upgraded.close();

    final fresh = p.join(dir.path, 'fresh27.db');
    await open(fresh);
    final a = await _schemaOf(path);
    final b = await _schemaOf(fresh);
    expect(a['version'], b['version']);
    expect(a['tables'], b['tables']);
    expect(a['rest'], b['rest']);
  });
}
