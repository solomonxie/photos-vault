import 'package:bring_your_own_photos/photos/photo_library_service.dart';
import 'package:bring_your_own_photos/storage/asset_record.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_manager/photo_manager.dart';

import '../support/fake_asset_record_store.dart';

AssetEntity _entity(
  String id, {
  AssetType type = AssetType.image,
  int createSecond = 0,
  bool isFavorite = false,
}) => AssetEntity(
  id: id,
  typeInt: type.index,
  width: 100,
  height: 100,
  createDateSecond: createSecond,
  isFavorite: isFavorite,
);

void main() {
  test(
    'requestAccess maps authorized/limited/other permission states',
    () async {
      final service = PhotoLibraryService(
        store: FakeAssetRecordStore(),
        requestPermission: () async => PermissionState.authorized,
      );
      expect(await service.requestAccess(), PhotoLibraryAccess.granted);

      final limited = PhotoLibraryService(
        store: FakeAssetRecordStore(),
        requestPermission: () async => PermissionState.limited,
      );
      expect(await limited.requestAccess(), PhotoLibraryAccess.limited);

      final denied = PhotoLibraryService(
        store: FakeAssetRecordStore(),
        requestPermission: () async => PermissionState.denied,
      );
      expect(await denied.requestAccess(), PhotoLibraryAccess.denied);
    },
  );

  test('syncAll upserts every listed asset as a photoManager record', () async {
    final store = FakeAssetRecordStore();
    final service = PhotoLibraryService(
      store: store,
      listAllAssets: () async => [
        _entity('a1'),
        _entity('a2', type: AssetType.video),
      ],
    );

    final added = (await service.syncAll()).added;

    expect(added, hasLength(2));
    expect(added[0].localId, 'photo:a1');
    expect(added[0].sourceType, AssetSourceType.photoManager);
    expect(added[0].isVideo, isFalse);
    expect(added[1].localId, 'photo:a2');
    expect(added[1].isVideo, isTrue);
    expect(await store.listAll(), hasLength(2));
  });

  test('syncAll is a no-op for assets already tracked', () async {
    final store = FakeAssetRecordStore();
    final service = PhotoLibraryService(
      store: store,
      listAllAssets: () async => [_entity('a1')],
    );
    await service.syncAll();

    await service.syncAll();

    expect(await store.listAll(), hasLength(1));
  });

  test('entityFor/fileFor return null for a non-photoManager record', () async {
    final store = FakeAssetRecordStore();
    final record = await store.upsert(
      localId: 'manual:x',
      contentHash: 'x',
      platform: 'ios',
      sourceType: AssetSourceType.manualFile,
      sourcePath: '/tmp/x.jpg',
    );
    final service = PhotoLibraryService(
      store: store,
      loadEntity: (_) async => _entity('unused'),
    );

    expect(await service.entityFor(record), isNull);
    expect(await service.fileFor(record), isNull);
  });

  test(
    'entityFor resolves a photoManager record via its bare asset id',
    () async {
      final store = FakeAssetRecordStore();
      final record = await store.upsert(
        localId: 'photo:a1',
        contentHash: 'a1',
        platform: 'ios',
        sourceType: AssetSourceType.photoManager,
      );
      String? requestedId;
      final service = PhotoLibraryService(
        store: store,
        loadEntity: (id) async {
          requestedId = id;
          return _entity(id);
        },
      );

      final entity = await service.entityFor(record);

      expect(requestedId, 'a1');
      expect(entity?.id, 'a1');
    },
  );

  group('favourites follow the photo library', () {
    test('a heart added in Photos arrives on the next scan', () async {
      final store = FakeAssetRecordStore();
      var favourited = false;
      final service = PhotoLibraryService(
        store: store,
        listAllAssets: () async => [_entity('a1', isFavorite: favourited)],
      );
      await service.syncAll();
      expect((await store.getByLocalId('photo:a1'))!.isFavorite, isFalse);

      favourited = true;
      final result = await service.syncAll();

      expect((await store.getByLocalId('photo:a1'))!.isFavorite, isTrue);
      expect(result.updated, 1);
      expect(
        result.isEmpty,
        isFalse,
        reason: 'nothing was added, but the screen still has to redraw',
      );
    });

    test('and taking one off in Photos arrives the same way', () async {
      final store = FakeAssetRecordStore();
      var favourited = true;
      final service = PhotoLibraryService(
        store: store,
        listAllAssets: () async => [_entity('a1', isFavorite: favourited)],
      );
      await service.syncAll();
      expect((await store.getByLocalId('photo:a1'))!.isFavorite, isTrue);

      favourited = false;
      final result = await service.syncAll();

      expect((await store.getByLocalId('photo:a1'))!.isFavorite, isFalse);
      expect(result.updated, 1);
    });

    test('an unchanged library reports nothing to do', () async {
      final store = FakeAssetRecordStore();
      final service = PhotoLibraryService(
        store: store,
        listAllAssets: () async => [_entity('a1', isFavorite: true)],
      );
      await service.syncAll();

      final result = await service.syncAll();

      expect(result.isEmpty, isTrue);
    });
  });
}
