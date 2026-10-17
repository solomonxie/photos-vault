import 'dart:math' as math;

import 'package:photos_vault/photos/photo_changes.dart';
import 'package:photos_vault/photos/photo_library_change.dart';
import 'package:photos_vault/photos/photo_library_service.dart';
import 'package:photos_vault/storage/asset_record.dart';
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

      // Its link to the asset, and its coordinates.
      expect(result.updated, 2);
      expect((await store.getByLocalId('photo:a1'))!.libraryId, 'a1');
      expect((await store.getByLocalId('photo:a1'))!.latitude, 48.86);
    },
  );

  test(
    'a record re-pointed at an asset while its page was read is not doubled',
    () async {
      final store = _RepointDuringLookup(from: 'photo:X', to: 'C');
      await store.upsert(localId: 'photo:X', contentHash: 'x', platform: 'ios');
      final service = PhotoLibraryService(
        store: store,
        listAssetPage: pagedFrom([_entity('C')]),
      );

      final result = await service.syncAll();

      expect(result.added, isEmpty);
      expect(await store.listAll(), hasLength(1));
      expect((await store.getByLibraryId('C'))!.localId, 'photo:X');
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
      requestPermission: () async => PermissionState.authorized,
      listAssetPage: pagedBy(() => listing()),
      loadEntity: (id) async => listing().where((e) => e.id == id).firstOrNull,
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

    test('one that never made it to the bucket is binned, row kept', () async {
      final store = FakeAssetRecordStore();
      var listing = [_entity('a1')];
      final service = await serviceWith(store, () => listing);
      await service.syncAll();
      await store.setDescription('photo:a1', 'caption');

      listing = [];
      await service.syncAll(reconcileDeletions: true);

      final record = (await store.getByLocalId('photo:a1'))!;
      expect(record.isDeleted, isTrue);
      expect(record.binnedByLibrary, isTrue);
      expect(record.description, 'caption', reason: 'metadata survives');
    });

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

  group('syncRecent — the head pass', () {
    test('reads only the newest pages, not the whole roll', () async {
      final store = FakeAssetRecordStore();
      final requested = <int>[];
      final service = PhotoLibraryService(
        store: store,
        listAssetPage: (page, size) async {
          requested.add(page);
          return [
            for (var i = 0; i < size; i++)
              _entity('p$page-$i', createSecond: 100000 - page * size - i),
          ];
        },
      );

      final result = await service.syncRecent(pages: 2);

      expect(requested, [0, 1]);
      expect(result.added, hasLength(400));
    });

    test('a photo deleted in Photos is accounted for straight away', () async {
      final store = FakeAssetRecordStore();
      var listing = [
        _entity('new', createSecond: 200),
        _entity('old', createSecond: 100),
      ];
      final service = PhotoLibraryService(
        store: store,
        requestPermission: () async => PermissionState.authorized,
        listAssetPage: pagedBy(() => listing),
        loadEntity: (id) async => listing.where((e) => e.id == id).firstOrNull,
      );
      await service.syncRecent();
      await store.updateDerivative(
        'photo:new',
        DerivativeKind.original,
        const DerivativeState(status: UploadStatus.uploaded),
      );

      listing = [_entity('old', createSecond: 100)];
      final result = await service.syncRecent(reconcileDeletions: true);

      expect((await store.getByLocalId('photo:new'))!.localDeleted, isTrue);
      expect(result.updated, 1);
    });

    test(
      'and says nothing about the part of the library it did not read',
      () async {
        final store = FakeAssetRecordStore();
        // Two full pages, so the pass reads page 0 only and everything on
        // page 1 is older than the window it can speak for.
        final all = [
          for (var i = 0; i < 400; i++) _entity('a$i', createSecond: 400 - i),
        ];
        var listing = all;
        final service = PhotoLibraryService(
          store: store,
          requestPermission: () async => PermissionState.authorized,
          listAssetPage: (page, size) async =>
              listing.skip(page * size).take(size).toList(),
          loadEntity: (id) async =>
              listing.where((e) => e.id == id).firstOrNull,
        );
        await service.syncAll();

        // The oldest photo in the library goes; the head pass never saw it
        // and must not guess.
        listing = all.take(399).toList();
        await service.syncRecent(pages: 1, reconcileDeletions: true);
        expect(await store.getByLocalId('photo:a399'), isNotNull);

        await service.syncAll(reconcileDeletions: true);
        expect((await store.getByLocalId('photo:a399'))!.isDeleted, isTrue);
      },
    );

    test('a library smaller than the window is reconciled in full', () async {
      final store = FakeAssetRecordStore();
      var listing = [_entity('a1', createSecond: 100)];
      final service = PhotoLibraryService(
        store: store,
        requestPermission: () async => PermissionState.authorized,
        listAssetPage: pagedBy(() => listing),
        loadEntity: (id) async => listing.where((e) => e.id == id).firstOrNull,
      );
      await service.syncRecent();

      listing = [];
      await service.syncRecent(reconcileDeletions: true);

      expect((await store.getByLocalId('photo:a1'))!.isDeleted, isTrue);
    });

    test(
      'a record the listing missed but the library still has is left alone',
      () async {
        final store = FakeAssetRecordStore();
        var listing = [
          _entity('a1', createSecond: 200),
          _entity('a2', createSecond: 100),
        ];
        final library = {for (final e in listing) e.id: e};
        final service = PhotoLibraryService(
          store: store,
          requestPermission: () async => PermissionState.authorized,
          listAssetPage: pagedBy(() => listing),
          loadEntity: (id) async => library[id],
        );
        await service.syncRecent();

        // Pages shift under a scan as photos arrive and leave: a2 falls
        // through the gap while still being perfectly present.
        listing = [_entity('a1', createSecond: 200)];
        final result = await service.syncRecent(reconcileDeletions: true);

        expect((await store.getByLocalId('photo:a2'))!.isDeleted, isFalse);
        expect(result.updated, 0);
      },
    );
  });

  group('applyChange — the notification path', () {
    PhotoLibraryService serviceOver(
      FakeAssetRecordStore store,
      Map<String, AssetEntity> library,
    ) => PhotoLibraryService(
      store: store,
      requestPermission: () async => PermissionState.authorized,
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

      library.clear();
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
        reason: 'never backed up — binned, row kept',
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

  group('absence never deletes', () {
    PhotoLibraryService serviceOver(
      FakeAssetRecordStore store, {
      required List<AssetEntity> Function() listing,
      PermissionState access = PermissionState.authorized,
      Future<AssetEntity?> Function(String id)? loadEntity,
    }) => PhotoLibraryService(
      store: store,
      requestPermission: () async => access,
      listAssetPage: pagedBy(listing),
      loadEntity:
          loadEntity ??
          (id) async => listing().where((e) => e.id == id).firstOrNull,
    );

    Future<void> expectUntouched(FakeAssetRecordStore store) async {
      final record = (await store.getByLocalId('photo:a1'))!;
      expect(record.isDeleted, isFalse);
      expect(record.localDeleted, isFalse);
    }

    test('limited access marks nothing gone', () async {
      final store = FakeAssetRecordStore();
      var listing = [_entity('a1')];
      await serviceOver(store, listing: () => listing).syncAll();

      listing = [];
      final limited = serviceOver(
        store,
        listing: () => listing,
        access: PermissionState.limited,
      );
      await limited.syncAll(reconcileDeletions: true);
      await limited.applyChange(const PhotoLibraryChange(deleted: {'a1'}));

      await expectUntouched(store);
    });

    test('a failed lookup marks nothing gone', () async {
      final store = FakeAssetRecordStore();
      var listing = [_entity('a1')];
      await serviceOver(store, listing: () => listing).syncAll();

      listing = [];
      final failing = serviceOver(
        store,
        listing: () => listing,
        loadEntity: (id) async => throw StateError('no channel'),
      );
      await failing.syncAll(reconcileDeletions: true);
      await failing.applyChange(const PhotoLibraryChange(deleted: {'a1'}));

      await expectUntouched(store);
    });

    test('a failed permission check marks nothing gone', () async {
      final store = FakeAssetRecordStore();
      var listing = [_entity('a1')];
      await serviceOver(store, listing: () => listing).syncAll();

      listing = [];
      final service = PhotoLibraryService(
        store: store,
        requestPermission: () async => throw StateError('no plugin'),
        listAssetPage: pagedBy(() => listing),
        loadEntity: (id) async => null,
      );
      await service.syncAll(reconcileDeletions: true);
      await service.applyChange(const PhotoLibraryChange(deleted: {'a1'}));

      await expectUntouched(store);
    });

    test('a missing notice for a photo Photos still has is ignored', () async {
      final store = FakeAssetRecordStore();
      final listing = [_entity('a1')];
      final service = serviceOver(store, listing: () => listing);
      await service.syncAll();

      // A tile whose thumbnail didn't come back.
      await service.applyChange(const PhotoLibraryChange(deleted: {'a1'}));

      await expectUntouched(store);
    });

    test(
      'a row the scan binned comes back out when the photo returns',
      () async {
        final store = FakeAssetRecordStore();
        var listing = [_entity('a1')];
        final service = serviceOver(store, listing: () => listing);
        await service.syncAll();
        listing = [];
        await service.syncAll(reconcileDeletions: true);
        expect((await store.getByLocalId('photo:a1'))!.binnedByLibrary, isTrue);

        listing = [_entity('a1')];
        final result = await service.syncAll(reconcileDeletions: true);

        final record = (await store.getByLocalId('photo:a1'))!;
        expect(record.isDeleted, isFalse);
        expect(record.binnedByLibrary, isFalse);
        expect(result.updated, 1);
      },
    );

    test('and through a change notice too', () async {
      final store = FakeAssetRecordStore();
      var listing = [_entity('a1')];
      final service = serviceOver(store, listing: () => listing);
      await service.syncAll();
      listing = [];
      await service.applyChange(const PhotoLibraryChange(deleted: {'a1'}));
      expect((await store.getByLocalId('photo:a1'))!.isDeleted, isTrue);

      listing = [_entity('a1')];
      await service.applyChange(const PhotoLibraryChange(updated: {'a1'}));

      expect((await store.getByLocalId('photo:a1'))!.isDeleted, isFalse);
    });

    test('a row the user binned stays binned', () async {
      final store = FakeAssetRecordStore();
      final listing = [_entity('a1')];
      final service = serviceOver(store, listing: () => listing);
      await service.syncAll();
      await store.softDelete('photo:a1');

      await service.syncAll(reconcileDeletions: true);
      await service.applyChange(const PhotoLibraryChange(updated: {'a1'}));

      expect((await store.getByLocalId('photo:a1'))!.isDeleted, isTrue);
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

  group('WP13b: bin entries and dates', () {
    PhotoLibraryService over(
      FakeAssetRecordStore store,
      List<AssetEntity> Function() listing,
    ) => PhotoLibraryService(
      store: store,
      requestPermission: () async => PermissionState.authorized,
      listAssetPage: pagedBy(() => listing()),
      loadEntity: (id) async => listing().where((e) => e.id == id).firstOrNull,
    );

    test('a bin entry from before binned_by comes out when Photos lists '
        'the asset; the user\'s own stays (04#1)', () async {
      final store = FakeAssetRecordStore();
      final listing = [_entity('a1'), _entity('a2')];
      final service = over(store, () => listing);
      await service.syncAll();
      store.binLegacy('photo:a1');
      await store.softDelete('photo:a2');

      await service.syncAll(reconcileDeletions: true);

      expect((await store.getByLocalId('photo:a1'))!.isDeleted, isFalse);
      expect((await store.getByLocalId('photo:a2'))!.isDeleted, isTrue);
    });

    test('a hidden legacy bin entry is never taken out', () async {
      final store = FakeAssetRecordStore();
      final listing = [_entity('a1')];
      final service = over(store, () => listing);
      await service.syncAll();
      store.binLegacy('photo:a1');
      await store.setPasscodeHash('photo:a1', 'h');

      await service.syncAll();

      expect((await store.getByLocalId('photo:a1'))!.isDeleted, isTrue);
    });

    test('a date changed in Photos reaches the record on an edit notice, '
        'not on a scan or a create (04#12)', () async {
      final store = FakeAssetRecordStore();
      var listing = [_entity('a1', createSecond: 1000)];
      final service = over(store, () => listing);
      await service.syncAll();

      listing = [_entity('a1', createSecond: 5000)];
      await service.syncAll();
      expect(
        (await store.getByLocalId('photo:a1'))!.createdAt,
        DateTime.fromMillisecondsSinceEpoch(1000 * 1000),
      );
      await service.applyChange(
        const PhotoLibraryChange(created: {'a1'}, updated: {'a1'}),
      );
      expect(
        (await store.getByLocalId('photo:a1'))!.createdAt,
        DateTime.fromMillisecondsSinceEpoch(1000 * 1000),
      );

      final result = await service.applyChange(
        const PhotoLibraryChange(updated: {'a1'}),
      );

      expect(result.updated, greaterThan(0));
      expect(
        (await store.getByLocalId('photo:a1'))!.createdAt,
        DateTime.fromMillisecondsSinceEpoch(5000 * 1000),
      );
    });

    test('an app-held file keeps its own date', () async {
      final store = FakeAssetRecordStore();
      var listing = [_entity('a1', createSecond: 1000)];
      final service = over(store, () => listing);
      await service.syncAll();
      await store.setSourcePath('photo:a1', '/tmp/held.jpg');

      listing = [_entity('a1', createSecond: 5000)];
      await service.applyChange(const PhotoLibraryChange(updated: {'a1'}));

      expect(
        (await store.getByLocalId('photo:a1'))!.createdAt,
        DateTime.fromMillisecondsSinceEpoch(1000 * 1000),
      );
    });
  });

  group('PW2: resume from the change history', () {
    PhotoLibraryService serviceOver(
      FakeAssetRecordStore store,
      Map<String, AssetEntity> library,
      _ScriptedChanges changes, {
      PermissionState permission = PermissionState.authorized,
    }) => PhotoLibraryService(
      store: store,
      requestPermission: () async => permission,
      listAssetPage: pagedBy(() => library.values.toList()),
      loadEntity: (id) async => library[id],
      changes: changes,
    );

    test('a full pass leaves a token for the next resume', () async {
      final store = FakeAssetRecordStore();
      final changes = _ScriptedChanges('t0');
      final service = serviceOver(store, {'a1': _entity('a1')}, changes);

      await service.syncAll(reconcileDeletions: true);

      expect(await store.getAppState(PhotoLibraryService.changeTokenKey), 't0');
      expect(
        await store.getAppState(PhotoLibraryService.fullPassAccessKey),
        'full',
      );
      expect(await service.lastFullPassAt(), isNotNull);
    });

    test('a resume applies only what changed, and moves the token', () async {
      final store = FakeAssetRecordStore();
      final library = {'a1': _entity('a1')};
      final changes = _ScriptedChanges('t0');
      var listed = 0;
      final service = PhotoLibraryService(
        store: store,
        requestPermission: () async => PermissionState.authorized,
        listAssetPage: (page, size) async {
          listed++;
          return page == 0 ? library.values.toList() : const [];
        },
        loadEntity: (id) async => library[id],
        changes: changes,
      );
      await service.syncAll(reconcileDeletions: true);
      final afterPass = listed;

      library
        ..remove('a1')
        ..['a2'] = _entity('a2', createSecond: 5);
      changes.next = const PhotoChangeDelta(
        change: PhotoLibraryChange(created: {'a2'}, deleted: {'a1'}),
        token: 't1',
      );
      final result = await service.syncChanges();

      expect(listed, afterPass, reason: 'no listing on a resume');
      expect(changes.asked, ['t0']);
      expect(result!.added.single.localId, 'photo:a2');
      expect(
        (await store.getByLocalId('photo:a1'))!.isDeleted,
        isTrue,
        reason: 'gone, never backed up: binned by the same rule as a scan',
      );
      expect(await store.getAppState(PhotoLibraryService.changeTokenKey), 't1');
    });

    test('a deletion it reports is asked about again first', () async {
      final store = FakeAssetRecordStore();
      final library = {'a1': _entity('a1')};
      final changes = _ScriptedChanges('t0');
      final service = serviceOver(store, library, changes);
      await service.syncAll(reconcileDeletions: true);

      changes.next = const PhotoChangeDelta(
        change: PhotoLibraryChange(deleted: {'a1'}),
        token: 't1',
      );
      await service.syncChanges();

      final record = (await store.getByLocalId('photo:a1'))!;
      expect(record.isDeleted, isFalse, reason: 'Photos still has it');
      expect(record.localDeleted, isFalse);
    });

    test('under limited access it marks nothing gone', () async {
      final store = FakeAssetRecordStore();
      final library = {'a1': _entity('a1')};
      final changes = _ScriptedChanges('t0');
      final service = serviceOver(
        store,
        library,
        changes,
        permission: PermissionState.limited,
      );
      await service.syncAll();

      library.clear();
      changes.next = const PhotoChangeDelta(
        change: PhotoLibraryChange(deleted: {'a1'}),
        token: 't1',
      );
      expect(await service.syncChanges(), isNotNull);

      final record = (await store.getByLocalId('photo:a1'))!;
      expect(record.isDeleted, isFalse);
      expect(record.localDeleted, isFalse);
    });

    test('no token yet means a full pass', () async {
      final service = serviceOver(
        FakeAssetRecordStore(),
        const {},
        _ScriptedChanges(null),
      );

      expect(await service.syncChanges(), isNull);
    });

    test('an expired token means a full pass, and is kept', () async {
      final store = FakeAssetRecordStore();
      final changes = _ScriptedChanges('t0');
      final service = serviceOver(store, {'a1': _entity('a1')}, changes);
      await service.syncAll(reconcileDeletions: true);

      changes.next = null;

      expect(await service.syncChanges(), isNull);
      expect(await store.getAppState(PhotoLibraryService.changeTokenKey), 't0');
    });

    test('access changed since the last pass means a full pass', () async {
      final store = FakeAssetRecordStore();
      final changes = _ScriptedChanges('t0')
        ..next = const PhotoChangeDelta(
          change: PhotoLibraryChange(),
          token: 't1',
        );
      // Made under "Selected Photos": it reconciled nothing.
      await serviceOver(
        store,
        {'a1': _entity('a1')},
        changes,
        permission: PermissionState.limited,
      ).syncAll();

      final granted = serviceOver(store, {'a1': _entity('a1')}, changes);

      expect(await granted.syncChanges(), isNull);
      expect(changes.asked, isEmpty);
    });

    test('restored rows waiting for an asset mean a full pass', () async {
      final store = FakeAssetRecordStore();
      final changes = _ScriptedChanges('t0')
        ..next = const PhotoChangeDelta(
          change: PhotoLibraryChange(),
          token: 't1',
        );
      final service = serviceOver(store, {'a1': _entity('a1')}, changes);
      await service.syncAll(reconcileDeletions: true);
      await store.markRelinkPending('photo:a1', DateTime(2020));

      expect(await service.syncChanges(), isNull);
    });

    test('a delta past the limit means a full pass', () async {
      final store = FakeAssetRecordStore();
      final changes = _ScriptedChanges('t0');
      final service = serviceOver(store, const {}, changes);
      await service.syncAll(reconcileDeletions: true);

      changes.next = PhotoChangeDelta(
        change: PhotoLibraryChange(
          updated: {
            for (var i = 0; i <= PhotoLibraryService.deltaLimit; i++) 'x$i',
          },
        ),
        token: 't1',
      );

      expect(await service.syncChanges(), isNull);
      expect(await store.getAppState(PhotoLibraryService.changeTokenKey), 't0');
    });
  });

  group('PW2: one write per page', () {
    test('new assets go in as one batch, not a commit per row', () async {
      final store = FakeAssetRecordStore();
      final service = PhotoLibraryService(
        store: store,
        listAssetPage: pagedFrom([
          _entity('a1', isFavorite: true),
          _entity('a2', type: AssetType.video),
          _entity('a3'),
        ]),
      );

      final result = await service.syncAll();

      expect(result.added, hasLength(3));
      expect(store.scanBatches, 1);
      expect((await store.getByLocalId('photo:a1'))!.isFavorite, isTrue);
      expect((await store.getByLocalId('photo:a2'))!.isVideo, isTrue);
    });

    test('and the page\'s updates as one more', () async {
      final store = FakeAssetRecordStore();
      var hearted = false;
      final service = PhotoLibraryService(
        store: store,
        listAssetPage: pagedBy(
          () => [
            _entity('a1', isFavorite: hearted),
            _entity('a2', isFavorite: hearted),
          ],
        ),
      );
      await service.syncAll();
      final before = store.scanBatches;

      hearted = true;
      final result = await service.syncAll();

      expect(result.updated, 2);
      expect(store.scanBatches, before + 1);
      expect((await store.getByLocalId('photo:a2'))!.isFavorite, isTrue);
    });

    test('with restored rows waiting, each asset is offered to them', () async {
      final store = FakeAssetRecordStore();
      await store.upsert(
        localId: 'photo:old',
        contentHash: 'old',
        platform: 'ios',
        createdAt: DateTime.fromMillisecondsSinceEpoch(7000),
        width: 100,
        height: 100,
      );
      await store.markRelinkPending(
        'photo:old',
        DateTime.fromMillisecondsSinceEpoch(7000),
      );
      final service = PhotoLibraryService(
        store: store,
        listAssetPage: pagedFrom([_entity('new', createSecond: 7)]),
        loadEntity: (id) async => null,
      );

      await service.syncAll();

      expect(store.scanBatches, 0);
      expect((await store.getByLocalId('photo:old'))!.libraryId, 'new');
      expect(await store.getByLocalId('photo:new'), isNull);
    });

    test('a new image\'s filename is asked for, for the GIF check', () async {
      final store = FakeAssetRecordStore();
      final asked = <String>[];
      final service = PhotoLibraryService(
        store: store,
        listAssetPage: pagedFrom([
          _entity('g'),
          _entity('v', type: AssetType.video),
        ]),
        loadTitle: (entity) async {
          asked.add(entity.id);
          return 'party.GIF';
        },
      );

      await service.syncAll();
      await service.syncAll();

      expect(asked, ['g'], reason: 'new images only, once');
      expect((await store.getByLocalId('photo:g'))!.isGif, isTrue);
    });

    test('a listed title is used as it is', () async {
      final store = FakeAssetRecordStore();
      final service = PhotoLibraryService(
        store: store,
        listAssetPage: pagedFrom([
          AssetEntity(
            id: 'g',
            typeInt: AssetType.image.index,
            width: 1,
            height: 1,
            title: 'party.GIF',
          ),
        ]),
      );

      await service.syncAll();

      expect((await store.getByLocalId('photo:g'))!.isGif, isTrue);
    });
  });
}

/// A swap landing between the page lookup and its inserts.
class _RepointDuringLookup extends FakeAssetRecordStore {
  _RepointDuringLookup({required this.from, required this.to});

  final String from;
  final String to;

  @override
  Future<Map<String, AssetRecord>> getByLibraryIds(
    Iterable<String> libraryIds,
  ) async {
    final page = await super.getByLibraryIds(libraryIds);
    await setLibraryId(from, to);
    return page;
  }
}

class _ScriptedChanges extends PhotoChanges {
  _ScriptedChanges(this.current);

  String? current;
  PhotoChangeDelta? next;
  final asked = <String>[];

  @override
  Future<String?> token() async => current;

  @override
  Future<PhotoChangeDelta?> since(String token) async {
    asked.add(token);
    return next;
  }
}
