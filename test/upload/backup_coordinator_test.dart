import 'package:back_your_own_photos/settings/backup_targets_store.dart';
import 'package:back_your_own_photos/settings/s3_backup_target.dart';
import 'package:back_your_own_photos/storage/asset_record.dart';
import 'package:back_your_own_photos/storage/asset_record_store.dart';
import 'package:back_your_own_photos/upload/backup_coordinator.dart';
import 'package:back_your_own_photos/upload/s3_uploader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../settings/fake_secure_store.dart';

class _FakeS3Uploader implements S3Uploader {
  _FakeS3Uploader(this.result);
  final bool result;
  final keys = <String>[];

  @override
  Future<bool> put({required String filePath, required String key, required S3BackupTarget target}) async {
    keys.add(key);
    return result;
  }
}

void main() {
  setUpAll(sqfliteFfiInit);

  // sqflite_common_ffi caches in-memory DBs by path (singleInstance
  // default), so distinct stores using the same sentinel path leak state
  // across tests unless each is explicitly closed.
  AssetRecordStore newRecordStore() {
    final store = AssetRecordStore(databaseFactory: databaseFactoryFfi, path: inMemoryDatabasePath);
    addTearDown(store.close);
    return store;
  }

  test('with no configured targets, status stays pending', () async {
    final targetsStore = BackupTargetsStore(store: FakeSecureStore());
    final recordStore = newRecordStore();
    final record = await recordStore.upsert(localId: 'manual:abc', contentHash: 'abc', platform: 'ios');
    final coordinator = BackupCoordinator(targetsStore: targetsStore, recordStore: recordStore);

    final succeeded = await coordinator.backUpDerivative(record: record, kind: DerivativeKind.original, filePath: '/tmp/a.jpg');

    expect(succeeded, 0);
    final updated = await recordStore.getByLocalId('manual:abc');
    expect(updated!.stateOf(DerivativeKind.original).status, UploadStatus.pending);
  });

  test('uploads to an S3 target and marks the derivative uploaded', () async {
    final targetsStore = BackupTargetsStore(store: FakeSecureStore());
    await targetsStore.addS3(accessKeyId: 'a', secretAccessKey: 'b', region: 'us-east-1', bucket: 'bucket', prefix: 'p/');
    final recordStore = newRecordStore();
    final record = await recordStore.upsert(localId: 'manual:abc', contentHash: 'abc', platform: 'ios');
    final fakeUploader = _FakeS3Uploader(true);
    final coordinator = BackupCoordinator(targetsStore: targetsStore, recordStore: recordStore, s3Uploader: fakeUploader);

    final succeeded = await coordinator.backUpDerivative(record: record, kind: DerivativeKind.original, filePath: '/tmp/a.jpg');

    expect(succeeded, 1);
    expect(fakeUploader.keys.single, 'p/originals/manual_abc.jpg');
    final updated = await recordStore.getByLocalId('manual:abc');
    expect(updated!.stateOf(DerivativeKind.original).status, UploadStatus.uploaded);
    expect(updated.stateOf(DerivativeKind.original).destinationKey, 'p/originals/manual_abc.jpg');
  });

  test('marks the derivative failed when every target fails', () async {
    final targetsStore = BackupTargetsStore(store: FakeSecureStore());
    await targetsStore.addS3(accessKeyId: 'a', secretAccessKey: 'b', region: 'us-east-1', bucket: 'bucket', prefix: '');
    final recordStore = newRecordStore();
    final record = await recordStore.upsert(localId: 'manual:abc', contentHash: 'abc', platform: 'ios');
    final coordinator = BackupCoordinator(
      targetsStore: targetsStore,
      recordStore: recordStore,
      s3Uploader: _FakeS3Uploader(false),
    );

    final succeeded = await coordinator.backUpDerivative(record: record, kind: DerivativeKind.original, filePath: '/tmp/a.jpg');

    expect(succeeded, 0);
    final updated = await recordStore.getByLocalId('manual:abc');
    expect(updated!.stateOf(DerivativeKind.original).status, UploadStatus.failed);
  });
}
