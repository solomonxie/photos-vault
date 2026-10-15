import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:photo_manager/photo_manager.dart';
import 'package:photos_vault/backup/app_snapshot.dart';
import 'package:photos_vault/photos/photo_library_service.dart';
import 'package:photos_vault/storage/asset_record.dart';
import 'package:photos_vault/storage/asset_record_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../support/fake_album_store.dart';
import '../support/fake_person_store.dart';

AssetEntity _entity(String id) => AssetEntity(
  id: id,
  typeInt: AssetType.image.index,
  width: 4032,
  height: 3024,
  createDateSecond: 1700000000,
);

void main() {
  setUpAll(sqfliteFfiInit);

  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('pv_restore_merge_'));
  tearDown(() => dir.deleteSync(recursive: true));

  var n = 0;
  AssetRecordStore store() {
    final s = AssetRecordStore(
      databaseFactory: databaseFactoryFfi,
      path: p.join(dir.path, 'db${n++}.db'),
    );
    addTearDown(s.close);
    return s;
  }

  ({AssetRecordStore records, FakeAlbumStore albums, AppSnapshotIo io}) phone({
    Future<bool?> Function(String id)? hasAsset,
  }) {
    final records = store();
    final albums = FakeAlbumStore();
    return (
      records: records,
      albums: albums,
      io: AppSnapshotIo(
        assetRecordStore: records,
        albumStore: albums,
        personStore: FakePersonStore(),
        hasAsset: hasAsset,
      ),
    );
  }

  /// The old phone's backup: one photo of asset X with a caption, tags, a
  /// heart, an upload and an album.
  Future<AppSnapshot> backup() async {
    final old = phone();
    await old.records.upsert(
      localId: 'photo:X',
      contentHash: 'X',
      platform: 'ios',
      libraryId: 'X',
      createdAt: _entity('X').createDateTime,
      width: 4032,
      height: 3024,
    );
    await old.records.setDescription('photo:X', 'grandma at the lake');
    await old.records.setTags('photo:X', ['lake', 'family']);
    await old.records.setFavorite('photo:X', true);
    await old.records.updateDerivative(
      'photo:X',
      DerivativeKind.original,
      const DerivativeState(
        status: UploadStatus.uploaded,
        destinationKey: 'p/originals/x.heic',
        backedUpHash: 'h',
      ),
    );
    await old.albums.upsert(id: 'a1', name: 'Summer');
    await old.albums.addAssets('a1', ['photo:X']);
    return old.io.export();
  }

  PhotoLibraryService scanner(
    AssetRecordStore records,
    List<AssetEntity> roll,
  ) => PhotoLibraryService(
    store: records,
    requestPermission: () async => PermissionState.authorized,
    listAssetPage: (page, size) async => page == 0 ? roll : const [],
    loadEntity: (id) async => roll.where((e) => e.id == id).firstOrNull,
  );

  Future<void> expectOneRestored(
    AssetRecordStore records,
    FakeAlbumStore albums, {
    required String libraryId,
  }) async {
    final all = await records.listAll();
    expect(all, hasLength(1), reason: 'no second record of the photo');
    final r = all.single;
    expect(r.localId, 'photo:X');
    expect(r.libraryId, libraryId);
    expect(r.description, 'grandma at the lake');
    expect(r.tags.toSet(), {'lake', 'family'});
    expect(r.isFavorite, isTrue);
    expect(
      r.stateOf(DerivativeKind.original).status,
      UploadStatus.uploaded,
      reason: 'not uploaded all over again',
    );
    expect((await albums.allMemberships())['a1'], ['photo:X']);
  }

  test('same phone: a scan ahead of the restore is merged with', () async {
    final snapshot = await backup();
    final b = phone();
    await scanner(b.records, [_entity('X')]).syncAll();
    expect(await b.io.isFreshInstall(scannedRows: true), isTrue);

    await b.io.import(snapshot);

    await expectOneRestored(b.records, b.albums, libraryId: 'X');
  });

  test('same phone: restore and scan at once leave one record', () async {
    final snapshot = await backup();
    final b = phone();
    await Future.wait([
      b.io.import(snapshot),
      scanner(b.records, [_entity('X')]).syncAll(reconcileDeletions: true),
    ]);

    await expectOneRestored(b.records, b.albums, libraryId: 'X');
  });

  test('new phone, restore first: the scan takes the restored row', () async {
    final snapshot = await backup();
    final b = phone(hasAsset: (id) async => id == 'Y');
    await b.io.import(snapshot);

    await scanner(b.records, [_entity('Y')]).syncAll(reconcileDeletions: true);

    await expectOneRestored(b.records, b.albums, libraryId: 'Y');
  });

  test(
    'new phone, scan first: the restored row takes the scanned one',
    () async {
      final snapshot = await backup();
      final b = phone(hasAsset: (id) async => id == 'Y');
      await scanner(b.records, [_entity('Y')]).syncAll();

      await b.io.import(snapshot);

      await expectOneRestored(b.records, b.albums, libraryId: 'Y');
      expect(
        (await b.records.mergedInto())['photo:Y'],
        'photo:X',
        reason: 'albums and people follow the scanned id',
      );
    },
  );

  test('a row someone already worked on is never restored over', () async {
    final snapshot = await backup();
    final b = phone();
    await scanner(b.records, [_entity('X')]).syncAll();
    await b.records.setDescription('photo:X', 'written on this phone');
    expect(await b.io.isFreshInstall(scannedRows: true), isFalse);

    await b.io.import(snapshot);

    final r = (await b.records.getByLocalId('photo:X'))!;
    expect(r.description, 'written on this phone');
    expect(r.tags, isEmpty);
    expect(await b.records.listAll(), hasLength(1));
  });

  test('two candidates for one asset: neither is guessed at', () async {
    final snapshot = await backup();
    final b = phone(hasAsset: (id) async => id != 'X');
    // Two photos from the same second, same size: a burst.
    await scanner(b.records, [_entity('Y'), _entity('Z')]).syncAll();

    await b.io.import(snapshot);

    final all = await b.records.listAll();
    expect(all, hasLength(3), reason: 'kept apart rather than merged wrong');
    final restored = all.singleWhere((r) => r.localId == 'photo:X');
    expect(restored.tags.toSet(), {'lake', 'family'});
  });
}
