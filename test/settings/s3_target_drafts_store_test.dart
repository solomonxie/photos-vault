import 'package:bring_your_own_photos/settings/s3_target_drafts_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_secure_store.dart';

void main() {
  test('loadAll returns empty list when nothing saved yet', () async {
    final store = S3TargetDraftsStore(store: FakeSecureStore());

    expect(await store.loadAll(), isEmpty);
  });

  test('save appends a new draft with a generated id', () async {
    final store = S3TargetDraftsStore(store: FakeSecureStore());

    await store.save(
      accessKeyId: 'AKIA1',
      secretAccessKey: 'shh',
      bucket: 'my-bucket',
      prefix: 'p/',
    );

    final all = await store.loadAll();
    expect(all, hasLength(1));
    expect(all.single.bucket, 'my-bucket');
    expect(all.single.id, isNotEmpty);
  });

  test(
    'saving again for the same bucket+access key replaces it, not duplicates',
    () async {
      final store = S3TargetDraftsStore(store: FakeSecureStore());

      await store.save(
        accessKeyId: 'AKIA1',
        secretAccessKey: 'shh',
        bucket: 'my-bucket',
        prefix: 'p/',
      );
      final firstId = (await store.loadAll()).single.id;
      await store.save(
        accessKeyId: 'AKIA1',
        secretAccessKey: 'updated-secret',
        bucket: 'my-bucket',
        prefix: 'p2/',
      );

      final all = await store.loadAll();
      expect(all, hasLength(1));
      expect(all.single.id, firstId);
      expect(all.single.secretAccessKey, 'updated-secret');
      expect(all.single.prefix, 'p2/');
    },
  );

  test(
    'drafts for different buckets or access keys are kept separately',
    () async {
      final store = S3TargetDraftsStore(store: FakeSecureStore());

      await store.save(
        accessKeyId: 'AKIA1',
        secretAccessKey: 'a',
        bucket: 'bucket-one',
        prefix: '',
      );
      await store.save(
        accessKeyId: 'AKIA2',
        secretAccessKey: 'b',
        bucket: 'bucket-two',
        prefix: '',
      );

      expect(await store.loadAll(), hasLength(2));
    },
  );

  test('remove deletes only the matching draft', () async {
    final store = S3TargetDraftsStore(store: FakeSecureStore());
    await store.save(
      accessKeyId: 'AKIA1',
      secretAccessKey: 'a',
      bucket: 'keep-me',
      prefix: '',
    );
    await store.save(
      accessKeyId: 'AKIA2',
      secretAccessKey: 'b',
      bucket: 'drop-me',
      prefix: '',
    );
    final drop = (await store.loadAll()).firstWhere(
      (d) => d.bucket == 'drop-me',
    );

    await store.remove(drop.id);

    final all = await store.loadAll();
    expect(all, hasLength(1));
    expect(all.single.bucket, 'keep-me');
  });

  test(
    'removeMatching drops the draft for a given bucket+access key',
    () async {
      final store = S3TargetDraftsStore(store: FakeSecureStore());
      await store.save(
        accessKeyId: 'AKIA1',
        secretAccessKey: 'a',
        bucket: 'my-bucket',
        prefix: '',
      );

      await store.removeMatching(accessKeyId: 'AKIA1', bucket: 'my-bucket');

      expect(await store.loadAll(), isEmpty);
    },
  );
}
