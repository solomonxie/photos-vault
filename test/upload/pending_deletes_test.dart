import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/settings/s3_backup_target.dart';
import 'package:photos_vault/upload/pending_deletes.dart';

import '../support/fake_asset_record_store.dart';

const _target = S3BackupTarget(
  id: 't1',
  accessKeyId: 'AKIA',
  secretAccessKey: 'secret',
  region: 'us-east-1',
  bucket: 'my-bucket',
  prefix: '',
);

const _other = S3BackupTarget(
  id: 't2',
  accessKeyId: 'AKIA',
  secretAccessKey: 'secret',
  region: 'us-east-1',
  bucket: 'second',
  prefix: '',
);

void main() {
  test('a delete that lands is forgotten', () async {
    final store = FakeAssetRecordStore();
    final tried = <String>[];
    final deletes = PendingDeletes(
      store: store,
      delete: ({required target, required key}) async {
        tried.add(key);
        return true;
      },
    );

    await deletes.add(const [
      PendingDelete(objectKey: 'originals/a.jpg', targetId: 't1'),
      PendingDelete(objectKey: 'thumbnails/a.jpg', targetId: 't1'),
    ]);
    expect(await deletes.count(), 2);

    expect(await deletes.drain([_target]), 0);
    expect(tried, ['originals/a.jpg', 'thumbnails/a.jpg']);
    expect(await deletes.count(), 0);
  });

  test('a delete that fails is kept, and tried again', () async {
    final store = FakeAssetRecordStore();
    var succeed = false;
    final deletes = PendingDeletes(
      store: store,
      delete: ({required target, required key}) async => succeed,
    );

    await deletes.add(const [
      PendingDelete(objectKey: 'originals/a.jpg', targetId: 't1'),
    ]);
    expect(await deletes.drain([_target]), 1, reason: 'offline, so it waits');
    expect(await deletes.count(), 1);

    succeed = true;
    expect(await deletes.drain([_target]), 0);
  });

  test('a task for a bucket the app no longer has goes dormant', () async {
    final store = FakeAssetRecordStore();
    var tried = 0;
    final deletes = PendingDeletes(
      store: store,
      delete: ({required target, required key}) async {
        tried++;
        return true;
      },
    );

    await deletes.add(const [
      PendingDelete(objectKey: 'originals/a.jpg', targetId: 't2'),
    ]);
    expect(await deletes.drain([_target]), 1);
    expect(tried, 0, reason: 'nothing to delete it from');
    expect(await deletes.count(), 1, reason: 'dormant, not dropped');

    // Re-add that bucket and it runs.
    expect(await deletes.drain([_target, _other]), 0);
    expect(tried, 1);
  });

  test('the same object queued twice is one task', () async {
    final store = FakeAssetRecordStore();
    final deletes = PendingDeletes(
      store: store,
      delete: ({required target, required key}) async => true,
    );
    await deletes.add(const [
      PendingDelete(objectKey: 'originals/a.jpg', targetId: 't1'),
    ]);
    await deletes.add(const [
      PendingDelete(objectKey: 'originals/a.jpg', targetId: 't1'),
    ]);
    expect(await deletes.count(), 1);
  });
}
