import 'dart:math' as math;

import 'package:bring_your_own_photos/photos/photo_library_change.dart';
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
  int width = 100,
  int height = 100,
  LatLng? latLng,
}) => AssetEntity(
  id: id,
  typeInt: type.index,
  width: width,
  height: height,
  createDateSecond: createSecond,
  isFavorite: isFavorite,
  latLng: latLng,
);

/// The real service pages the camera roll newest-first; these fakes hand
/// back one page and then nothing, which is all any of these cases need.
Future<List<AssetEntity>> Function(int, int) pagedFrom(
  List<AssetEntity> entities,
) =>
    (page, size) async => page == 0 ? entities : const [];

Future<List<AssetEntity>> Function(int, int) pagedBy(
  List<AssetEntity> Function() entities,
) =>
    (page, size) async => page == 0 ? entities() : const [];

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
      listAssetPage: pagedFrom([
        _entity('a1'),
        _entity('a2', type: AssetType.video),
      ]),
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

  test(
    'syncAll keeps what the library already knows: where and how big',
    () async {
      final store = FakeAssetRecordStore();
      final service = PhotoLibraryService(
        store: store,
        listAssetPage: pagedFrom([
          _entity(
            'a1',
            width: 5857,
            height: 3905,
            latLng: const LatLng(latitude: 48.86, longitude: 2.35),
          ),
          // No GPS tag: reads back as Null Island, which is nobody's holiday.
          _entity('a2', latLng: const LatLng(latitude: 0, longitude: 0)),
        ]),
      );

      await service.syncAll();

      final tagged = (await store.getByLocalId('photo:a1'))!;
      expect(tagged.latitude, 48.86);
      expect(tagged.longitude, 2.35);
      expect(tagged.width, 5857);
      expect(tagged.height, 3905);
      expect((await store.getByLocalId('photo:a2'))!.hasCoordinates, isFalse);
    },
  );

  test(
    'a photo tracked before any of that was kept gets it on the next scan',
    () async {
      final store = FakeAssetRecordStore();
      // Scanned by an older build: tracked, but nothing about it recorded.
      await store.upsert(
        localId: 'photo:a1',
        contentHash: 'a1',
        platform: 'ios',
      );
      final service = PhotoLibraryService(
        store: store,
        listAssetPage: pagedFrom([
          _entity('a1', latLng: const LatLng(latitude: 48.86, longitude: 2.35)),
        ]),
      );

      final result = await service.syncAll();

      expect(result.updated, 1);
      expect((await store.getByLocalId('photo:a1'))!.latitude, 48.86);
    },
  );

  test('syncAll is a no-op for assets already tracked', () async {
    final store = FakeAssetRecordStore();
    final service = PhotoLibraryService(
      store: store,
      listAssetPage: pagedFrom([_entity('a1')]),
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
    'entityFor resolves a photoManager record via the library id it holds',
    () async {
      final store = FakeAssetRecordStore();
      final record = await store.upsert(
        localId: 'photo:a1',
        contentHash: 'a1',
        platform: 'ios',
        sourceType: AssetSourceType.photoManager,
        libraryId: 'a1',
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

  test(
    'a photo taken out of the library resolves to no asset at all',
    () async {
      final store = FakeAssetRecordStore();
      await store.upsert(
        localId: 'photo:a1',
        contentHash: 'a1',
        platform: 'ios',
        sourceType: AssetSourceType.photoManager,
        libraryId: 'a1',
      );
      // Hidden: this app holds the only copy now.
      await store.setLibraryId('photo:a1', null);
      final hidden = (await store.getByLocalId('photo:a1'))!;
      var requested = 0;
      final service = PhotoLibraryService(
        store: store,
        loadEntity: (id) async {
          requested++;
          return _entity(id);
        },
      );

      // The id inside its localId names the asset PhotoKit destroyed — asking
      // for it would hand back the wrong thing, or nothing, at random.
      expect(await service.entityFor(hidden), isNull);
      expect(requested, 0);
    },
  );

  group('favourites follow the photo library', () {
    test('a heart added in Photos arrives on the next scan', () async {
      final store = FakeAssetRecordStore();
      var favourited = false;
      final service = PhotoLibraryService(
        store: store,
        listAssetPage: pagedBy(() => [_entity('a1', isFavorite: favourited)]),
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
        listAssetPage: pagedBy(() => [_entity('a1', isFavorite: favourited)]),
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
        listAssetPage: pagedFrom([_entity('a1', isFavorite: true)]),
      );
      await service.syncAll();

      final result = await service.syncAll();

      expect(result.isEmpty, isTrue);
    });
  });

  group('photos deleted from the library', () {
    Future<PhotoLibraryService> serviceWith(
      FakeAssetRecordStore store,
      List<AssetEntity> Function() listing,
    ) async => PhotoLibraryService(
      store: store,
      listAssetPage: pagedBy(() => listing()),
    );

    test('a backed-up one becomes cloud-only, keeping its place', () async {
      final store = FakeAssetRecordStore();
      var listing = [_entity('a1')];
      final service = await serviceWith(store, () => listing);
      await service.syncAll();
      await store.setDescription('photo:a1', 'the good one');
      await store.updateDerivative(
        'photo:a1',
        DerivativeKind.original,
        const DerivativeState(status: UploadStatus.uploaded),
      );

      listing = [];
      final result = await service.syncAll(reconcileDeletions: true);

      final record = (await store.getByLocalId('photo:a1'))!;
      expect(record.localDeleted, isTrue);
      expect(record.isDeleted, isFalse, reason: 'still in the library');
      expect(record.description, 'the good one', reason: 'metadata survives');
      expect(result.updated, 1);
    });

    test(
      'one that never made it to the bucket goes to Recently Deleted',
      () async {
        final store = FakeAssetRecordStore();
        var listing = [_entity('a1')];
        final service = await serviceWith(store, () => listing);
        await service.syncAll();

        listing = [];
        await service.syncAll(reconcileDeletions: true);

        final record = (await store.getByLocalId('photo:a1'))!;
        expect(record.isDeleted, isTrue);
        expect(
          record,
          isNotNull,
          reason: 'the row survives, so restoring it restores its metadata too',
        );
      },
    );

    test('and coming back out of Photos\' own trash undoes it', () async {
      final store = FakeAssetRecordStore();
      var listing = [_entity('a1')];
      final service = await serviceWith(store, () => listing);
      await service.syncAll();
      await store.updateDerivative(
        'photo:a1',
        DerivativeKind.original,
        const DerivativeState(status: UploadStatus.uploaded),
      );
      listing = [];
      await service.syncAll(reconcileDeletions: true);
      expect((await store.getByLocalId('photo:a1'))!.localDeleted, isTrue);

      listing = [_entity('a1')];
      await service.syncAll(reconcileDeletions: true);

      expect((await store.getByLocalId('photo:a1'))!.localDeleted, isFalse);
    });

    test('nothing happens when the pass is off — the default', () async {
      final store = FakeAssetRecordStore();
      var listing = [_entity('a1')];
      final service = await serviceWith(store, () => listing);
      await service.syncAll();

      listing = [];
      final result = await service.syncAll();

      expect((await store.getByLocalId('photo:a1'))!.isDeleted, isFalse);
      expect(result.isEmpty, isTrue);
    });

    test('an original restored from the bucket is left alone', () async {
      final store = FakeAssetRecordStore();
      var listing = [_entity('a1')];
      final service = await serviceWith(store, () => listing);
      await service.syncAll();
      // "Remove from Device", then Restore Original: gone from the photo
      // library for good, but this app holds a copy of its own.
      await store.setLocalDeleted('photo:a1', true);
      await store.setSourcePath('photo:a1', '/tmp/restored.jpg');
      await store.setLocalDeleted('photo:a1', false);

      listing = [];
      await service.syncAll(reconcileDeletions: true);

      final record = (await store.getByLocalId('photo:a1'))!;
      expect(record.isDeleted, isFalse);
      expect(record.localDeleted, isFalse);
    });
  });

  group('applyChange — the notification path', () {
    PhotoLibraryService serviceOver(
      FakeAssetRecordStore store,
      Map<String, AssetEntity> library,
    ) => PhotoLibraryService(
      store: store,
      // Never lists: the whole point is that a change costs nothing
      // proportional to library size.
      listAssetPage: (page, size) async => throw StateError('should not scan'),
      loadEntity: (id) async => library[id],
    );

    test('a new photo arrives without a scan', () async {
      final store = FakeAssetRecordStore();
      final service = serviceOver(store, {'a1': _entity('a1')});

      final result = await service.applyChange(
        const PhotoLibraryChange(created: {'a1'}),
      );

      expect(result.added.single.localId, 'photo:a1');
      expect(await store.listAll(), hasLength(1));
    });

    test('an edited one updates its favourite in place', () async {
      final store = FakeAssetRecordStore();
      final library = {'a1': _entity('a1')};
      final service = serviceOver(store, library);
      await service.applyChange(const PhotoLibraryChange(created: {'a1'}));

      library['a1'] = _entity('a1', isFavorite: true);
      final result = await service.applyChange(
        const PhotoLibraryChange(updated: {'a1'}),
      );

      expect((await store.getByLocalId('photo:a1'))!.isFavorite, isTrue);
      expect(result.added, isEmpty);
      expect(result.updated, 1);
    });

    test('a deleted one follows the same rule as the scan', () async {
      final store = FakeAssetRecordStore();
      final library = {'a1': _entity('a1'), 'a2': _entity('a2')};
      final service = serviceOver(store, library);
      await service.applyChange(
        const PhotoLibraryChange(created: {'a1', 'a2'}),
      );
      await store.updateDerivative(
        'photo:a1',
        DerivativeKind.original,
        const DerivativeState(status: UploadStatus.uploaded),
      );

      await service.applyChange(
        const PhotoLibraryChange(deleted: {'a1', 'a2'}),
      );

      expect(
        (await store.getByLocalId('photo:a1'))!.localDeleted,
        isTrue,
        reason: 'backed up — stays as a cloud-only item',
      );
      expect(
        (await store.getByLocalId('photo:a2'))!.isDeleted,
        isTrue,
        reason: 'never backed up — binned',
      );
    });

    test('an id that vanished between notice and lookup is skipped', () async {
      final store = FakeAssetRecordStore();
      final service = serviceOver(store, const {});

      final result = await service.applyChange(
        const PhotoLibraryChange(created: {'gone-already'}),
      );

      expect(result.isEmpty, isTrue);
      expect(await store.listAll(), isEmpty);
    });

    test('a delete for something never tracked is ignored', () async {
      final store = FakeAssetRecordStore();
      final service = serviceOver(store, const {});

      final result = await service.applyChange(
        const PhotoLibraryChange(deleted: {'never-seen'}),
      );

      expect(result.isEmpty, isTrue);
    });
  });

  group('a first scan', () {
    List<AssetEntity> newestFirst(int count) => [
      for (var i = count - 1; i >= 0; i--)
        _entity('a$i', createSecond: i * 86400),
    ];

    test('works through the library a page at a time', () async {
      final store = FakeAssetRecordStore();
      final all = newestFirst(450);
      final requested = <int>[];
      final service = PhotoLibraryService(
        store: store,
        listAssetPage: (page, size) async {
          requested.add(page);
          final start = page * size;
          if (start >= all.length) return const [];
          return all.sublist(start, math.min(start + size, all.length));
        },
      );

      final result = await service.syncAll();

      expect(result.added, hasLength(450));
      expect(await store.listAll(), hasLength(450));
      expect(requested, [0, 1, 2], reason: 'a short page ends the scan');
    });

    test('hands over the newest photos before it has read the rest', () async {
      final store = FakeAssetRecordStore();
      final all = newestFirst(450);
      final firstPage = <String>[];
      final service = PhotoLibraryService(
        store: store,
        listAssetPage: (page, size) async {
          final start = page * size;
          if (start >= all.length) return const [];
          return all.sublist(start, math.min(start + size, all.length));
        },
      );

      await service.syncAll(
        onPage: (page) {
          if (firstPage.isNotEmpty) return;
          firstPage.addAll(page.added.map((r) => r.localId));
        },
      );

      // The very newest photo is in the first thing the screen is handed —
      // the page the user is looking at, not the tail of a decade-long
      // scan.
      expect(firstPage.first, 'photo:a449');
      expect(firstPage, hasLength(200));
    });
  });
}
