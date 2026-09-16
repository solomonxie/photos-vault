import 'package:bring_your_own_photos/storage/asset_record.dart';
import 'package:bring_your_own_photos/storage/asset_record_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  // sqflite_common_ffi caches in-memory DBs by path (singleInstance
  // default), so distinct stores using the same sentinel path leak state
  // across tests unless each is explicitly closed.
  AssetRecordStore newStore() {
    final store = AssetRecordStore(
      databaseFactory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    addTearDown(store.close);
    return store;
  }

  test('upsert creates a record with all derivatives pending', () async {
    final store = newStore();

    final record = await store.upsert(
      localId: 'asset-1',
      contentHash: 'hash-1',
      platform: 'ios',
    );

    expect(record.localId, 'asset-1');
    for (final kind in DerivativeKind.values) {
      expect(record.stateOf(kind).status, UploadStatus.pending);
      expect(record.stateOf(kind).destinationKey, isNull);
    }
  });

  test('upsert persists isVideo, defaulting to false', () async {
    final store = newStore();

    final photo = await store.upsert(
      localId: 'asset-1',
      contentHash: 'hash-1',
      platform: 'ios',
    );
    final video = await store.upsert(
      localId: 'asset-2',
      contentHash: 'hash-2',
      platform: 'ios',
      isVideo: true,
    );

    expect(photo.isVideo, isFalse);
    expect(video.isVideo, isTrue);
    expect((await store.getByLocalId('asset-2'))!.isVideo, isTrue);
  });

  test('upsert is idempotent for an already-tracked localId', () async {
    final store = newStore();
    final first = await store.upsert(
      localId: 'asset-1',
      contentHash: 'hash-1',
      platform: 'ios',
    );

    final second = await store.upsert(
      localId: 'asset-1',
      contentHash: 'different-hash',
      platform: 'ios',
    );

    expect(second.contentHash, first.contentHash);
    expect(await store.listAll(), hasLength(1));
  });

  test('updateDerivative persists status and destination key for that derivative only', () async {
    final store = newStore();
    await store.upsert(
      localId: 'asset-1',
      contentHash: 'hash-1',
      platform: 'ios',
    );

    await store.updateDerivative(
      'asset-1',
      DerivativeKind.thumbnail,
      const DerivativeState(
        status: UploadStatus.uploaded,
        destinationKey: 'thumbnails/asset-1.jpg',
      ),
    );

    final record = await store.getByLocalId('asset-1');
    expect(
      record!.stateOf(DerivativeKind.thumbnail).status,
      UploadStatus.uploaded,
    );
    expect(
      record.stateOf(DerivativeKind.thumbnail).destinationKey,
      'thumbnails/asset-1.jpg',
    );
    expect(record.stateOf(DerivativeKind.medium).status, UploadStatus.pending);
  });

  test(
    'updateDerivative persists backedUpHash for that derivative only',
    () async {
      final store = newStore();
      await store.upsert(
        localId: 'asset-1',
        contentHash: 'hash-1',
        platform: 'ios',
      );

      await store.updateDerivative(
        'asset-1',
        DerivativeKind.original,
        const DerivativeState(
          status: UploadStatus.uploaded,
          backedUpHash: 'sha256:abc',
        ),
      );

      final record = await store.getByLocalId('asset-1');
      expect(
        record!.stateOf(DerivativeKind.original).backedUpHash,
        'sha256:abc',
      );
      expect(record.stateOf(DerivativeKind.medium).backedUpHash, isNull);
    },
  );

  test('thumbnail path and the cloud-only flag round-trip', () async {
    final store = newStore();
    await store.upsert(
      localId: 'asset-1',
      contentHash: 'hash-1',
      platform: 'ios',
    );

    expect((await store.getByLocalId('asset-1'))!.thumbnailPath, isNull);
    expect((await store.getByLocalId('asset-1'))!.localDeleted, isFalse);

    await store.setThumbnailPath('asset-1', '/thumbs/asset-1.jpg');
    await store.setLocalDeleted('asset-1', true);

    final record = (await store.getByLocalId('asset-1'))!;
    expect(record.thumbnailPath, '/thumbs/asset-1.jpg');
    expect(record.localDeleted, isTrue);
  });

  test('setSourcePath points a record at a restored local file', () async {
    final store = newStore();
    await store.upsert(
      localId: 'asset-1',
      contentHash: 'hash-1',
      platform: 'ios',
    );

    await store.setSourcePath('asset-1', '/restored/asset-1.jpg');

    expect(
      (await store.getByLocalId('asset-1'))!.sourcePath,
      '/restored/asset-1.jpg',
    );
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

  test(
    'remove deletes the record so a later upsert re-creates it fresh',
    () async {
      final store = newStore();
      await store.upsert(
        localId: 'asset-1',
        contentHash: 'hash-1',
        platform: 'ios',
      );

      await store.remove('asset-1');

      expect(await store.getByLocalId('asset-1'), isNull);
      final recreated = await store.upsert(
        localId: 'asset-1',
        contentHash: 'hash-2',
        platform: 'ios',
      );
      expect(recreated.contentHash, 'hash-2');
    },
  );

  test('setFavorite toggles the favorite flag', () async {
    final store = newStore();
    await store.upsert(
      localId: 'asset-1',
      contentHash: 'hash-1',
      platform: 'ios',
    );

    await store.setFavorite('asset-1', true);
    expect((await store.getByLocalId('asset-1'))!.isFavorite, isTrue);

    await store.setFavorite('asset-1', false);
    expect((await store.getByLocalId('asset-1'))!.isFavorite, isFalse);
  });

  test('setHidden toggles the hidden flag', () async {
    final store = newStore();
    await store.upsert(
      localId: 'asset-1',
      contentHash: 'hash-1',
      platform: 'ios',
    );

    await store.setHidden('asset-1', true);
    expect((await store.getByLocalId('asset-1'))!.isHidden, isTrue);

    await store.setHidden('asset-1', false);
    expect((await store.getByLocalId('asset-1'))!.isHidden, isFalse);
  });

  test('softDelete sets deletedAt, restore clears it', () async {
    final store = newStore();
    await store.upsert(
      localId: 'asset-1',
      contentHash: 'hash-1',
      platform: 'ios',
    );

    await store.softDelete('asset-1');
    final deleted = await store.getByLocalId('asset-1');
    expect(deleted!.isDeleted, isTrue);

    await store.restore('asset-1');
    final restored = await store.getByLocalId('asset-1');
    expect(restored!.isDeleted, isFalse);
  });

  test(
    'a freshly-upserted record has empty description/tags, no location',
    () async {
      final store = newStore();
      final record = await store.upsert(
        localId: 'asset-1',
        contentHash: 'hash-1',
        platform: 'ios',
      );

      expect(record.description, '');
      expect(record.tags, isEmpty);
      expect(record.location, isNull);
    },
  );

  test(
    'setCreatedAt overwrites the timestamp used for date grouping',
    () async {
      final store = newStore();
      await store.upsert(
        localId: 'asset-1',
        contentHash: 'hash-1',
        platform: 'ios',
        createdAt: DateTime(2020, 1, 1),
      );

      await store.setCreatedAt('asset-1', DateTime(2021, 6, 15));

      expect(
        (await store.getByLocalId('asset-1'))!.createdAt,
        DateTime(2021, 6, 15),
      );
    },
  );

  test('setDescription/setTags/setLocation persist and round-trip', () async {
    final store = newStore();
    await store.upsert(
      localId: 'asset-1',
      contentHash: 'hash-1',
      platform: 'ios',
    );

    await store.setDescription('asset-1', 'A trip to the mountains.');
    await store.setTags('asset-1', ['sunset', 'hiking']);
    await store.setLocation('asset-1', 'Kyoto, Japan');

    final record = await store.getByLocalId('asset-1');
    expect(record!.description, 'A trip to the mountains.');
    expect(record.tags, ['sunset', 'hiking']);
    expect(record.location, 'Kyoto, Japan');
  });

  test('setEvent round-trips and allEvents skips the unset ones', () async {
    final store = newStore();
    for (final id in ['asset-1', 'asset-2', 'asset-3']) {
      await store.upsert(localId: id, contentHash: id, platform: 'ios');
    }

    await store.setEvent('asset-1', "Nina's Wedding");
    await store.setEvent('asset-2', "Nina's Wedding");

    expect((await store.getByLocalId('asset-1'))!.event, "Nina's Wedding");
    expect((await store.getByLocalId('asset-3'))!.event, isNull);
    expect(await store.allEvents(), {"Nina's Wedding"});

    await store.setEvent('asset-1', null);
    expect((await store.getByLocalId('asset-1'))!.event, isNull);
  });

  test('setLocation(null) clears a previously-set location', () async {
    final store = newStore();
    await store.upsert(
      localId: 'asset-1',
      contentHash: 'hash-1',
      platform: 'ios',
    );
    await store.setLocation('asset-1', 'Kyoto, Japan');

    await store.setLocation('asset-1', null);

    expect((await store.getByLocalId('asset-1'))!.location, isNull);
  });

  test(
    'allLocations returns distinct, non-empty locations across photos',
    () async {
      final store = newStore();
      await store.upsert(
        localId: 'asset-1',
        contentHash: 'h1',
        platform: 'ios',
      );
      await store.upsert(
        localId: 'asset-2',
        contentHash: 'h2',
        platform: 'ios',
      );
      await store.upsert(
        localId: 'asset-3',
        contentHash: 'h3',
        platform: 'ios',
      );
      await store.setLocation('asset-1', 'Kyoto, Japan');
      await store.setLocation('asset-2', 'Kyoto, Japan');
      await store.setLocation('asset-3', null);

      expect(await store.allLocations(), {'Kyoto, Japan'});
    },
  );

  test('allTags returns the union of tags used across photos', () async {
    final store = newStore();
    await store.upsert(localId: 'asset-1', contentHash: 'h1', platform: 'ios');
    await store.upsert(localId: 'asset-2', contentHash: 'h2', platform: 'ios');
    await store.setTags('asset-1', ['sunset', 'hiking']);
    await store.setTags('asset-2', ['hiking', 'family']);

    expect(await store.allTags(), {'sunset', 'hiking', 'family'});
  });

  group('app state', () {
    test('round-trips a flag, and starts absent', () async {
      final store = newStore();

      expect(await store.getAppState('seeded'), isNull);
      await store.setAppState('seeded', 'true');

      expect(await store.getAppState('seeded'), 'true');
    });

    test('writing the same key again replaces it', () async {
      final store = newStore();
      await store.setAppState('seeded', 'true');

      await store.setAppState('seeded', 'again');

      expect(await store.getAppState('seeded'), 'again');
    });
  });
}
