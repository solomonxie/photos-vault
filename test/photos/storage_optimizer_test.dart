import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
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
        fix: fix,
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
            .apply([itemFor(record, 4000, StorageFix.reduceResolution)]);

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
      'leaves the bucket copy alone and stops the change check re-uploading it',
      () async {
        final store = FakeAssetRecordStore();
        final original = File('${tempDir.path}/a.png')
          ..writeAsBytesSync(Uint8List(4000));
        final record = await ownedPhoto(store, path: original.path);

        await optimizerOver(store)
            .apply([itemFor(record, 4000, StorageFix.reduceResolution)]);

        final state = (await store.getByLocalId('manual:a'))!
            .stateOf(DerivativeKind.original);
        expect(state.status, UploadStatus.uploaded);
        expect(state.destinationKey, 'originals/a.png');
        // The full-quality original stays in the bucket only if the next
        // change check sees the new local file as already accounted for.
        final saved = (await store.getByLocalId('manual:a'))!;
        expect(state.backedUpHash, await hashFile(saved.sourcePath!));
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
      ).apply([itemFor(record, 100, StorageFix.convertFormat)]);

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
      ).apply([itemFor(record, 4000, StorageFix.convertFormat)]);

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
}
