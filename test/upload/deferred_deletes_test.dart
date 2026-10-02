import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/settings/s3_backup_target.dart';
import 'package:photos_vault/storage/asset_record.dart';
import 'package:photos_vault/upload/pending_deletes.dart';
import 'package:photos_vault/viewer/private_album_gate.dart';

import '../support/fake_asset_record_store.dart';

void main() {
  late FakeAssetRecordStore records;
  late PendingDeletes pending;
  late DeferredDeletes deferred;

  setUp(() async {
    records = FakeAssetRecordStore();
    pending = PendingDeletes(
      store: records,
      delete: ({required S3BackupTarget target, required String key}) async =>
          true,
    );
    deferred = DeferredDeletes(store: records, pending: pending);
    await records.upsert(localId: 'photo:a', contentHash: 'a', platform: 'ios');
  });

  Future<void> markUploaded(String key) async {
    await records.recordUpload(
      localId: 'photo:a',
      kind: DerivativeKind.original,
      targetId: 't1',
      destinationKey: key,
    );
    await records.updateDerivative(
      'photo:a',
      DerivativeKind.original,
      DerivativeState(status: UploadStatus.uploaded, destinationKey: key),
    );
  }

  test('carriers wait until the plain copy is in every bucket', () async {
    await deferred.add('photo:a', const [
      PendingDelete(objectKey: 'p/originals/photo_a.jpg', targetId: 't1'),
    ]);

    expect(await deferred.release(), 0);
    expect(await pending.pending(), isEmpty);

    await markUploaded('p/originals/photo_a.heic');
    expect(await deferred.release(), 1);
    expect(await pending.pending(), const [
      PendingDelete(objectKey: 'p/originals/photo_a.jpg', targetId: 't1'),
    ]);
    expect(await deferred.waiting(), isEmpty);
  });

  test('a key the plain upload overwrote is never deleted', () async {
    await deferred.add('photo:a', const [
      PendingDelete(objectKey: 'p/originals/photo_a.jpg', targetId: 't1'),
    ]);
    await markUploaded('p/originals/photo_a.jpg');

    await deferred.release();

    expect(await pending.pending(), isEmpty);
    expect(await deferred.waiting(), isEmpty);
  });

  test('a photo with no record keeps its group waiting', () async {
    await deferred.add('photo:gone', const [
      PendingDelete(objectKey: 'k', targetId: 't1'),
    ]);
    expect(await deferred.release(), 0);
    expect((await deferred.waiting()).keys, ['photo:gone']);
  });

  test('un-hiding defers the carriers it forgets', () async {
    final dir = await Directory.systemTemp.createTemp('pv_unhide_');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/a.jpg')..writeAsBytesSync([1, 2, 3]);
    await records.setSourcePath('photo:a', file.path);
    await markUploaded('p/originals/photo_a.jpg');

    await resetBackupAfterUnhide(
      (await records.getByLocalId('photo:a'))!,
      records,
      deferred: deferred,
    );

    expect(
      await records.targetsHolding('photo:a', DerivativeKind.original),
      isEmpty,
    );
    expect((await deferred.waiting())['photo:a'], const [
      PendingDelete(objectKey: 'p/originals/photo_a.jpg', targetId: 't1'),
    ]);
  });

  test(
    'a copy with no bucket on record is queued against every bucket',
    () async {
      final dir = await Directory.systemTemp.createTemp('pv_unhide_');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/a.jpg')..writeAsBytesSync([1, 2, 3]);
      await records.setSourcePath('photo:a', file.path);
      await records.updateDerivative(
        'photo:a',
        DerivativeKind.original,
        const DerivativeState(
          status: UploadStatus.uploaded,
          destinationKey: 'p/originals/photo_a.jpg',
        ),
      );
      S3BackupTarget target(String id) => S3BackupTarget(
        id: id,
        accessKeyId: 'a',
        secretAccessKey: 's',
        region: 'us-east-1',
        bucket: 'b',
        prefix: 'p/',
      );

      await resetBackupAfterUnhide(
        (await records.getByLocalId('photo:a'))!,
        records,
        deferred: deferred,
        loadTargets: () async => [target('t1'), target('t2')],
      );

      expect((await deferred.waiting())['photo:a'], const [
        PendingDelete(objectKey: 'p/originals/photo_a.jpg', targetId: 't1'),
        PendingDelete(objectKey: 'p/originals/photo_a.jpg', targetId: 't2'),
      ]);
    },
  );
}
