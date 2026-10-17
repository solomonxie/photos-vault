import 'dart:convert';
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

    test('the first read pages through a big library, in order', () async {
      await open().listAll();
      final db = await databaseFactoryFfi.openDatabase(dbPath());
      final batch = db.batch();
      // Ties on the capture time straddle every page boundary.
      for (var i = 0; i < 4500; i++) {
        batch.insert('asset_record', {
          'local_id': 'photo:${(4500 - i).toString().padLeft(5, '0')}',
          'content_hash': 'h$i',
          'platform': 'ios',
          'created_at': i ~/ 3,
          'updated_at': 0,
        });
      }
      await batch.commit(noResult: true);

      final s = open();
      final newest = await s.listNewest(4);
      final all = await s.listAll();

      expect(all, hasLength(4500));
      expect(all.map((r) => r.localId).toSet(), hasLength(4500));
      for (var i = 1; i < all.length; i++) {
        final a = all[i - 1];
        final b = all[i];
        final byDate = a.createdAt.compareTo(b.createdAt);
        expect(
          byDate < 0 || (byDate == 0 && a.localId.compareTo(b.localId) < 0),
          isTrue,
        );
      }
      expect(
        newest.map((r) => r.localId),
        all.sublist(4496).map((r) => r.localId),
      );
      expect(libraryDelta(null, newest), (
        shape: true,
        visibility: true,
        flags: true,
      ));
      expect(identical(await s.listAll(), all), isTrue);
    });

    test('a write during the first read is in the next one', () async {
      final s = open();
      await add(s, 'photo:a', at: DateTime(2020));
      final reading = s.listAll();
      await add(s, 'photo:b', at: DateTime(2019));
      await s.setDescription('photo:a', 'beach');
      await reading;

      final all = await s.listAll();
      expect(all.map((r) => r.localId), ['photo:b', 'photo:a']);
      expect(all.last.description, 'beach');
    });

    test('a removal during the first read never shows', () async {
      final s = open();
      await add(s, 'photo:a');
      await add(s, 'photo:b');
      final reading = s.listAll();
      await s.removeMany(['photo:a']);
      await reading;

      expect((await s.listAll()).map((r) => r.localId), ['photo:b']);
    });

    test('changesBetween: record by record, across lists', () async {
      final s = open();
      for (final id in ['photo:a', 'photo:b', 'photo:c']) {
        await add(s, id);
      }
      final first = await s.listAll();
      expect(s.changesBetween(first, first), isEmpty);

      await s.setFavorite('photo:a', true);
      final second = await s.listAll();
      final heart = s.changesBetween(first, second)!;
      expect(heart, hasLength(1));
      expect(identical(heart.single.before, first[0]), isTrue);
      expect(identical(heart.single.after, second[0]), isTrue);

      await s.remove('photo:b');
      await add(s, 'photo:d');
      final third = await s.listAll();
      final both = {
        for (final c in s.changesBetween(first, third)!)
          (c.before ?? c.after)!.localId: c,
      };
      expect(both.keys, unorderedEquals(['photo:a', 'photo:b', 'photo:d']));
      expect(identical(both['photo:a']!.before, first[0]), isTrue);
      expect(both['photo:b']!.after, isNull);
      expect(both['photo:d']!.before, isNull);
      // Lists not from this store, or not in order: no answer.
      expect(s.changesBetween([...first], third), isNull);
      expect(s.changesBetween(third, first), isNull);
    });

    test('changesBetween: a list published while another call applies '
        'carries that call\'s changes', () async {
      final s = open();
      await add(s, 'photo:a');
      await add(s, 'photo:b');
      final first = await s.listAll();
      await s.setFavorite('photo:a', true);
      await s.setFavorite('photo:b', true);

      final lists = await Future.wait([s.listAll(), s.listAll()]);
      for (final list in lists) {
        final ids = [
          for (final c in s.changesBetween(first, list)!) c.after!.localId,
        ];
        final hearted = [
          for (final r in list)
            if (r.isFavorite) r.localId,
        ];
        expect(ids, unorderedEquals(hearted));
      }
    });

    test('changesBetween: rows lost under the cache break the chain', () async {
      final s = open();
      await add(s, 'photo:a');
      await add(s, 'photo:b');
      final first = await s.listAll();
      final other = AssetRecordStore(
        databaseFactory: databaseFactoryFfi,
        path: dbPath(),
      );
      await other.remove('photo:a');
      final second = await s.listAll();
      expect(second.map((r) => r.localId), ['photo:b']);
      expect(s.changesBetween(first, second), isNull);
    });

    test('listOf: from the cache, in grid order', () async {
      final s = open();
      await add(s, 'photo:new', at: DateTime(2026));
      await add(s, 'photo:old', at: DateTime(2014));
      await add(s, 'photo:mid', at: DateTime(2020));
      for (var i = 0; i < 30; i++) {
        await add(s, 'photo:$i', at: DateTime(2000 + i));
      }
      final some = await s.listOf(['photo:new', 'photo:old', 'photo:gone']);
      expect(some.map((r) => r.localId), ['photo:old', 'photo:new']);
      final all = await s.listAll();
      expect(
        identical(some.last, all.firstWhere((r) => r.localId == 'photo:new')),
        isTrue,
      );
      final most = await s.listOf([for (final r in all) r.localId]);
      expect(most, all);
    });

    test('visibleById reads the cache live, hidden left out', () async {
      final s = open();
      await add(s, 'photo:a');
      await add(s, 'photo:b');
      await s.listAll();
      await s.setHidden('photo:b', true);
      await s.listAll();
      expect(s.visibleById['photo:a'], isNotNull);
      expect(s.visibleById['photo:b'], isNull);
      expect(s.visibleById.keys, ['photo:a']);
    });

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
      expect(libraryDelta(a, b), (
        shape: false,
        visibility: false,
        flags: true,
      ));

      await s.setFavorite('photo:a', true);
      final c = await s.listAll();
      expect(libraryDelta(b, c), (shape: true, visibility: false, flags: true));

      await s.softDelete('photo:a');
      final d = await s.listAll();
      expect(libraryDelta(c, d), (shape: true, visibility: true, flags: true));
      expect(libraryDelta(null, d).shape, isTrue);
    });

    test('libraryDelta: pending to uploading and back moves no flag; an '
        'outcome does', () async {
      final s = open();
      await add(s, 'photo:a');
      final a = await s.listAll();

      Future<List<AssetRecord>> set(UploadStatus status, {String? key}) async {
        await s.updateDerivative(
          'photo:a',
          DerivativeKind.original,
          DerivativeState(status: status, destinationKey: key),
        );
        return s.listAll();
      }

      final uploading = await set(UploadStatus.uploading);
      expect(identical(a, uploading), isFalse);
      expect(libraryDelta(a, uploading).flags, isFalse);
      final back = await set(UploadStatus.pending);
      expect(libraryDelta(a, back).flags, isFalse);

      final failed = await set(UploadStatus.failed);
      expect(libraryDelta(back, failed).flags, isTrue);
      final retried = await set(UploadStatus.pending);
      expect(libraryDelta(failed, retried).flags, isTrue);

      final up = await set(UploadStatus.uploaded, key: 'originals/a.jpg');
      expect(libraryDelta(retried, up).flags, isTrue);
      expect(libraryDelta(retried, up).shape, isFalse);

      await s.setThumbnailPath('photo:a', '/tmp/a.jpg');
      expect(libraryDelta(up, await s.listAll()).flags, isTrue);
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

  test('v28 to v29: the spot check\'s dates move into change_check, and '
      'order its picks', () async {
    final s = open();
    for (final (id, day) in [('a', 1), ('b', 2), ('c', 3), ('d', 4)]) {
      await add(s, 'photo:$id', at: DateTime(2020, 1, day));
      await s.updateDerivative(
        'photo:$id',
        DerivativeKind.original,
        DerivativeState(
          status: UploadStatus.uploaded,
          destinationKey: 'originals/$id.jpg',
        ),
      );
      await s.setLocalDeleted('photo:$id', true);
    }
    await s.markChecked('photo:b', 7);
    await s.close();
    final legacy = await databaseFactoryFfi.openDatabase(dbPath());
    await legacy.execute('ALTER TABLE change_check DROP COLUMN spot_checked');
    await legacy.insert('app_state', {
      'key': 'spot_checked_at',
      'value': jsonEncode({'photo:a': 300, 'photo:b': 100, 'photo:gone': 5}),
    });
    await legacy.setVersion(28);
    await legacy.close();

    final upgraded = open();
    expect(await upgraded.getAppState('spot_checked_at'), isNull);
    // Never checked first (by date), then the longest ago.
    expect(await upgraded.spotCheckOrder(limit: 10), [
      'photo:c',
      'photo:d',
      'photo:b',
      'photo:a',
    ]);
    expect(await upgraded.checkedModified('photo:b'), 7, reason: 'kept');
    expect(await upgraded.spotCheckOrder(limit: 2, offset: 2), [
      'photo:b',
      'photo:a',
    ]);

    await upgraded.markSpotChecked({'photo:c': 400, 'photo:d': 50});
    expect(await upgraded.spotCheckOrder(limit: 10), [
      'photo:d',
      'photo:b',
      'photo:a',
      'photo:c',
    ]);
    await upgraded.markChecked('photo:d', 9);
    expect((await upgraded.spotCheckOrder(limit: 1)).single, 'photo:d');
  });

  test('v27 to v28: whole-row log entries slim to diffs after open', () async {
    final s = open();
    await add(s, 'photo:a', at: DateTime(2020));
    await s.close();
    final legacy = await databaseFactoryFfi.openDatabase(dbPath());
    final row = (await legacy.query('asset_record')).single;
    String whole(Map<String, Object?> changes) =>
        jsonEncode({...row, ...changes});
    // What builds before PW5 wrote: the whole row on both sides.
    await legacy.insert(changeLogTable, {
      'table_name': 'asset_record',
      'row_key': 'photo:a',
      'op': 'update',
      'before': whole({'created_at': 1, 'thumbnail_path': '/old/t.jpg'}),
      'after': whole({'created_at': 2, 'thumbnail_path': '/new/t.jpg'}),
      'at': '',
    });
    await legacy.insert(changeLogTable, {
      'table_name': 'asset_record',
      'row_key': 'photo:a',
      'op': 'update',
      'before': whole({'thumbnail_path': '/old/t.jpg', 'updated_at': 1}),
      'after': whole({'thumbnail_path': '/new/t.jpg', 'updated_at': 2}),
      'at': '',
    });
    await legacy.setVersion(27);
    final mark = await changeLogMark(legacy);
    await legacy.close();

    final upgraded = open();
    await upgraded.setDescription('photo:a', 'after');
    final db = await databaseFactoryFfi.openDatabase(dbPath());
    expect(await upgraded.getAppState('change_log_slim_below'), '${mark + 1}');

    await AssetRecordStore.tidyLog(db);

    final rows = await upgraded.changeLogRows();
    expect(
      (rows.first['after'] as Map)['content_hash'],
      'photo:a',
      reason: 'the insert keeps its row',
    );
    expect(rows[1]['before'], {'created_at': 1});
    expect(rows[1]['after'], {'created_at': 2});
    expect(rows[2]['before'], isEmpty, reason: 'only silent columns moved');
    expect(rows.last['after'], {'description': 'after'});
    expect(await upgraded.changeMark(), mark + 1);
    expect(await upgraded.getAppState('change_log_slim_below'), isNull);
  });

  test('compacting once turns on incremental vacuum; later launches hand '
      'freed pages back', () async {
    final store = open();
    for (var i = 0; i < 300; i++) {
      await store.upsert(
        localId: 'p$i',
        contentHash: 'x' * 2000,
        platform: 'ios',
      );
    }
    await store.close();
    final db = await databaseFactoryFfi.openDatabase(dbPath());
    addTearDown(db.close);
    Future<int> pragma(String name) async =>
        (await db.rawQuery('PRAGMA $name')).first.values.first! as int;

    await AssetRecordStore.compact(db);
    expect(await pragma('auto_vacuum'), 2);
    expect(await pragma('temp_store'), 2, reason: 'back to memory after');

    await db.delete('asset_record');
    await db.delete(changeLogTable);
    expect(await pragma('freelist_count'), greaterThan(0));
    await AssetRecordStore.compact(db);
    expect(await pragma('freelist_count'), 0);
  });
}
