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
}
