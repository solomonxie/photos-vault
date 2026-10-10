import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photos_vault/photos/file_hash.dart';
import 'package:photos_vault/photos/photo_library_service.dart';
import 'package:photos_vault/photos/storage_advice.dart';
import 'package:photos_vault/photos/storage_optimizer.dart';
import 'package:photos_vault/photos/thumbnail_cache.dart';
import 'package:photos_vault/storage/asset_record.dart';

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

  StorageOptimizer optimizerOver(
    FakeAssetRecordStore store, {
    PhotoLibraryService? library,
    Future<void> Function(List<AssetRecord>)? backUp,
    Future<(Uint8List, int, int)?> Function(Uint8List, int?)? encode,
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
        (bytes, maxEdge) async => (Uint8List(bytes.length ~/ 4), 2560, 1707),
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
      StorageOptimizer optimizer() => StorageOptimizer(
        store: store,
        thumbnails: ThumbnailCache(
          store: store,
          directory: () async => tempDir,
          encode: (_) async => Uint8List.fromList([1]),
        ),
        library: libraryThatDeletes(const []),
        backUp: (_) async {},
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
      final relaunched = optimizer();
      expect(await relaunched.pendingSwaps(), hasLength(1));
      final result = await relaunched.finishSwaps();

      expect(deleted, [
        ['old-asset'],
      ]);
      expect(result.freedBytes, 6000 - 100);
      expect((await store.getByLocalId('cam'))!.libraryId, 'new-asset');
      expect(await relaunched.pendingSwaps(), isEmpty);
    });

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
