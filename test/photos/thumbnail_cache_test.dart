import 'dart:io';
import 'dart:typed_data';

import 'package:bring_your_own_photos/photos/thumbnail_cache.dart';
import 'package:bring_your_own_photos/storage/asset_record.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_asset_record_store.dart';

void main() {
  late Directory tempDir;

  setUp(() => tempDir = Directory.systemTemp.createTempSync('byop_thumbs_'));
  tearDown(() => tempDir.delete(recursive: true));

  ThumbnailCache cacheOver(
    FakeAssetRecordStore store, {
    Future<Uint8List?> Function(File file)? encode,
  }) => ThumbnailCache(
    store: store,
    directory: () async => tempDir,
    encode: encode ?? (_) async => Uint8List.fromList([1, 2, 3]),
  );

  Future<AssetRecord> newRecord(FakeAssetRecordStore store) => store.upsert(
    localId: 'manual:abc',
    contentHash: 'abc',
    platform: 'ios',
    sourceType: AssetSourceType.manualFile,
    sourcePath: '/tmp/original.jpg',
  );

  test('writes a thumbnail file and records its path on the asset', () async {
    final store = FakeAssetRecordStore();
    final record = await newRecord(store);

    final path = await cacheOver(store).ensureFor(record, '/tmp/original.jpg');

    expect(path, isNotNull);
    expect(File(path!).readAsBytesSync(), [1, 2, 3]);
    expect((await store.getByLocalId('manual:abc'))!.thumbnailPath, path);
  });

  test('reuses an already-cached thumbnail instead of re-encoding', () async {
    final store = FakeAssetRecordStore();
    final record = await newRecord(store);
    final first = await cacheOver(store).ensureFor(record, '/tmp/original.jpg');
    final reloaded = (await store.getByLocalId('manual:abc'))!;
    var encodes = 0;

    final second = await cacheOver(
      store,
      encode: (_) async {
        encodes++;
        return Uint8List.fromList([9]);
      },
    ).ensureFor(reloaded, '/tmp/original.jpg');

    expect(second, first);
    expect(encodes, 0);
  });

  test('returns null when the source has no still image to encode', () async {
    final store = FakeAssetRecordStore();
    final record = await newRecord(store);

    final path = await cacheOver(
      store,
      encode: (_) async => null,
    ).ensureFor(record, '/tmp/video.mp4');

    expect(path, isNull);
    expect((await store.getByLocalId('manual:abc'))!.thumbnailPath, isNull);
  });

  test('remove deletes the cached file', () async {
    final store = FakeAssetRecordStore();
    final record = await newRecord(store);
    final cache = cacheOver(store);
    final path = await cache.ensureFor(record, '/tmp/original.jpg');

    await cache.remove((await store.getByLocalId('manual:abc'))!);

    expect(File(path!).existsSync(), isFalse);
  });
}
