import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:photo_manager/photo_manager.dart';
import 'package:image/image.dart' as img;
import 'package:photos_vault/photos/file_hash.dart';
import 'package:photos_vault/photos/photo_library_service.dart';
import 'package:photos_vault/photos/record_fixer.dart';
import 'package:photos_vault/photos/storage_advice.dart';
import 'package:photos_vault/photos/storage_optimizer.dart';
import 'package:photos_vault/upload/pending_deletes.dart';
import 'package:photos_vault/photos/thumbnail_cache.dart';
import 'package:photos_vault/settings/backup_targets_store.dart';
import 'package:photos_vault/storage/asset_record.dart';
import 'package:photos_vault/storage/bucket_object.dart';
import 'package:photos_vault/upload/bucket_flagged.dart' show FixOutcome;
import 'package:photos_vault/upload/backup_verifier.dart';

import '../settings/fake_secure_store.dart';
import '../support/fake_asset_record_store.dart';

void main() {
  late Directory tempDir;

  setUp(() => tempDir = Directory.systemTemp.createTempSync('pv_storage_'));
  tearDown(() => tempDir.delete(recursive: true));

  var deleted = <List<String>>[];

  PhotoLibraryService libraryThatDeletes(List<String> refuse) =>
      PhotoLibraryService(
        store: FakeAssetRecordStore(),
        deleteAssets: (ids) async {
          deleted.add(ids);
          return ids.where((id) => !refuse.contains(id)).toList();
        },
      );

  /// Photos holding [present], deleting what it is asked to (but [refuse]),
  /// with full access.
  PhotoLibraryService photosWith(
    Set<String> present, {
    List<String> refuse = const [],
  }) => PhotoLibraryService(
    store: FakeAssetRecordStore(),
    requestPermission: () async => PermissionState.authorized,
    loadEntity: (id) async => present.contains(id)
        ? AssetEntity(id: id, typeInt: 1, width: 1, height: 1)
        : null,
    deleteAssets: (ids) async {
      deleted.add(ids);
      final gone = [
        for (final id in ids)
          if (present.contains(id) && !refuse.contains(id)) id,
      ];
      present.removeAll(gone);
      return gone;
    },
  );

  /// A bucket answering [answer] to every HEAD; none at all unless
  /// [configured].
  Future<BackupVerifier> bucketSaying(
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
      head: (url) async => http.Response('', answer),
    );
  }

  StorageOptimizer optimizerOver(
    FakeAssetRecordStore store, {
    PhotoLibraryService? library,
    Future<void> Function(List<AssetRecord>)? backUp,
    Future<(Uint8List, int, int)?> Function(String, int?)? encode,
  }) => StorageOptimizer(
    store: store,
    thumbnails: ThumbnailCache(
      store: store,
      directory: () async => tempDir,
      encode: (_) async => Uint8List.fromList([9, 9, 9]),
    ),
    library: library ?? libraryThatDeletes(const []),
    backUp: backUp ?? (_) async {},
    encode:
        encode ??
        (path, maxEdge) async =>
            (Uint8List(File(path).lengthSync() ~/ 4), 2560, 1707),
  );

  Future<AssetRecord> ownedPhoto(
    FakeAssetRecordStore store, {
    required String path,
    int width = 6000,
    int height = 4000,
  }) async {
    await store.upsert(
      localId: 'manual:a',
      contentHash: 'a',
      platform: 'ios',
      sourceType: AssetSourceType.manualFile,
      sourcePath: path,
      width: width,
      height: height,
    );
    await store.updateDerivative(
      'manual:a',
      DerivativeKind.original,
      const DerivativeState(
        status: UploadStatus.uploaded,
        destinationKey: 'originals/a.png',
        backedUpHash: 'hash-of-the-original',
      ),
    );
    return (await store.getByLocalId('manual:a'))!;
  }

  StorageItem itemFor(AssetRecord record, int bytes, StorageFix fix) =>
      StorageItem(
        record: record,
        bytes: bytes,
        name: record.sourcePath ?? record.localId,
        appOwned: record.sourcePath != null,
        issues: const {},
        fixes: [fix],
      );

  setUp(() => deleted = <List<String>>[]);

  group('rewriting a local copy', () {
    test(
      'replaces the file, repoints the record and records the new size',
      () async {
        final store = FakeAssetRecordStore();
        final original = File('${tempDir.path}/a.png')
          ..writeAsBytesSync(Uint8List(4000));
        final record = await ownedPhoto(store, path: original.path);

        final result = await optimizerOver(store)
            .apply([itemFor(record, 4000, StorageFix.optimize)]);

        expect(result.freedBytes, 3000);
        expect(original.existsSync(), isFalse);
        final saved = (await store.getByLocalId('manual:a'))!;
        expect(saved.sourcePath, endsWith('.webp'));
        expect(File(saved.sourcePath!).lengthSync(), 1000);
        expect(saved.width, 2560);
        expect(saved.height, 1707);
      },
    );

    test(
      'leaves the change check to send the smaller copy to the bucket',
      () async {
        final store = FakeAssetRecordStore();
        final original = File('${tempDir.path}/a.png')
          ..writeAsBytesSync(Uint8List(4000));
        final record = await ownedPhoto(store, path: original.path);

        await optimizerOver(store)
            .apply([itemFor(record, 4000, StorageFix.optimize)]);

        final state = (await store.getByLocalId('manual:a'))!
            .stateOf(DerivativeKind.original);
        expect(state.status, UploadStatus.uploaded);
        expect(state.destinationKey, 'originals/a.png');
        // The backed-up hash is the old file's, so the next change check
        // sees a different file and uploads the smaller one.
        final saved = (await store.getByLocalId('manual:a'))!;
        expect(state.backedUpHash, isNot(await hashFile(saved.sourcePath!)));
        expect(saved.localOptimized, isTrue);
      },
    );

    test('a JPEG re-encode is named .jpg', () async {
      final store = FakeAssetRecordStore();
      final original = File('${tempDir.path}/a.png')
        ..writeAsBytesSync(Uint8List(4000));
      final record = await ownedPhoto(store, path: original.path);

      await optimizerOver(
        store,
        encode: (_, _) async =>
            (Uint8List.fromList([0xFF, 0xD8, 0xFF, 0, 1]), 2560, 1707),
      ).apply([itemFor(record, 4000, StorageFix.optimize)]);

      final saved = (await store.getByLocalId('manual:a'))!;
      expect(saved.sourcePath, endsWith('.jpg'));
      expect(original.existsSync(), isFalse);
    });

    test('one that grew is remembered as not smaller, so it isn\'t offered '
        'again', () async {
      final store = FakeAssetRecordStore();
      final original = File('${tempDir.path}/a.png')
        ..writeAsBytesSync(Uint8List(100));
      final record = await ownedPhoto(store, path: original.path);
      final optimizer = optimizerOver(
        store,
        encode: (_, _) async => (Uint8List(500), 2560, 1707),
      );

      await optimizer.apply([itemFor(record, 100, StorageFix.optimize)]);

      expect(optimizer.notSmaller, contains('manual:a'));
    });

    test('an app-held Live Photo is never re-encoded (04#11)', () async {
      final store = FakeAssetRecordStore();
      final original = File('${tempDir.path}/live.jpg')
        ..writeAsBytesSync(Uint8List(4000));
      final motion = File('${original.path}.live.mov')..writeAsBytesSync([1]);
      await store.upsert(
        localId: 'manual:live',
        contentHash: 'live',
        platform: 'ios',
        sourceType: AssetSourceType.manualFile,
        sourcePath: original.path,
        isLivePhoto: true,
        width: 6000,
        height: 4000,
      );
      final record = (await store.getByLocalId('manual:live'))!;

      final result = await optimizerOver(store)
          .apply([itemFor(record, 4000, StorageFix.optimize)]);

      expect(result.skipped, 1);
      expect(original.lengthSync(), 4000);
      expect(motion.existsSync(), isTrue);
      expect(
        (await store.getByLocalId('manual:live'))!.sourcePath,
        original.path,
      );
    });

    test('a re-encode that grew the file changes nothing', () async {
      final store = FakeAssetRecordStore();
      final original = File('${tempDir.path}/a.png')
        ..writeAsBytesSync(Uint8List(100));
      final record = await ownedPhoto(store, path: original.path);

      final result = await optimizerOver(
        store,
        encode: (_, _) async => (Uint8List(500), 2560, 1707),
      ).apply([itemFor(record, 100, StorageFix.optimize)]);

      expect(result.freedBytes, 0);
      expect(result.skipped, 1);
      expect(original.existsSync(), isTrue);
      expect((await store.getByLocalId('manual:a'))!.sourcePath, original.path);
    });

    test('an undecodable file is left alone rather than lost', () async {
      final store = FakeAssetRecordStore();
      final original = File('${tempDir.path}/a.png')
        ..writeAsBytesSync(Uint8List(4000));
      final record = await ownedPhoto(store, path: original.path);

      final result = await optimizerOver(
        store,
        encode: (_, _) async => null,
      ).apply([itemFor(record, 4000, StorageFix.optimize)]);

      expect(result.skipped, 1);
      expect(original.existsSync(), isTrue);
    });
  });

  group('removing local copies', () {
    test('takes the whole camera-roll batch out in one library call', () async {
      final store = FakeAssetRecordStore();
      final items = <StorageItem>[];
      for (var i = 0; i < 3; i++) {
        await store.upsert(
          localId: 'photo:$i',
          contentHash: '$i',
          platform: 'ios',
          libraryId: 'lib-$i',
        );
        await store.setThumbnailPath(
          'photo:$i',
          (File('${tempDir.path}/t$i.jpg')..writeAsBytesSync([1])).path,
        );
        items.add(
          itemFor(
            (await store.getByLocalId('photo:$i'))!,
            1000,
            StorageFix.removeFromDevice,
          ),
        );
      }

      final result = await optimizerOver(store).apply(items);

      // One iOS confirmation, not three.
      expect(deleted, [
        ['lib-0', 'lib-1', 'lib-2'],
      ]);
      expect(result.freedBytes, 3000);
      for (var i = 0; i < 3; i++) {
        expect((await store.getByLocalId('photo:$i'))!.localDeleted, isTrue);
      }
    });

    test('a declined removal leaves that photo exactly as it was', () async {
      final store = FakeAssetRecordStore();
      await store.upsert(
        localId: 'photo:0',
        contentHash: '0',
        platform: 'ios',
        libraryId: 'lib-0',
      );
      await store.setThumbnailPath(
        'photo:0',
        (File('${tempDir.path}/t.jpg')..writeAsBytesSync([1])).path,
      );
      final record = (await store.getByLocalId('photo:0'))!;

      final result = await optimizerOver(
        store,
        library: libraryThatDeletes(['lib-0']),
      ).apply([itemFor(record, 1000, StorageFix.removeFromDevice)]);

      expect(result.freedBytes, 0);
      expect(result.skipped, 1);
      expect((await store.getByLocalId('photo:0'))!.localDeleted, isFalse);
    });

    test(
      'an app-owned file is deleted directly, not through the library',
      () async {
        final store = FakeAssetRecordStore();
        final file = File('${tempDir.path}/a.jpg')
          ..writeAsBytesSync(Uint8List(2048));
        final record = await ownedPhoto(store, path: file.path);

        final result = await optimizerOver(store)
            .apply([itemFor(record, 2048, StorageFix.removeFromDevice)]);

        expect(deleted, isEmpty);
        expect(file.existsSync(), isFalse);
        expect(result.freedBytes, 2048);
        expect((await store.getByLocalId('manual:a'))!.localDeleted, isTrue);
      },
    );

    test('nothing is removed without a thumbnail left to draw', () async {
      final store = FakeAssetRecordStore();
      await store.upsert(
        localId: 'photo:0',
        contentHash: '0',
        platform: 'ios',
        libraryId: 'lib-0',
      );
      final record = (await store.getByLocalId('photo:0'))!;

      final result = await StorageOptimizer(
        store: store,
        thumbnails: ThumbnailCache(
          store: store,
          directory: () async => tempDir,
          encode: (_) async => null,
        ),
        library: libraryThatDeletes(const []),
        backUp: (_) async {},
      ).apply([itemFor(record, 1000, StorageFix.removeFromDevice)]);

      expect(deleted, isEmpty);
      expect(result.skipped, 1);
      expect((await store.getByLocalId('photo:0'))!.localDeleted, isFalse);
    });
  });

  test('backups go out through the caller\'s own queue, in one call', () async {
    final store = FakeAssetRecordStore();
    final queued = <List<AssetRecord>>[];
    final records = <AssetRecord>[];
    for (var i = 0; i < 2; i++) {
      records.add(
        await store.upsert(
          localId: 'photo:$i',
          contentHash: '$i',
          platform: 'ios',
        ),
      );
    }

    final result = await optimizerOver(
      store,
      backUp: (r) async => queued.add(r),
    ).apply([for (final r in records) itemFor(r, 100, StorageFix.backUpFirst)]);

    expect(queued.single.map((r) => r.localId), ['photo:0', 'photo:1']);
    expect(result.queuedForBackup, 2);
    expect(result.freedBytes, 0);
  });

  group('shrinking a camera-roll photo', () {
    Future<AssetRecord> cameraRoll(FakeAssetRecordStore store) async {
      await store.upsert(
        localId: 'cam',
        contentHash: 'cam',
        platform: 'ios',
        libraryId: 'old-asset',
        width: 8064,
        height: 6048,
      );
      await store.updateDerivative(
        'cam',
        DerivativeKind.original,
        const DerivativeState(
          status: UploadStatus.uploaded,
          destinationKey: 'originals/cam.heic',
          backedUpHash: 'original-hash',
        ),
      );
      return (await store.getByLocalId('cam'))!;
    }

    test('a run asks to delete its originals once, at the end, and a quit '
        'in between still asks next time', () async {
      final store = FakeAssetRecordStore();
      final record = await cameraRoll(store);
      deleted = [];
      final photos = {'old-asset', 'new-asset'};
      final bucket = await bucketSaying(store);
      // The run's own check is a listing (not faked here); the prompt's is
      // a HEAD per photo.
      StorageOptimizer optimizer({BackupVerifier? verifier}) =>
          StorageOptimizer(
            store: store,
            thumbnails: ThumbnailCache(
              store: store,
              directory: () async => tempDir,
              encode: (_) async => Uint8List.fromList([1]),
            ),
            library: photosWith(photos),
            backUp: (_) async {},
            verifier: verifier,
            writer: _FakeWriter(tempDir),
          );

      await optimizer().apply([
        StorageItem(
          record: record,
          bytes: 6000,
          name: 'IMG_1.HEIC',
          appOwned: false,
          issues: const {StorageIssue.highResolution},
          fixes: const [StorageFix.optimize],
        ),
      ], deferDeletes: true);

      expect(deleted, isEmpty, reason: 'no prompt mid-run');
      expect((await store.getByLocalId('cam'))!.libraryId, 'old-asset');

      // A new launch: a fresh optimizer finds the filed original and asks.
      final relaunched = optimizer(verifier: bucket);
      expect(await relaunched.pendingSwaps(), hasLength(1));
      final result = await relaunched.finishSwaps();

      expect(deleted, [
        ['old-asset'],
      ]);
      expect(result.freedBytes, 6000 - 100);
      expect((await store.getByLocalId('cam'))!.libraryId, 'new-asset');
      expect(await relaunched.pendingSwaps(), isEmpty);
    });

    test('a copy barely smaller is not saved, and is remembered as the '
        'smallest it gets', () async {
      final store = FakeAssetRecordStore();
      final record = await cameraRoll(store);
      final writer = _BarelySmallerWriter(tempDir);
      final optimizer = StorageOptimizer(
        store: store,
        thumbnails: ThumbnailCache(
          store: store,
          directory: () async => tempDir,
          encode: (_) async => Uint8List.fromList([1]),
        ),
        library: libraryThatDeletes(const []),
        backUp: (_) async {},
        writer: writer,
      );
      final outcomes = <StorageItemOutcome>[];

      await optimizer.apply(
        [
          StorageItem(
            record: record,
            bytes: 6000,
            name: 'IMG_1.MOV',
            appOwned: false,
            issues: const {StorageIssue.largeFile},
            fixes: const [StorageFix.optimize],
          ),
        ],
        deferDeletes: true,
        onItem: (_, outcome) => outcomes.add(outcome),
      );

      expect(writer.savedTitles, isEmpty);
      expect(outcomes, [StorageItemOutcome.skipped]);
      expect(optimizer.notSmaller, {'cam'});
    });

    test('a copy already in Photos: the original goes, its record takes the '
        'copy over, and the record sync made of the copy is merged in and '
        'dropped', () async {
      final store = FakeAssetRecordStore();
      final original = await cameraRoll(store);
      await store.upsert(
        localId: 'copy',
        contentHash: 'copy',
        platform: 'ios',
        libraryId: 'copy-asset',
        width: 2560,
        height: 1920,
      );
      await store.setTags('copy', ['beach']);
      await store.recordUpload(
        localId: 'copy',
        kind: DerivativeKind.original,
        targetId: 't',
        destinationKey: 'originals/copy.heic',
      );
      final writer = _FakeWriter(tempDir);
      final bucket = await bucketSaying(store);
      StorageOptimizer optimizer(List<String> refuse) => StorageOptimizer(
        store: store,
        thumbnails: ThumbnailCache(
          store: store,
          directory: () async => tempDir,
          encode: (_) async => Uint8List.fromList([1]),
        ),
        library: photosWith({'old-asset', 'copy-asset'}, refuse: refuse),
        backUp: (_) async {},
        verifier: bucket,
        writer: writer,
      );
      final copy = (await store.getByLocalId('copy'))!;

      await optimizer(['old-asset']).fileFoundCopies(original, copy: copy);
      await optimizer(['old-asset']).finishSwaps();
      expect(writer.deletedIds, isEmpty, reason: 'declined keeps the copy');
      expect(await store.getByLocalId('copy'), isNotNull);

      await optimizer(const []).fileFoundCopies(original, copy: copy);
      await optimizer(const []).finishSwaps();
      final moved = (await store.getByLocalId('cam'))!;
      expect(moved.libraryId, 'copy-asset');
      expect(moved.localOptimized, isTrue);
      expect(moved.tags, ['beach'], reason: 'the copy record\'s tags stay');
      expect(await store.getByLocalId('copy'), isNull);
      expect(await store.mergedInto(), {'copy': 'cam'});
      expect(
        (await PendingDeletes(store: store).pending()).map((d) => d.objectKey),
        ['originals/copy.heic'],
      );
    });

    test(
      'one swap per photo: Optimize after Finish Optimize makes no '
      'second copy, and a copy made for a photo filed meanwhile goes at once',
      () async {
        final store = FakeAssetRecordStore();
        final original = await cameraRoll(store);
        await store.upsert(
          localId: 'copy',
          contentHash: 'copy',
          platform: 'ios',
          libraryId: 'copy-asset',
          width: 2560,
          height: 1920,
        );
        final writer = _FakeWriter(tempDir);
        final optimizer = StorageOptimizer(
          store: store,
          thumbnails: ThumbnailCache(
            store: store,
            directory: () async => tempDir,
            encode: (_) async => Uint8List.fromList([1]),
          ),
          library: photosWith({'old-asset', 'copy-asset'}),
          backUp: (_) async {},
          verifier: await bucketSaying(store),
          writer: writer,
        );
        final item = StorageItem(
          record: original,
          bytes: 6000,
          name: 'IMG_1.HEIC',
          appOwned: false,
          issues: const {StorageIssue.highResolution},
          fixes: const [StorageFix.optimize],
        );
        final copy = (await store.getByLocalId('copy'))!;

        await optimizer.fileFoundCopies(original, copy: copy);
        final prepared = <String>[];
        await StorageOptimizer(
          store: store,
          thumbnails: ThumbnailCache(
            store: store,
            directory: () async => tempDir,
          ),
          library: photosWith({'old-asset', 'copy-asset'}),
          backUp: (_) async {},
          writer: writer,
        ).apply([item], deferDeletes: true, onPrepared: prepared.add);

        expect(writer.savedTitles, isEmpty);
        expect(prepared, ['cam']);
        expect(await optimizer.pendingSwaps(), hasLength(1));
        await optimizer.finishSwaps();
        expect((await store.getByLocalId('cam'))!.libraryId, 'copy-asset');

        // Filed by another run between this one's check and its copy: the
        // copy it made is taken back out, never left in Photos unclaimed.
        final racing = _RacingWriter(tempDir, store);
        await StorageOptimizer(
          store: store,
          thumbnails: ThumbnailCache(
            store: store,
            directory: () async => tempDir,
          ),
          library: photosWith({'copy-asset'}),
          backUp: (_) async {},
          writer: racing,
        ).apply([
          item.withRecord((await store.getByLocalId('cam'))!),
        ], deferDeletes: true);
        expect(racing.deletedIds, ['new-asset']);
        expect((await store.pendingSwaps()).single.newAsset, 'raced-asset');
      },
    );

    test('puts the smaller copy in Photos and moves the record onto it, so '
        'the bucket keeps the original', () async {
      final store = FakeAssetRecordStore();
      final record = await cameraRoll(store);
      final writer = _FakeWriter(tempDir);
      final optimizer = StorageOptimizer(
        store: store,
        thumbnails: ThumbnailCache(
          store: store,
          directory: () async => tempDir,
          encode: (_) async => Uint8List.fromList([1]),
        ),
        library: libraryThatDeletes(const []),
        backUp: (_) async {},
        writer: writer,
      );

      final result = await optimizer.apply([
        StorageItem(
          record: record,
          bytes: 6000,
          name: 'IMG_1.HEIC',
          appOwned: false,
          issues: const {StorageIssue.highResolution},
          fixes: const [StorageFix.optimize],
        ),
      ]);

      final after = (await store.getByLocalId('cam'))!;
      expect(result.freedBytes, 6000 - 100);
      expect(after.libraryId, 'new-asset');
      expect(after.localOptimized, isTrue);
      expect(
        after.stateOf(DerivativeKind.original).destinationKey,
        'originals/cam.heic',
      );
      expect(writer.savedTitles, ['IMG_1.HEIC']);
      expect(writer.deletedIds, isEmpty);
    });

    test('declined at the prompt, the new copy is taken back out', () async {
      final store = FakeAssetRecordStore();
      final record = await cameraRoll(store);
      final writer = _FakeWriter(tempDir);
      final optimizer = StorageOptimizer(
        store: store,
        thumbnails: ThumbnailCache(
          store: store,
          directory: () async => tempDir,
          encode: (_) async => Uint8List.fromList([1]),
        ),
        library: libraryThatDeletes(const ['old-asset']),
        backUp: (_) async {},
        writer: writer,
      );

      final result = await optimizer.apply([
        StorageItem(
          record: record,
          bytes: 6000,
          name: 'IMG_1.HEIC',
          appOwned: false,
          issues: const {StorageIssue.highResolution},
          fixes: const [StorageFix.optimize],
        ),
      ]);

      expect(result.skipped, 1);
      expect((await store.getByLocalId('cam'))!.libraryId, 'old-asset');
      expect(writer.deletedIds, ['new-asset']);
    });
  });

  test('Finish Optimize: once the original is out of Photos, the pair is '
      'not offered again', () async {
    final store = FakeAssetRecordStore();
    final taken = DateTime(2026, 9, 8, 14, 42, 50);
    String picture(String name, int width) {
      final image = img.Image(width: width, height: width * 3 ~/ 4);
      for (final px in image) {
        px
          ..r = px.x * 255 ~/ width
          ..g = px.x * 255 ~/ width
          ..b = px.y * 255 ~/ (width * 3 ~/ 4);
      }
      return (File(
        '${tempDir.path}/$name.jpg',
      )..writeAsBytesSync(img.encodeJpg(image))).path;
    }

    Future<void> photo(
      String id,
      String asset, {
      required int width,
      required DateTime added,
    }) async {
      await store.upsert(
        localId: id,
        contentHash: id,
        platform: 'ios',
        libraryId: asset,
        width: width,
        height: width * 3 ~/ 4,
        createdAt: taken,
        addedAt: added,
      );
      await store.updateDerivative(
        id,
        DerivativeKind.original,
        DerivativeState(
          status: UploadStatus.uploaded,
          destinationKey: 'originals/$id.heic',
        ),
      );
      await store.setThumbnailPath(id, picture(id, 80));
    }

    await photo('cam', 'old-asset', width: 8064, added: taken);
    await photo(
      'copy',
      'copy-asset',
      width: 2560,
      added: taken.add(const Duration(days: 30)),
    );
    await store.replaceBucketObjects('t', [
      for (final id in ['cam', 'copy'])
        BucketObject(
          targetId: 't',
          key: 'originals/$id.heic',
          size: 100,
          lastModified: taken,
        ),
    ]);
    final optimizer = StorageOptimizer(
      store: store,
      thumbnails: ThumbnailCache(
        store: store,
        directory: () async => tempDir,
        encode: (_) async => Uint8List.fromList([1]),
      ),
      library: photosWith({'old-asset', 'copy-asset'}),
      backUp: (_) async {},
      verifier: await bucketSaying(store),
      writer: _FakeWriter(tempDir),
    );
    final records = RecordFixer(
      store: store,
      thumbnail: (_) async => null,
      inPhotos: (_) async => true,
      remove: (_) async => true,
      fileCopies: optimizer.fileFoundCopies,
    );

    final found = (await records.scan()).leftoverCopies;
    expect(found.map((f) => f.asset!.localId), ['cam']);
    final filed = await records.finishOptimize(found.single.asset!);
    expect(filed.outcome, FixOutcome.filed, reason: filed.detail);
    await optimizer.finishSwaps();

    expect((await store.getByLocalId('cam'))!.libraryId, 'copy-asset');
    expect((await records.scan()).leftoverCopies, isEmpty);
  });

  group('the swap journal', () {
    late FakeAssetRecordStore store;
    late Set<String> photos;
    late _FakeWriter writer;

    setUp(() {
      store = FakeAssetRecordStore();
      photos = {};
      writer = _FakeWriter(tempDir);
    });

    Iterable<String> everDeleted() => deleted.expand((ids) => ids);

    /// [id] backed up, on `<id>-old`, with its smaller copy `<id>-new` in
    /// Photos and the swap filed.
    Future<void> filed(String id) async {
      await store.upsert(
        localId: id,
        contentHash: id,
        platform: 'ios',
        libraryId: '$id-old',
      );
      await store.updateDerivative(
        id,
        DerivativeKind.original,
        DerivativeState(
          status: UploadStatus.uploaded,
          destinationKey: 'originals/$id.heic',
        ),
      );
      photos.addAll({'$id-old', '$id-new'});
      await store.fileSwap(
        PendingSwap(
          localId: id,
          oldAsset: '$id-old',
          newAsset: '$id-new',
          oldBytes: 1000,
          newBytes: 100,
        ),
      );
    }

    Future<StorageOptimizer> over({
      int answer = 200,
      bool configured = true,
    }) async => StorageOptimizer(
      store: store,
      thumbnails: ThumbnailCache(store: store, directory: () async => tempDir),
      library: photosWith(photos),
      backUp: (_) async {},
      verifier: await bucketSaying(
        store,
        answer: answer,
        configured: configured,
      ),
      writer: writer,
    );

    test('a kill after the delete, before the records move, resumes '
        'forward', () async {
      await filed('a');
      await filed('b');
      store.crashAt = 'adopt';
      await expectLater((await over()).finishSwaps(), throwsStateError);
      expect(photos, {'a-new', 'b-new'});
      expect((await store.getByLocalId('a'))!.libraryId, 'a-old');
      expect(await store.pendingSwaps(), hasLength(2));

      final result = await (await over()).finishSwaps();

      expect((await store.getByLocalId('a'))!.libraryId, 'a-new');
      expect((await store.getByLocalId('b'))!.libraryId, 'b-new');
      expect(await store.pendingSwaps(), isEmpty);
      expect(result.freedBytes, 2 * 900);
      expect(everDeleted().where((id) => id.endsWith('-new')), isEmpty);
      expect(photos, {'a-new', 'b-new'});
    });

    test('a kill after one record moved resumes with the rest, and a stale '
        'entry never deletes the copy it moved onto', () async {
      await filed('a');
      await filed('b');
      // Before the kill: a's original went and a moved; b's went too.
      photos.removeAll({'a-old', 'b-old'});
      await store.adoptAsset('a', 'a-new', closeSwap: true);
      // Filed again for a as it was (an old build's journal): a is on its
      // copy now, which must not be read as the asset to delete.
      await store.fileSwap(
        const PendingSwap(localId: 'a', oldAsset: 'a-old', newAsset: 'a-new'),
      );

      await (await over()).finishSwaps();

      expect((await store.getByLocalId('a'))!.libraryId, 'a-new');
      expect((await store.getByLocalId('b'))!.libraryId, 'b-new');
      expect(photos, {'a-new', 'b-new'});
      expect(everDeleted(), isNot(contains('a-new')));
      expect(writer.deletedIds, isEmpty, reason: 'a-new is a\'s photo now');
      expect(await store.pendingSwaps(), isEmpty);
    });

    test('filings made at once are all kept', () async {
      final optimizer = await over();
      final pairs = <(AssetRecord, AssetRecord)>[];
      for (final id in ['a', 'b', 'c', 'd']) {
        pairs.add((
          await store.upsert(
            localId: id,
            contentHash: id,
            platform: 'ios',
            libraryId: '$id-old',
          ),
          await store.upsert(
            localId: '$id-copy',
            contentHash: '$id-copy',
            platform: 'ios',
            libraryId: '$id-new',
          ),
        ));
      }
      await Future.wait([
        for (final (original, copy) in pairs)
          optimizer.fileFoundCopies(original, copy: copy, flag: 'f:$original'),
      ]);
      expect([
        for (final s in await store.pendingSwaps()) s.localId,
      ], unorderedEquals(['a', 'b', 'c', 'd']));
    });

    test('a bucket that does not answer leaves the original and the swap '
        'filed', () async {
      await filed('a');
      final outcomes = <StorageItemOutcome>[];
      await (await over(configured: false))
          .finishSwaps(onItem: (_, outcome) => outcomes.add(outcome));
      expect(everDeleted(), isEmpty);
      expect(outcomes, [StorageItemOutcome.unverified]);
      expect(await store.pendingSwaps(), hasLength(1));
      expect(writer.deletedIds, isEmpty);
    });

    test('a bucket without the original keeps it in Photos and takes the '
        'copy back out', () async {
      await filed('a');
      await (await over(answer: 404)).finishSwaps();
      expect(everDeleted(), isEmpty);
      expect((await store.getByLocalId('a'))!.libraryId, 'a-old');
      expect(await store.pendingSwaps(), isEmpty);
      expect(writer.deletedIds, ['a-new']);
    });

    test('a copy gone from Photos keeps the original', () async {
      await filed('a');
      photos.remove('a-new');
      await (await over()).finishSwaps();
      expect(everDeleted(), isEmpty);
      expect((await store.getByLocalId('a'))!.libraryId, 'a-old');
      expect(await store.pendingSwaps(), isEmpty);
    });

    test('a photo locked, hidden or binned since it was filed stays in '
        'Photos', () async {
      for (final id in ['a', 'b', 'c']) {
        await filed(id);
      }
      await store.setLocked('a', true);
      await store.setPasscodeHash('b', 'h');
      await store.softDelete('c');
      await (await over()).finishSwaps();
      expect(everDeleted(), isEmpty);
      for (final id in ['a', 'b', 'c']) {
        expect((await store.getByLocalId(id))!.libraryId, '$id-old');
      }
      expect(await store.pendingSwaps(), isEmpty);
    });

    test(
      'never the asset another swap moves onto, nor a kept copy\'s',
      () async {
        Future<void> on(String id, String asset) async {
          await store.upsert(
            localId: id,
            contentHash: id,
            platform: 'ios',
            libraryId: asset,
          );
          photos.add(asset);
        }

        await filed('a');
        await filed('k');
        await on('c', 'a-new');
        await on('d', 'd-asset');
        // c's asset is the one a moves onto; k is d's kept copy.
        await store.fileSwap(
          const PendingSwap(localId: 'c', oldAsset: 'a-new', keeperId: 'k'),
        );
        await store.fileSwap(
          const PendingSwap(localId: 'd', oldAsset: 'd-asset', keeperId: 'k'),
        );

        await (await over()).finishSwaps();

        expect(everDeleted(), unorderedEquals(['a-old', 'd-asset']));
        expect((await store.getByLocalId('k'))!.libraryId, 'k-old');
        expect((await store.getByLocalId('d'))!.isDeleted, isTrue);
        expect(photos, containsAll(['a-new', 'k-old']));
      },
    );
  });

  group('a smaller copy for the bucket', () {
    StorageOptimizer over(FakeAssetRecordStore store) => StorageOptimizer(
      store: store,
      thumbnails: ThumbnailCache(store: store, directory: () async => tempDir),
      library: libraryThatDeletes(const []),
      backUp: (_) async {},
      writer: _FakeWriter(tempDir),
    );

    Future<AssetRecord> owned(
      FakeAssetRecordStore store, {
      required bool optimized,
      bool present = true,
    }) async {
      final file = File('${tempDir.path}/mine.heic');
      if (present) file.writeAsBytesSync(List.filled(3000, 7));
      await store.upsert(
        localId: 'manual:m',
        contentHash: 'm',
        platform: 'ios',
        sourceType: AssetSourceType.manualFile,
        sourcePath: file.path,
      );
      await store.setLocalOptimized('manual:m', optimized);
      return (await store.getByLocalId('manual:m'))!;
    }

    test('an optimized phone copy goes up as it is', () async {
      final store = FakeAssetRecordStore();
      final record = await owned(store, optimized: true);

      final out = (await over(store).smallerFile(record))!;

      expect(out.readAsBytesSync(), List.filled(3000, 7));
      expect(File(record.sourcePath!).existsSync(), isTrue);
      out.deleteSync();
    });

    test('a full phone copy is shrunk, and left where it is', () async {
      final store = FakeAssetRecordStore();
      final record = await owned(store, optimized: false);

      final out = (await over(store).smallerFile(record))!;

      expect(out.lengthSync(), 100);
      expect(File(record.sourcePath!).lengthSync(), 3000);
      out.deleteSync();
    });

    test("with no copy here, the bucket's is downloaded and shrunk", () async {
      final store = FakeAssetRecordStore();
      final record = await owned(store, optimized: false, present: false);
      String? asked;

      final out = (await over(store).smallerFile(
        record,
        fromBucket: (path) async {
          asked = path;
          return File(path)..writeAsBytesSync(List.filled(5000, 1));
        },
      ))!;

      expect(asked, isNotNull);
      expect(out.lengthSync(), 100);
      expect(File(asked!).existsSync(), isFalse, reason: 'download cleaned up');
      out.deleteSync();
    });
  });

  group('removing a duplicate', () {
    Future<StorageItem> pair(FakeAssetRecordStore store) async {
      for (final id in ['kept', 'dup']) {
        await store.upsert(
          localId: id,
          contentHash: id,
          platform: 'ios',
          libraryId: '$id-asset',
        );
        await store.updateDerivative(
          id,
          DerivativeKind.original,
          const DerivativeState(
            status: UploadStatus.uploaded,
            backedUpHash: 'same',
          ),
        );
      }
      return StorageItem(
        record: (await store.getByLocalId('dup'))!,
        bytes: 100,
        name: 'dup',
        appOwned: false,
        issues: const {StorageIssue.duplicate},
        fixes: const [StorageFix.removeDuplicate],
        duplicateOf: 'kept',
        keptId: 'kept',
      );
    }

    PhotoLibraryService libraryWith(Set<String> present) => PhotoLibraryService(
      store: FakeAssetRecordStore(),
      loadEntity: (id) async => present.contains(id)
          ? AssetEntity(id: id, typeInt: 1, width: 1, height: 1)
          : null,
      deleteAssets: (ids) async {
        deleted.add(ids);
        return ids;
      },
    );

    test('a kept copy Photos no longer has stops it', () async {
      final store = FakeAssetRecordStore();
      final item = await pair(store);
      final outcomes = <StorageItemOutcome>[];

      final result = await optimizerOver(
        store,
        library: libraryWith({'dup-asset'}),
      ).apply([item], onItem: (_, outcome) => outcomes.add(outcome));

      expect(deleted, isEmpty);
      expect((await store.getByLocalId('dup'))!.isDeleted, isFalse);
      expect(outcomes, [StorageItemOutcome.unverified]);
      expect(result.unverified, 1);
    });

    test('so does a kept copy whose row is gone', () async {
      final store = FakeAssetRecordStore();
      final item = await pair(store);
      await store.remove('kept');

      await optimizerOver(
        store,
        library: libraryWith({'dup-asset', 'kept-asset'}),
      ).apply([item]);

      expect(deleted, isEmpty);
      expect((await store.getByLocalId('dup'))!.isDeleted, isFalse);
    });

    test('a kept copy still in Photos lets it go', () async {
      final store = FakeAssetRecordStore();
      final item = await pair(store);

      await optimizerOver(
        store,
        library: libraryWith({'dup-asset', 'kept-asset'}),
      ).apply([item]);

      expect(deleted, [
        ['dup-asset'],
      ]);
      expect((await store.getByLocalId('dup'))!.isDeleted, isTrue);
    });
  });
}

class _FakeWriter extends LibraryWriter {
  _FakeWriter(this.dir);

  final Directory dir;
  final savedTitles = <String>[];
  final deletedIds = <String>[];

  @override
  Future<File?> original(
    PhotoLibraryService library,
    AssetRecord record,
  ) async =>
      File('${dir.path}/original.heic')..writeAsBytesSync(List.filled(6000, 1));

  @override
  Future<bool> encodeStill(String input, String output, int maxEdge) async {
    File(output).writeAsBytesSync(List.filled(100, 2));
    return true;
  }

  @override
  Future<AssetEntity?> save({
    required File file,
    File? motion,
    required bool isVideo,
    required String title,
    required DateTime createdAt,
  }) async {
    savedTitles.add(title);
    return AssetEntity(id: 'new-asset', typeInt: 1, width: 2560, height: 1920);
  }

  @override
  Future<void> delete(List<String> ids) async => deletedIds.addAll(ids);
}

class _BarelySmallerWriter extends _FakeWriter {
  _BarelySmallerWriter(super.dir);

  @override
  Future<bool> encodeStill(String input, String output, int maxEdge) async {
    File(output).writeAsBytesSync(List.filled(5800, 2));
    return true;
  }
}

/// Another run files the same photo while this one saves its copy.
class _RacingWriter extends _FakeWriter {
  _RacingWriter(super.dir, this.store);

  final FakeAssetRecordStore store;

  @override
  Future<AssetEntity?> save({
    required File file,
    File? motion,
    required bool isVideo,
    required String title,
    required DateTime createdAt,
  }) async {
    await store.fileSwap(
      const PendingSwap(
        localId: 'cam',
        oldAsset: 'copy-asset',
        newAsset: 'raced-asset',
      ),
    );
    return super.save(
      file: file,
      motion: motion,
      isVideo: isVideo,
      title: title,
      createdAt: createdAt,
    );
  }
}
