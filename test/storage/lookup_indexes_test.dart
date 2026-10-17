import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:photos_vault/storage/asset_record.dart';
import 'package:photos_vault/storage/asset_record_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// PW9: DB-11, DB-12, DB-13.
void main() {
  setUpAll(sqfliteFfiInit);

  late Directory dir;
  late AssetRecordStore store;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('pv_lookup_');
    store = AssetRecordStore(
      databaseFactory: databaseFactoryFfi,
      path: p.join(dir.path, 'a.db'),
    );
  });
  tearDown(() async {
    await store.close();
    await dir.delete(recursive: true);
  });

  Future<void> add(
    String id, {
    String? path,
    String? passcode,
    double? latitude,
    DateTime? at,
  }) async {
    await store.upsert(
      localId: id,
      contentHash: id,
      platform: 'ios',
      sourceType: path == null
          ? AssetSourceType.photoManager
          : AssetSourceType.manualFile,
      sourcePath: path,
      latitude: latitude,
      longitude: latitude,
      createdAt: at,
    );
    if (passcode != null) await store.setPasscodeHash(id, passcode);
  }

  Future<List<String>> plan(String sql, [List<Object?> args = const []]) async {
    await store.listAll();
    await store.close();
    final db = await databaseFactoryFfi.openDatabase(p.join(dir.path, 'a.db'));
    try {
      return [
        for (final row in await db.rawQuery('EXPLAIN QUERY PLAN $sql', args))
          '${row['detail']}',
      ];
    } finally {
      await db.close();
    }
  }

  group('source_path (DB-12)', () {
    test('plainIdsUnder takes the folder and nothing beside it', () async {
      await add('manual:a', path: '/v/plain/a.jpg');
      await add('manual:b', path: '/v/plain/sub/b.jpg');
      await add('manual:c', path: '/v/plain2/c.jpg');
      await add('manual:d', path: '/v/plain/d.jpg', passcode: 'h');
      await add('photo:e');
      expect((await store.plainIdsUnder('/v/plain'))..sort(), [
        'manual:a',
        'manual:b',
      ]);
      expect(await store.sourcePathShared('/v/plain/a.jpg', 'manual:x'), true);
      expect(await store.sourcePathShared('/v/plain/a.jpg', 'manual:a'), false);
    });

    test('both read the path index, not the passcode one', () async {
      await add('manual:a', path: '/v/plain/a.jpg');
      final under = await plan(
        'SELECT local_id FROM asset_record WHERE +passcode_hash IS NULL '
        'AND source_path >= ? AND source_path < ?',
        ['/v/plain/', '/v/plain0'],
      );
      expect(under.join(), contains('asset_record_source_path'));
      final shared = await plan(
        'SELECT local_id FROM asset_record '
        'WHERE source_path = ? AND local_id != ? LIMIT 1',
        ['/v/plain/a.jpg', 'x'],
      );
      expect(shared.join(), contains('asset_record_source_path'));
    });
  });

  group('places (DB-13)', () {
    test('listAwaitingPlaceName walks its own index, newest first', () async {
      await add('photo:old', latitude: 1, at: DateTime(2020));
      await add('photo:new', latitude: 1, at: DateTime(2024));
      await add('photo:named', latitude: 1, at: DateTime(2025));
      await store.setLocation('photo:named', 'Paris');
      await add('photo:none', at: DateTime(2026));
      expect(
        [for (final r in await store.listAwaitingPlaceName()) r.localId],
        ['photo:new', 'photo:old'],
      );
      final rows = await plan(
        "SELECT * FROM asset_record WHERE latitude IS NOT NULL AND longitude "
        "IS NOT NULL AND (location IS NULL OR location = '') AND deleted_at "
        'IS NULL ORDER BY created_at DESC LIMIT 5',
      );
      expect(rows.join(), contains('asset_record_awaiting_place'));
      expect(rows.join(), isNot(contains('TEMP B-TREE')));
    });

    test('fillLocations never overwrites a name typed meanwhile', () async {
      await add('photo:a', latitude: 1);
      await add('photo:b', latitude: 1);
      await store.setLocation('photo:b', 'Typed');
      expect(
        await store.fillLocations({
          'photo:a': 'Paris',
          'photo:b': 'Paris',
          'photo:gone': 'Paris',
        }),
        1,
      );
      expect((await store.getByLocalId('photo:a'))!.location, 'Paris');
      expect((await store.getByLocalId('photo:b'))!.location, 'Typed');
    });

    test('the picker lists are kept until a row changes or goes', () async {
      await add('photo:a');
      await store.setTags('photo:a', ['sea']);
      await store.setLocation('photo:a', 'Nice');
      expect(await store.allTags(), {'sea'});
      expect(await store.allLocations(), {'Nice'});
      // A caller's copy, not the memo.
      (await store.allTags()).add('mutated');
      expect(await store.allTags(), {'sea'});

      await store.setTags('photo:a', ['sea', 'sun']);
      await store.setLocation('photo:a', 'Cannes');
      expect(await store.allTags(), {'sea', 'sun'});
      expect(await store.allLocations(), {'Cannes'});

      await store.removeMany(['photo:a']);
      expect(await store.allTags(), isEmpty);
      expect(await store.allLocations(), isEmpty);
    });
  });

  group('originalStemHeld (DB-11)', () {
    Future<void> uploaded(String id, String key) async {
      await add(id);
      await store.updateDerivative(
        id,
        DerivativeKind.original,
        DerivativeState(status: UploadStatus.uploaded, destinationKey: key),
      );
    }

    test('found under the bucket\'s prefix by the index', () async {
      await uploaded('photo:a', 'pv/originals/IMG_1.heic');
      expect(await store.originalStemHeld('IMG_1', prefixes: ['pv/']), true);
      expect(await store.originalStemHeld('IMG_1', prefixes: ['pv']), true);
      final rows = await plan(
        'SELECT 1 FROM asset_record WHERE original_key >= ? '
        'AND original_key < ? LIMIT 1',
        ['pv/originals/IMG_1.', 'pv/originals/IMG_1/'],
      );
      expect(rows.join(), contains('asset_record_original_key'));
    });

    test('a key under another prefix or folder is still found', () async {
      await uploaded('photo:a', 'old/originals/IMG_1.jpg');
      await uploaded('photo:b', 'pv/originals/sub/IMG_2.jpg');
      await store.recordUpload(
        localId: 'photo:c',
        kind: DerivativeKind.original,
        targetId: 't',
        destinationKey: 'x/IMG_3.png',
      );
      for (final stem in ['IMG_1', 'IMG_2', 'IMG_3']) {
        expect(
          await store.originalStemHeld(stem, prefixes: ['pv/']),
          isTrue,
          reason: stem,
        );
      }
      expect(await store.originalStemHeld('IMG_4', prefixes: ['pv/']), false);
      expect(await store.originalStemHeld('IMG_', prefixes: ['pv/']), false);
    });
  });
}
