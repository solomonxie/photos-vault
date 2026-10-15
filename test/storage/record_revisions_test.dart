import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:photos_vault/backup/change_log.dart';
import 'package:photos_vault/storage/asset_record.dart';
import 'package:photos_vault/storage/asset_record_store.dart';
import 'package:photos_vault/storage/bucket_object.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('pv_rev_'));
  tearDown(() => dir.delete(recursive: true));

  String dbPath() => p.join(dir.path, 'photos_vault.db');

  AssetRecordStore open() {
    final store = AssetRecordStore(
      databaseFactory: databaseFactoryFfi,
      path: dbPath(),
    );
    addTearDown(store.close);
    return store;
  }

  Future<void> add(AssetRecordStore s, String id, {DateTime? at}) =>
      s.upsert(localId: id, contentHash: id, platform: 'ios', createdAt: at);

  group('listAll', () {
    test(
      'a photo taken years ago, added after the first read, shows',
      () async {
        final s = open();
        await add(s, 'photo:new', at: DateTime(2026, 10, 1));
        expect(await s.listAll(), hasLength(1));

        await add(s, 'photo:old', at: DateTime(2014, 3, 2));

        final all = await s.listAll();
        expect(all.map((r) => r.localId), ['photo:old', 'photo:new']);
      },
    );

    test('a future-dated photo does not hide later writes', () async {
      final s = open();
      await add(s, 'photo:a', at: DateTime(2020));
      await s.listAll();
      await add(s, 'photo:future', at: DateTime(2099));
      await s.listAll();

      await s.setFavorite('photo:a', true);
      await add(s, 'photo:b', at: DateTime(2021));

      final all = {for (final r in await s.listAll()) r.localId: r};
      expect(all['photo:a']!.isFavorite, isTrue);
      expect(all.keys, containsAll(['photo:b', 'photo:future']));
    });

    test('writes in the same millisecond are all seen', () async {
      final s = open();
      await add(s, 'photo:a', at: DateTime(2020));
      await add(s, 'photo:b', at: DateTime(2020));
      await s.listAll();

      await Future.wait([
        s.setFavorite('photo:a', true),
        s.setFavorite('photo:b', true),
        s.setLocation('photo:a', 'Paris'),
      ]);

      final all = {for (final r in await s.listAll()) r.localId: r};
      expect(all['photo:a']!.isFavorite, isTrue);
      expect(all['photo:b']!.isFavorite, isTrue);
      expect(all['photo:a']!.location, 'Paris');
    });

    test('same capture time sorts by id, every time', () async {
      final s = open();
      final at = DateTime(2022, 5, 5, 12);
      for (final id in ['photo:c', 'photo:a', 'photo:b']) {
        await add(s, id, at: at);
      }
      await s.listAll();
      await s.setFavorite('photo:a', true);
      expect((await s.listAll()).map((r) => r.localId), [
        'photo:a',
        'photo:b',
        'photo:c',
      ]);
    });

    test('a re-dated photo moves; unchanged ones keep their object', () async {
      final s = open();
      await add(s, 'photo:a', at: DateTime(2020));
      await add(s, 'photo:b', at: DateTime(2021));
      final first = await s.listAll();
      expect(identical(await s.listAll(), first), isTrue);

      await s.setCreatedAt('photo:a', DateTime(2022));

      final second = await s.listAll();
      expect(second.map((r) => r.localId), ['photo:b', 'photo:a']);
      expect(identical(second.first, first[1]), isTrue);
    });

    test(
      'removeMany leaves the cache; another instance\'s delete too',
      () async {
        final s = open();
        for (final id in ['photo:a', 'photo:b', 'photo:c']) {
          await add(s, id);
        }
        await s.listAll();
        await s.removeMany(['photo:a', 'photo:b']);
        expect((await s.listAll()).map((r) => r.localId), ['photo:c']);
        expect(await s.removedIds(), {'photo:a', 'photo:b'});

        final other = AssetRecordStore(
          databaseFactory: databaseFactoryFfi,
          path: dbPath(),
        );
        // Same connection (ffi shares one per path), its own cache.
        await other.remove('photo:c');
        expect(await s.listAll(), isEmpty);
      },
    );

    test('libraryDelta: upload state alone is not a shape change', () async {
      final s = open();
      await add(s, 'photo:a');
      final a = await s.listAll();

      await s.updateDerivative(
        'photo:a',
        DerivativeKind.original,
        const DerivativeState(
          status: UploadStatus.uploaded,
          destinationKey: 'p/originals/a.jpg',
        ),
      );
      final b = await s.listAll();
      expect(identical(a, b), isFalse);
      expect(libraryDelta(a, b), (shape: false, visibility: false));

      await s.setFavorite('photo:a', true);
      final c = await s.listAll();
      expect(libraryDelta(b, c), (shape: true, visibility: false));

      await s.softDelete('photo:a');
      final d = await s.listAll();
      expect(libraryDelta(c, d), (shape: true, visibility: true));
      expect(libraryDelta(null, d).shape, isTrue);
    });
  });

  group('change log', () {
    Future<List<Map<String, Object?>>> log(AssetRecordStore s) =>
        s.changeLogRows();

    test('upload state moves the mark without a row; a cache path does '
        'neither; a heart logs', () async {
      final s = open();
      await add(s, 'photo:a');
      final rows = (await log(s)).length;
      final mark = await s.changeMark();

      await s.updateDerivative(
        'photo:a',
        DerivativeKind.thumbnail,
        const DerivativeState(status: UploadStatus.uploaded),
      );
      expect((await log(s)).length, rows);
      final afterUpload = await s.changeMark();
      expect(afterUpload, greaterThan(mark));

      await s.setThumbnailPath('photo:a', '/tmp/a.jpg');
      expect((await log(s)).length, rows);
      expect(await s.changeMark(), afterUpload);

      await s.setFavorite('photo:a', true);
      expect((await log(s)).length, rows + 1);
    });

    test('a hidden row still logs nothing of itself', () async {
      final s = open();
      await add(s, 'photo:h');
      await s.setPasscodeHash('photo:h', 'tag');
      final mark = await s.changeMark();
      await s.setDescription('photo:h', 'secret');
      expect(
        (await log(s)).where((r) => '${r['after']}'.contains('secret')),
        isEmpty,
      );
      expect(await s.changeMark(), greaterThan(mark));
    });
  });

  group('a staged bucket listing', () {
    BucketObject o(String key) => BucketObject(
      targetId: 't',
      key: key,
      size: 1,
      lastModified: DateTime(2026),
    );

    test('a key forgotten mid-scan stays forgotten', () async {
      final s = open();
      await s.replaceBucketObjects('t', [o('originals/k.jpg')]);
      await s.stageBucketPage('t', 'originals', null, [o('originals/k.jpg')]);

      await s.forgetBucketObject('t', 'originals/k.jpg');
      // A page listed before the delete, staged after it.
      await s.stageBucketPage('t', 'thumbnails', null, [o('originals/k.jpg')]);
      await s.commitBucketScan('t');

      expect(await s.isListed('t', 'originals/k.jpg'), isFalse);
    });

    test('a move mid-scan lands on the new key', () async {
      final s = open();
      await s.stageBucketPage('t', 'originals', null, [o('originals/a.jpg')]);
      await s.moveBucketObject(o('originals/a.jpg'), o('originals/b.heic'));
      await s.commitBucketScan('t');

      expect(await s.isListed('t', 'originals/a.jpg'), isFalse);
      expect(await s.isListed('t', 'originals/b.heic'), isTrue);
    });

    test('uploaded again after a forget, the next listing keeps it', () async {
      final s = open();
      await s.forgetBucketObject('t', 'originals/k.jpg');
      await s.recordUpload(
        localId: 'photo:k',
        kind: DerivativeKind.original,
        targetId: 't',
        destinationKey: 'originals/k.jpg',
      );
      await s.stageBucketPage('t', 'originals', null, [o('originals/k.jpg')]);
      await s.commitBucketScan('t');
      expect(await s.isListed('t', 'originals/k.jpg'), isTrue);
    });
  });

  group('upgrade', () {
    // What each version added to `asset_record`, from onUpgrade.
    const added = <int, List<String>>{
      2: ['is_video INTEGER NOT NULL DEFAULT 0'],
      3: [
        "description TEXT NOT NULL DEFAULT ''",
        "tags TEXT NOT NULL DEFAULT '[]'",
        'location TEXT',
      ],
      4: ['passcode_hash TEXT'],
      5: ['thumbnail_hash TEXT', 'medium_hash TEXT', 'original_hash TEXT'],
      6: ['thumbnail_path TEXT', 'local_deleted INTEGER NOT NULL DEFAULT 0'],
      8: ['is_live_photo INTEGER NOT NULL DEFAULT 0'],
      10: [
        'latitude REAL',
        'longitude REAL',
        'width INTEGER',
        'height INTEGER',
      ],
      11: ['library_id TEXT'],
      13: ['is_gif INTEGER NOT NULL DEFAULT 0'],
      14: [
        "live_status TEXT NOT NULL DEFAULT 'pending'",
        'live_key TEXT',
        'live_hash TEXT',
      ],
      15: [
        'is_locked INTEGER NOT NULL DEFAULT 0',
        'local_optimized INTEGER NOT NULL DEFAULT 0',
      ],
      17: ['added_at INTEGER'],
      20: ['binned_by TEXT'],
      22: ['held_name TEXT'],
    };
    const tablesAt = {
      'place_name': 10,
      'app_state': 12,
      'derivative_target': 16,
      'hidden_note': 17,
      'bucket_object': 18,
      'bucket_scan': 19,
      'bucket_scan_object': 19,
      'hidden_transition': 21,
      'pending_swap': 23,
      'relink_pending': 24,
    };
    const base = '''
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
      updated_at INTEGER NOT NULL''';

    const indexesAt = {
      'asset_record_library_id_unique': 23,
      'relink_pending_created': 24,
    };
    final indexes = <String, String>{};

    Future<Map<String, String>> freshTableSql() async {
      final fresh = AssetRecordStore(
        databaseFactory: databaseFactoryFfi,
        path: p.join(dir.path, 'fresh.db'),
      );
      await fresh.listAll();
      await fresh.close();
      final db = await databaseFactoryFfi.openDatabase(
        p.join(dir.path, 'fresh.db'),
      );
      final rows = await db.rawQuery(
        "SELECT name, sql FROM sqlite_master WHERE type = 'table'",
      );
      for (final r in await db.rawQuery(
        "SELECT name, sql FROM sqlite_master WHERE type = 'index' "
        'AND sql IS NOT NULL',
      )) {
        indexes[r['name'] as String] = r['sql'] as String;
      }
      await db.close();
      return {for (final r in rows) r['name'] as String: r['sql'] as String};
    }

    Future<Map<String, List<String>>> shape(String path) async {
      final db = await databaseFactoryFfi.openDatabase(path);
      final out = <String, List<String>>{};
      for (final t in await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type IN ('table') "
        "AND name NOT LIKE 'sqlite_%'",
      )) {
        final name = t['name'] as String;
        out[name] = [
          for (final c in await db.rawQuery('PRAGMA table_info($name)'))
            '${c['name']} ${c['type']} ${c['notnull']} ${c['dflt_value']} '
                '${c['pk']}',
        ]..sort();
      }
      out['_index'] = [
        for (final r in await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type IN ('index', 'trigger') "
          "AND name NOT LIKE 'sqlite_%'",
        ))
          r['name'] as String,
      ]..sort();
      await db.close();
      return out;
    }

    for (final version in [1, 5, 10, 13, 15, 16, 17, 19, 21, 22, 23, 24]) {
      test(
        'v$version upgrades to today\'s schema and keeps every row',
        () async {
          final tables = await freshTableSql();
          final path = p.join(dir.path, 'v$version.db');
          final db = await databaseFactoryFfi.openDatabase(path);
          final columns = [
            base,
            for (final MapEntry(:key, :value) in added.entries)
              if (key <= version) ...value,
          ];
          await db.execute(
            'CREATE TABLE asset_record (${columns.join(',\n')})',
          );
          for (final MapEntry(:key, :value) in tablesAt.entries) {
            if (value <= version) await db.execute(tables[key]!);
          }
          for (final MapEntry(:key, :value) in indexesAt.entries) {
            if (value <= version) await db.execute(indexes[key]!);
          }
          Map<String, Object?> row(String id, int at) => {
            'local_id': id,
            'content_hash': 'h-$id',
            'platform': 'ios',
            'original_status': 'uploaded',
            'original_key': 'p/originals/$id.jpg',
            if (version >= 5) 'original_hash': 'x-$id',
            if (version >= 3) 'description': 'caption $id',
            'is_favorite': 1,
            'created_at': at,
            'updated_at': at,
          };
          await db.insert('asset_record', row('photo:A', 1000));
          await db.insert('asset_record', row('photo:B', 2000));
          if (version >= 16) {
            // A launch of that build already put its triggers in.
            await installChangeLog(db, const ['asset_record']);
          }
          await db.setVersion(version);
          await db.close();

          final store = AssetRecordStore(
            databaseFactory: databaseFactoryFfi,
            path: path,
          );
          final all = await store.listAll();
          expect(all.map((r) => r.localId), ['photo:A', 'photo:B']);
          final a = all.first;
          expect(a.contentHash, 'h-photo:A');
          expect(a.isFavorite, isTrue);
          expect(
            a.stateOf(DerivativeKind.original).destinationKey,
            'p/originals/photo:A.jpg',
          );
          if (version >= 3) expect(a.description, 'caption photo:A');
          final holding = await store.targetsHolding(
            'photo:A',
            DerivativeKind.original,
          );
          if (version < 16) {
            // The v16 adoption, which read the wrong column names until now.
            expect(holding, {'': 'p/originals/photo:A.jpg'});
            if (version >= 5) {
              final rows = await store.uploadRows();
              expect(
                rows.firstWhere(
                  (r) => r['local_id'] == 'photo:A',
                )['source_hash'],
                'x-photo:A',
              );
            }
          } else {
            expect(holding, isEmpty, reason: 'no guessing on a later version');
          }
          // Writes after the upgrade are seen.
          await store.setFavorite('photo:B', false);
          expect((await store.listAll()).last.isFavorite, isFalse);
          await store.close();

          final fresh = await shape(p.join(dir.path, 'fresh.db'));
          final upgraded = await shape(path);
          expect(upgraded, fresh);
        },
      );
    }
  });
}
