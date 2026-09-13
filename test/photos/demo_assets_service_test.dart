import 'dart:io';

import 'package:back_your_own_photos/photos/demo_assets_service.dart';
import 'package:back_your_own_photos/photos/manual_add.dart';
import 'package:back_your_own_photos/storage/album_store.dart';
import 'package:back_your_own_photos/storage/asset_record.dart';
import 'package:back_your_own_photos/storage/asset_record_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  AssetRecordStore newStore() {
    final store = AssetRecordStore(databaseFactory: databaseFactoryFfi, path: inMemoryDatabasePath);
    addTearDown(store.close);
    return store;
  }

  // A real (temp) file, not `inMemoryDatabasePath` — sqflite's default
  // `singleInstance: true` caches open connections keyed by that literal
  // path string across every store in the process, so an `AssetRecordStore`
  // and an `AlbumStore` both opened against `:memory:` in the same test
  // would silently share one connection (and thus one schema) instead of
  // getting independent databases.
  AlbumStore newAlbumStore() {
    final dir = Directory.systemTemp.createTempSync('album_store_test_');
    final store = AlbumStore(databaseFactory: databaseFactoryFfi, path: p.join(dir.path, 'albums.db'));
    addTearDown(() async {
      await store.close();
      await dir.delete(recursive: true);
    });
    return store;
  }

  DemoAssetsService newService({AssetRecordStore? store, AlbumStore? albumStore}) => DemoAssetsService(
    manualAddService: ManualAddService(
      store: store ?? newStore(),
      targetDirectory: () async => Directory.systemTemp,
    ),
    albumStore: albumStore ?? newAlbumStore(),
    targetDirectory: () async => Directory.systemTemp,
  );

  test('addAll enqueues every bundled demo asset as a manual file', () async {
    final store = newStore();
    final service = newService(store: store);

    final added = await service.addAll();

    expect(added, hasLength(DemoAssetsService.assetPaths.length));
    for (final record in added) {
      expect(record.sourceType, AssetSourceType.manualFile);
      expect(record.sourcePath, isNotNull);
    }
    expect(await store.listAll(), hasLength(DemoAssetsService.assetPaths.length));
  });

  test('addAll groups demo assets into 5 days across 3 years, not one day each', () async {
    final service = newService();

    final added = await service.addAll();

    final days = added.map((r) => DateTime(r.createdAt.year, r.createdAt.month, r.createdAt.day)).toSet();
    final years = added.map((r) => r.createdAt.year).toSet();
    expect(days, hasLength(5));
    expect(years, hasLength(3));
  });

  test('addAll is a no-op for demo assets already present', () async {
    final store = newStore();
    final service = newService(store: store);

    await service.addAll();
    await service.addAll();

    expect(await store.listAll(), hasLength(DemoAssetsService.assetPaths.length));
  });

  test('addAll re-creates a demo asset that was deleted (reset behavior)', () async {
    final store = newStore();
    final service = newService(store: store);
    await service.addAll();
    final firstRecord = (await store.listAll()).first;

    await store.remove(firstRecord.localId);
    expect(await store.listAll(), hasLength(DemoAssetsService.assetPaths.length - 1));

    await service.addAll();

    expect(await store.listAll(), hasLength(DemoAssetsService.assetPaths.length));
  });

  test('addAll seeds preset demo albums with members from the added assets', () async {
    final albumStore = newAlbumStore();
    final service = newService(albumStore: albumStore);

    await service.addAll();

    final albums = await albumStore.listAll();
    expect(albums, hasLength(3));
    expect(albums.every((a) => a.isDemo), isTrue);
    for (final album in albums) {
      expect(await albumStore.localIdsIn(album.id), isNotEmpty);
    }
  });

  test('addAll re-populates a demo album deleted since the last run', () async {
    final albumStore = newAlbumStore();
    final service = newService(albumStore: albumStore);
    await service.addAll();
    final firstAlbum = (await albumStore.listAll()).first;

    await albumStore.remove(firstAlbum.id);
    expect(await albumStore.getById(firstAlbum.id), isNull);

    await service.addAll();

    final restored = await albumStore.getById(firstAlbum.id);
    expect(restored, isNotNull);
    expect(await albumStore.localIdsIn(firstAlbum.id), isNotEmpty);
  });
}
