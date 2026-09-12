import 'package:back_your_own_photos/settings/backup_targets_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_secure_store.dart';

void main() {
  test('loadAll returns empty list when nothing saved yet', () async {
    final store = BackupTargetsStore(store: FakeSecureStore());

    expect(await store.loadAll(), isEmpty);
  });

  test('add appends a target with a generated id and persists it', () async {
    final store = BackupTargetsStore(store: FakeSecureStore());

    final added = await store.addS3(
      accessKeyId: 'AKIA...',
      secretAccessKey: 'shh',
      region: 'us-east-1',
      bucket: 'my-photos',
      prefix: 'backup/',
    );

    expect(added.id, isNotEmpty);
    final all = await store.loadAll();
    expect(all, hasLength(1));
    expect(all.single.bucket, 'my-photos');
    expect(all.single.id, added.id);
  });

  test('add twice keeps both targets, each with a distinct id', () async {
    final store = BackupTargetsStore(store: FakeSecureStore());

    await store.addS3(accessKeyId: 'a', secretAccessKey: 'b', region: 'us-east-1', bucket: 'bucket-one', prefix: '');
    await store.addS3(accessKeyId: 'a', secretAccessKey: 'b', region: 'eu-west-1', bucket: 'bucket-two', prefix: '');

    final all = await store.loadAll();
    expect(all, hasLength(2));
    expect(all.map((t) => t.bucket), containsAll(['bucket-one', 'bucket-two']));
    expect(all[0].id, isNot(all[1].id));
  });

  test('remove deletes only the matching target', () async {
    final store = BackupTargetsStore(store: FakeSecureStore());
    final keep = await store.addS3(accessKeyId: 'a', secretAccessKey: 'b', region: 'r', bucket: 'keep-me', prefix: '');
    final drop = await store.addS3(accessKeyId: 'a', secretAccessKey: 'b', region: 'r', bucket: 'drop-me', prefix: '');

    await store.remove(drop.id);

    final all = await store.loadAll();
    expect(all, hasLength(1));
    expect(all.single.id, keep.id);
  });
}
