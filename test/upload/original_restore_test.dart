import 'dart:io';

import 'package:photos_vault/settings/backup_targets_store.dart';
import 'package:photos_vault/storage/asset_record.dart';
import 'package:photos_vault/upload/original_restore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import '../settings/fake_secure_store.dart';
import '../support/fake_asset_record_store.dart';

Future<BackupTargetsStore> _oneTarget() async {
  final targetsStore = BackupTargetsStore(store: FakeSecureStore());
  await targetsStore.add(
    accessKeyId: 'a',
    secretAccessKey: 'b',
    region: 'us-east-1',
    bucket: 'bucket',
    prefix: '',
  );
  return targetsStore;
}

void main() {
  test('a cloud-only photo with no thumbnail left fetches one', () async {
    final store = FakeAssetRecordStore();
    await store.upsert(
      localId: 'photo:bare',
      contentHash: 'b',
      platform: 'ios',
    );
    await store.updateDerivative(
      'photo:bare',
      DerivativeKind.thumbnail,
      const DerivativeState(
        status: UploadStatus.uploaded,
        destinationKey: 'thumbnails/photo_bare.jpg',
      ),
    );
    await store.setLocalDeleted('photo:bare', true);
    final record = (await store.getByLocalId('photo:bare'))!;

    final tempDir = Directory.systemTemp.createTempSync('pv_thumb_');
    addTearDown(() => tempDir.deleteSync(recursive: true));
    final fetched = <String>[];

    final path = await OriginalRestore(
      targetsStore: await _oneTarget(),
      recordStore: store,
      directory: () async => tempDir,
      get: (url) async {
        fetched.add(url.path);
        return http.Response.bytes([1, 2, 3], 200);
      },
    ).restoreThumbnail(record);

    expect(fetched.single, contains('thumbnails/photo_bare.jpg'));
    expect(path, isNotNull);
    expect(File(path!).readAsBytesSync(), [1, 2, 3]);
    expect(
      (await store.getByLocalId('photo:bare'))!.thumbnailPath,
      path,
      reason: 'the record has to point at it, or the next open re-fetches',
    );
    expect(
      (await store.getByLocalId('photo:bare'))!.localDeleted,
      isTrue,
      reason: 'a thumbnail is not the original coming back',
    );
  });

  test('and says so when the bucket has no thumbnail either', () async {
    final store = FakeAssetRecordStore();
    await store.upsert(
      localId: 'photo:small',
      contentHash: 's',
      platform: 'ios',
    );
    final record = (await store.getByLocalId('photo:small'))!;

    final path = await OriginalRestore(
      targetsStore: await _oneTarget(),
      recordStore: store,
      directory: () async => Directory.systemTemp,
      get: (_) async => fail('nothing to ask for'),
    ).restoreThumbnail(record);

    expect(path, isNull);
  });

  test('a Live Photo comes back with its motion, not as a still', () async {
    final store = FakeAssetRecordStore();
    await store.upsert(
      localId: 'photo:live',
      contentHash: 'l',
      platform: 'ios',
      isLivePhoto: true,
    );
    await store.updateDerivative(
      'photo:live',
      DerivativeKind.original,
      const DerivativeState(
        status: UploadStatus.uploaded,
        destinationKey: 'originals/photo_live.HEIC',
      ),
    );
    await store.updateDerivative(
      'photo:live',
      DerivativeKind.livePhoto,
      const DerivativeState(
        status: UploadStatus.uploaded,
        destinationKey: 'originals/photo_live.mov',
      ),
    );
    await store.setLocalDeleted('photo:live', true);
    final record = (await store.getByLocalId('photo:live'))!;
    final fetched = <String>[];

    final tempDir = Directory.systemTemp.createTempSync('pv_restore_');
    addTearDown(() => tempDir.deleteSync(recursive: true));

    final path = await OriginalRestore(
      targetsStore: await () async {
        final targetsStore = BackupTargetsStore(store: FakeSecureStore());
        await targetsStore.add(
          accessKeyId: 'a',
          secretAccessKey: 'b',
          region: 'us-east-1',
          bucket: 'bucket',
          prefix: '',
        );
        return targetsStore;
      }(),
      recordStore: store,
      directory: () async => tempDir,
      get: (url) async {
        fetched.add(url.path);
        return http.Response.bytes([1, 2, 3], 200);
      },
    ).restore(record);

    expect(path, endsWith('photo_live.HEIC'));
    // Both halves, or what comes back is the still the backup was supposed
    // to stop being the whole story.
    expect(fetched.where((p) => p.endsWith('.mov')), hasLength(1));
    expect(File('${tempDir.path}/photo_live.mov').existsSync(), isTrue);
  });

  late Directory tempDir;

  setUp(() => tempDir = Directory.systemTemp.createTempSync('byop_restore_'));
  tearDown(() => tempDir.delete(recursive: true));

  Future<AssetRecord> cloudOnlyRecord(
    FakeAssetRecordStore store, {
    String? key = 'originals/manual_abc.jpg',
  }) async {
    await store.upsert(
      localId: 'manual:abc',
      contentHash: 'abc',
      platform: 'ios',
    );
    await store.updateDerivative(
      'manual:abc',
      DerivativeKind.original,
      DerivativeState(status: UploadStatus.uploaded, destinationKey: key),
    );
    await store.setLocalDeleted('manual:abc', true);
    return (await store.getByLocalId('manual:abc'))!;
  }

  test(
    'downloads the original, points the record at it, and clears cloud-only',
    () async {
      final targetsStore = BackupTargetsStore(store: FakeSecureStore());
      await targetsStore.add(
        accessKeyId: 'a',
        secretAccessKey: 'b',
        region: 'us-east-1',
        bucket: 'bucket',
        prefix: '',
      );
      final recordStore = FakeAssetRecordStore();
      final record = await cloudOnlyRecord(recordStore);

      final restored = await OriginalRestore(
        targetsStore: targetsStore,
        recordStore: recordStore,
        directory: () async => tempDir,
        get: (url) async => http.Response.bytes([7, 8, 9], 200),
      ).restore(record);

      expect(restored, isNotNull);
      expect(File(restored!).readAsBytesSync(), [7, 8, 9]);
      final updated = (await recordStore.getByLocalId('manual:abc'))!;
      expect(updated.localDeleted, isFalse);
      expect(updated.sourcePath, restored);
    },
  );

  test(
    'falls through to the next target when the first does not have it',
    () async {
      final targetsStore = BackupTargetsStore(store: FakeSecureStore());
      await targetsStore.add(
        accessKeyId: 'a',
        secretAccessKey: 'b',
        region: 'us-east-1',
        bucket: 'gone',
        prefix: '',
      );
      await targetsStore.add(
        accessKeyId: 'a',
        secretAccessKey: 'b',
        region: 'us-east-1',
        bucket: 'has-it',
        prefix: '',
      );
      final recordStore = FakeAssetRecordStore();
      final record = await cloudOnlyRecord(recordStore);
      var calls = 0;

      final restored = await OriginalRestore(
        targetsStore: targetsStore,
        recordStore: recordStore,
        directory: () async => tempDir,
        get: (url) async => http.Response.bytes([1], ++calls == 1 ? 404 : 200),
      ).restore(record);

      expect(calls, 2);
      expect(restored, isNotNull);
      expect(
        (await recordStore.getByLocalId('manual:abc'))!.localDeleted,
        isFalse,
      );
    },
  );

  test('stays cloud-only when every target fails', () async {
    final targetsStore = BackupTargetsStore(store: FakeSecureStore());
    await targetsStore.add(
      accessKeyId: 'a',
      secretAccessKey: 'b',
      region: 'us-east-1',
      bucket: 'bucket',
      prefix: '',
    );
    final recordStore = FakeAssetRecordStore();
    final record = await cloudOnlyRecord(recordStore);

    final restored = await OriginalRestore(
      targetsStore: targetsStore,
      recordStore: recordStore,
      directory: () async => tempDir,
      get: (url) async => throw Exception('offline'),
    ).restore(record);

    expect(restored, isNull);
    expect(
      (await recordStore.getByLocalId('manual:abc'))!.localDeleted,
      isTrue,
    );
  });

  test('does nothing for a record that was never backed up', () async {
    final targetsStore = BackupTargetsStore(store: FakeSecureStore());
    final recordStore = FakeAssetRecordStore();
    final record = await cloudOnlyRecord(recordStore, key: null);

    final restored = await OriginalRestore(
      targetsStore: targetsStore,
      recordStore: recordStore,
      directory: () async => tempDir,
      get: (url) async => throw StateError('should not be called'),
    ).restore(record);

    expect(restored, isNull);
  });
}
