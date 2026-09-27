import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:photo_manager/photo_manager.dart';
import 'package:photos_vault/photos/asset_removal.dart';
import 'package:photos_vault/photos/photo_library_service.dart';
import 'package:photos_vault/photos/thumbnail_cache.dart';
import 'package:photos_vault/settings/backup_targets_store.dart';
import 'package:photos_vault/storage/asset_record.dart';
import 'package:photos_vault/upload/backup_verifier.dart';

import '../settings/fake_secure_store.dart';
import '../support/fake_asset_record_store.dart';

void main() {
  late Directory tempDir;

  setUp(() => tempDir = Directory.systemTemp.createTempSync('pv_removal_'));
  tearDown(() => tempDir.delete(recursive: true));

  var deleted = <List<String>>[];
  setUp(() => deleted = <List<String>>[]);

  /// A bucket that answers 200 for everything, so `removeFromDevice` gets
  /// the confirmation it now insists on before deleting a local original.
  /// [answer] is the status code to hand back — 404 for a bucket that
  /// hasn't got the object, and a targets store with nothing in it for a
  /// bucket that can't be reached at all.
  Future<BackupVerifier> verifierOver(
    FakeAssetRecordStore store, {
    int answer = 200,
    bool configured = true,
  }) async {
    final targets = BackupTargetsStore(store: FakeSecureStore());
    if (configured) {
      await targets.add(
        accessKeyId: 'AKIA',
        secretAccessKey: 'secret',
        region: 'us-east-1',
        bucket: 'bucket',
        prefix: 'photos/',
      );
    }
    return BackupVerifier(
      targetsStore: targets,
      recordStore: store,
      head: (_) async => http.Response('', answer),
    );
  }

  AssetRemoval removalOver(
    FakeAssetRecordStore store, {
    List<String> refuse = const [],
    Future<Uint8List?> Function(AssetRecord)? libraryThumbnail,
    Future<AssetEntity?> Function(String id)? loadEntity,
    BackupVerifier? verifier,
  }) => AssetRemoval(
    verifier: verifier,
    store: store,
    thumbnails: ThumbnailCache(
      store: store,
      directory: () async => tempDir,
      encode: (_) async => Uint8List.fromList([1]),
      libraryThumbnail:
          libraryThumbnail ?? (_) async => Uint8List.fromList([2]),
    ),
    library: PhotoLibraryService(
      store: store,
      loadEntity: loadEntity ?? (_) async => null,
      deleteAssets: (ids) async {
        deleted.add(ids);
        return ids.where((id) => !refuse.contains(id)).toList();
      },
    ),
  );

  Future<AssetRecord> backedUp(
    FakeAssetRecordStore store, {
    bool isVideo = false,
    String? libraryId = 'lib-1',
  }) async {
    await store.upsert(
      localId: 'photo:1',
      contentHash: '1',
      platform: 'ios',
      isVideo: isVideo,
      libraryId: libraryId,
    );
    await store.updateDerivative(
      'photo:1',
      DerivativeKind.original,
      const DerivativeState(
        status: UploadStatus.uploaded,
        // A key is what the bucket can be asked about; a row claiming to be
        // uploaded without one is not verifiable and is refused.
        destinationKey: 'photos/originals/photo_1.mov',
      ),
    );
    return (await store.getByLocalId('photo:1'))!;
  }

  test(
    'a backed-up video can go cloud-only, keeping its poster frame',
    () async {
      final store = FakeAssetRecordStore();
      final record = await backedUp(store, isVideo: true);
      final removal = removalOver(store, verifier: await verifierOver(store));

      expect(removal.canRemoveFromDevice(record), isTrue);
      expect(await removal.removeFromDevice(record), RemovalOutcome.freed);

      final saved = (await store.getByLocalId('photo:1'))!;
      expect(saved.localDeleted, isTrue);
      // Still something for the grid to draw.
      expect(File(saved.thumbnailPath!).readAsBytesSync(), [2]);
      expect(deleted, [
        ['lib-1'],
      ]);
    },
  );

  test('an imported video with no frame to draw is not offered it', () async {
    final store = FakeAssetRecordStore();
    final record = await backedUp(store, isVideo: true, libraryId: null);

    expect(removalOver(store).canRemoveFromDevice(record), isFalse);
  });

  test('a photo with no backup is not offered it either', () async {
    final store = FakeAssetRecordStore();
    final record = await store.upsert(
      localId: 'photo:2',
      contentHash: '2',
      platform: 'ios',
      libraryId: 'lib-2',
    );

    expect(removalOver(store).canRemoveFromDevice(record), isFalse);
  });

  test('a declined OS prompt leaves the record exactly as it was', () async {
    final store = FakeAssetRecordStore();
    final record = await backedUp(store, isVideo: true);

    final went = await removalOver(
      store,
      refuse: ['lib-1'],
      verifier: await verifierOver(store),
    ).removeFromDevice(record);

    expect(went, RemovalOutcome.failed);
    expect((await store.getByLocalId('photo:1'))!.localDeleted, isFalse);
  });

  test('no thumbnail means nothing is removed', () async {
    final store = FakeAssetRecordStore();
    final record = await backedUp(store, isVideo: true);

    final went = await removalOver(
      store,
      libraryThumbnail: (_) async => null,
      verifier: await verifierOver(store),
    ).removeFromDevice(record);

    expect(went, RemovalOutcome.failed);
    expect(deleted, isEmpty);
    expect((await store.getByLocalId('photo:1'))!.localDeleted, isFalse);
  });

  test('a bucket that hasn\'t got it keeps the local copy', () async {
    final store = FakeAssetRecordStore();
    final record = await backedUp(store, isVideo: true);

    final went = await removalOver(
      store,
      verifier: await verifierOver(store, answer: 404),
    ).removeFromDevice(record);

    expect(went, RemovalOutcome.backupMissing);
    expect(deleted, isEmpty);
    expect((await store.getByLocalId('photo:1'))!.localDeleted, isFalse);
    // And the row that claimed to be backed up doesn't get to keep saying so.
    final saved = (await store.getByLocalId('photo:1'))!;
    expect(saved.stateOf(DerivativeKind.original).status, UploadStatus.pending);
  });

  test('a bucket nobody can reach is not permission to delete', () async {
    final store = FakeAssetRecordStore();
    final record = await backedUp(store, isVideo: true);

    final went = await removalOver(
      store,
      verifier: await verifierOver(store, configured: false),
    ).removeFromDevice(record);

    expect(went, RemovalOutcome.backupUnverifiable);
    expect(deleted, isEmpty);
    expect((await store.getByLocalId('photo:1'))!.localDeleted, isFalse);
    // Nothing was learned, so nothing is re-queued either.
    final saved = (await store.getByLocalId('photo:1'))!;
    expect(
      saved.stateOf(DerivativeKind.original).status,
      UploadStatus.uploaded,
    );
  });

  test('a photo with nothing behind it is forgotten, not binned', () async {
    final store = FakeAssetRecordStore();
    final record = await store.upsert(
      localId: 'photo:2',
      contentHash: '2',
      platform: 'ios',
      libraryId: 'lib-2',
    );

    expect(await removalOver(store).deleteEverywhere(record), isTrue);

    expect(deleted, [
      ['lib-2'],
    ]);
    expect(await store.getByLocalId('photo:2'), isNull);
  });

  test('opening the bin drops what is gone everywhere', () async {
    final store = FakeAssetRecordStore();
    await store.upsert(
      localId: 'photo:2',
      contentHash: '2',
      platform: 'ios',
      libraryId: 'lib-2',
    );
    await store.softDelete('photo:2');
    final binned = [(await store.getByLocalId('photo:2'))!];

    expect(await removalOver(store).purgeVanished(binned), isEmpty);
    expect(await store.getByLocalId('photo:2'), isNull);
  });

  test('a bin entry the library still holds is left alone', () async {
    final store = FakeAssetRecordStore();
    await store.upsert(
      localId: 'photo:2',
      contentHash: '2',
      platform: 'ios',
      libraryId: 'lib-2',
    );
    await store.softDelete('photo:2');
    final binned = [(await store.getByLocalId('photo:2'))!];

    final kept = await removalOver(
      store,
      loadEntity: (_) async =>
          AssetEntity(id: 'lib-2', typeInt: 1, width: 1, height: 1),
    ).purgeVanished(binned);

    expect(kept, hasLength(1));
    expect(await store.getByLocalId('photo:2'), isNotNull);
  });

  test('deleting everywhere bins it here and takes it out of Photos', () async {
    final store = FakeAssetRecordStore();
    final record = await backedUp(store);

    expect(await removalOver(store).deleteEverywhere(record), isTrue);

    expect(deleted, [
      ['lib-1'],
    ]);
    expect((await store.getByLocalId('photo:1'))!.isDeleted, isTrue);
  });

  test('a declined delete leaves it in both places', () async {
    final store = FakeAssetRecordStore();
    final record = await backedUp(store);

    final binned = await removalOver(
      store,
      refuse: ['lib-1'],
    ).deleteEverywhere(record);

    expect(binned, isFalse);
    expect((await store.getByLocalId('photo:1'))!.isDeleted, isFalse);
  });
}
