import 'dart:io';

import 'package:photos_vault/settings/backup_targets_store.dart';
import 'package:photos_vault/storage/asset_record.dart';
import 'package:photos_vault/upload/original_restore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import '../settings/fake_secure_store.dart';
import '../support/fake_asset_record_store.dart';

void main() {
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
