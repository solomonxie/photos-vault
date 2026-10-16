import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/settings/s3_backup_target.dart';
import 'package:photos_vault/storage/asset_record.dart';
import 'package:photos_vault/upload/object_keys.dart';
import 'package:photos_vault/upload/pending_deletes.dart';

import '../support/fake_asset_record_store.dart';

S3BackupTarget _target(String id, {String prefix = ''}) => S3BackupTarget(
  id: id,
  accessKeyId: 'AK',
  secretAccessKey: 'SK',
  region: 'us-east-1',
  bucket: 'b-$id',
  prefix: prefix,
);

Set<(String, String)> _pairs(List<PendingDelete> tasks) => {
  for (final t in tasks) (t.targetId, t.objectKey),
};

/// The keys a photo's delete aims at: a wrong one deletes something else,
/// a missing one leaves an object nothing points at.
void main() {
  late FakeAssetRecordStore store;
  late AssetRecord record;

  setUp(() async {
    store = FakeAssetRecordStore();
    await store.upsert(localId: 'photo:A', contentHash: 'h', platform: 'ios');
    await store.updateDerivative(
      'photo:A',
      DerivativeKind.original,
      const DerivativeState(
        status: UploadStatus.uploaded,
        destinationKey: 'first/originals/IMG_1.HEIC',
      ),
    );
    record = (await store.getByLocalId('photo:A'))!;
  });

  test('each bucket is asked for its own key, under its own prefix', () {
    final tasks = deletionTasksFor(
      record,
      [_target('t1', prefix: 'first'), _target('t2', prefix: 'second/')],
      {
        DerivativeKind.original: {'t1': 'first/originals/IMG_1.HEIC'},
      },
    );
    expect(_pairs(tasks), {
      ('t1', 'first/originals/IMG_1.HEIC'),
      ('t2', 'second/originals/IMG_1.HEIC'),
    });
    expect(tasks.every((t) => t.localId == 'photo:A'), isTrue);
  });

  test('the key a row recorded wins over the rebuilt one', () {
    final tasks = deletionTasksFor(
      record,
      [_target('t2', prefix: 'second')],
      {
        DerivativeKind.original: {'t2': 'old/originals/IMG_1.heic'},
      },
    );
    expect(_pairs(tasks), {('t2', 'old/originals/IMG_1.heic')});
  });

  test('a bucket no longer configured keeps a dormant task', () {
    final tasks = deletionTasksFor(
      record,
      [_target('t1', prefix: 'first')],
      {
        DerivativeKind.original: {
          't1': 'first/originals/IMG_1.HEIC',
          'gone': 'x/originals/IMG_1.HEIC',
        },
      },
    );
    expect(_pairs(tasks), contains(('gone', 'x/originals/IMG_1.HEIC')));
  });

  test('with no bucket at all nothing is dropped: unnamed tasks wait', () {
    final tasks = deletionTasksFor(record, const [], {
      DerivativeKind.thumbnail: {'old': 'thumbnails/IMG_1.jpg'},
    });
    expect(_pairs(tasks), {
      ('old', 'thumbnails/IMG_1.jpg'),
      ('', 'first/originals/IMG_1.HEIC'),
    });
  });

  test('a bucket with no row gets the record key rebuilt; kinds never '
      'uploaded aim at nothing', () {
    final tasks = deletionTasksFor(record, [_target('t1')], const {});
    expect(_pairs(tasks), {('t1', 'originals/IMG_1.HEIC')});
  });

  test('groupUploads groups rows by photo, kind and bucket', () {
    final grouped = groupUploads([
      {
        'local_id': 'photo:A',
        'kind': 'original',
        'target_id': 't1',
        'destination_key': 'k1',
      },
      {
        'local_id': 'photo:A',
        'kind': 'thumbnail',
        'target_id': 't1',
        'destination_key': 'k2',
      },
      {
        'local_id': 'photo:B',
        'kind': 'retired_kind',
        'target_id': 't1',
        'destination_key': 'k3',
      },
    ]);
    expect(grouped.keys, ['photo:A']);
    expect(grouped['photo:A']![DerivativeKind.original], {'t1': 'k1'});
    expect(grouped['photo:A']![DerivativeKind.thumbnail], {'t1': 'k2'});
  });
}
