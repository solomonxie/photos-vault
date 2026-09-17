import 'package:bring_your_own_photos/settings/backup_targets_store.dart';
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

    await store.addS3(
      accessKeyId: 'a',
      secretAccessKey: 'b',
      region: 'us-east-1',
      bucket: 'bucket-one',
      prefix: '',
    );
    await store.addS3(
      accessKeyId: 'a',
      secretAccessKey: 'b',
      region: 'eu-west-1',
      bucket: 'bucket-two',
      prefix: '',
    );

    final all = await store.loadAll();
    expect(all, hasLength(2));
    expect(all.map((t) => t.bucket), containsAll(['bucket-one', 'bucket-two']));
    expect(all[0].id, isNot(all[1].id));
  });

  test('remove deletes only the matching target', () async {
    final store = BackupTargetsStore(store: FakeSecureStore());
    final keep = await store.addS3(
      accessKeyId: 'a',
      secretAccessKey: 'b',
      region: 'r',
      bucket: 'keep-me',
      prefix: '',
    );
    final drop = await store.addS3(
      accessKeyId: 'a',
      secretAccessKey: 'b',
      region: 'r',
      bucket: 'drop-me',
      prefix: '',
    );

    await store.remove(drop.id);

    final all = await store.loadAll();
    expect(all, hasLength(1));
    expect(all.single.id, keep.id);
  });

  test('order strategy defaults to fileByFile and persists once set', () async {
    final store = BackupTargetsStore(store: FakeSecureStore());

    expect(await store.getOrderStrategy(), BackupOrderStrategy.fileByFile);

    await store.setOrderStrategy(BackupOrderStrategy.bucketByBucket);

    expect(await store.getOrderStrategy(), BackupOrderStrategy.bucketByBucket);
  });

  test('backup format defaults to original and persists once set', () async {
    final store = BackupTargetsStore(store: FakeSecureStore());

    expect(await store.getBackupFormat(), BackupFormat.original);

    await store.setBackupFormat(BackupFormat.optimized);

    expect(await store.getBackupFormat(), BackupFormat.optimized);
  });

  test(
    'sync frequency defaults to manual, and lastSyncAt defaults to null',
    () async {
      final store = BackupTargetsStore(store: FakeSecureStore());

      expect(await store.getSyncFrequency(), SyncFrequency.manual);
      expect(await store.getLastSyncAt(), isNull);

      await store.setSyncFrequency(SyncFrequency.everyHour);
      final now = DateTime(2026, 1, 1, 12);
      await store.setLastSyncAt(now);

      expect(await store.getSyncFrequency(), SyncFrequency.everyHour);
      expect(await store.getLastSyncAt(), now);
    },
  );

  group('isSyncDue', () {
    final now = DateTime(2026, 1, 1, 12);

    test('manual is never due, regardless of how long it has been', () {
      expect(
        isSyncDue(frequency: SyncFrequency.manual, lastSyncAt: null, now: now),
        isFalse,
      );
      expect(
        isSyncDue(
          frequency: SyncFrequency.manual,
          lastSyncAt: DateTime(2000),
          now: now,
        ),
        isFalse,
      );
    });

    test('any non-manual frequency is due when it has never run', () {
      expect(
        isSyncDue(frequency: SyncFrequency.daily, lastSyncAt: null, now: now),
        isTrue,
      );
    });

    test('due once the interval has elapsed, not before', () {
      final lastSyncAt = now.subtract(const Duration(minutes: 14));
      expect(
        isSyncDue(
          frequency: SyncFrequency.every15Minutes,
          lastSyncAt: lastSyncAt,
          now: now,
        ),
        isFalse,
      );

      final justOver = now.subtract(const Duration(minutes: 15, seconds: 1));
      expect(
        isSyncDue(
          frequency: SyncFrequency.every15Minutes,
          lastSyncAt: justOver,
          now: now,
        ),
        isTrue,
      );
    });
  });
}
