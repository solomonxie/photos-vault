import 'package:back_your_own_photos/settings/aws_settings.dart';
import 'package:back_your_own_photos/settings/aws_settings_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_secure_store.dart';

void main() {
  test('load returns empty settings when nothing saved yet', () async {
    final store = AwsSettingsStore(store: FakeSecureStore());

    final settings = await store.load();

    expect(settings.hasCredentials, isFalse);
    expect(settings.accessKeyId, isEmpty);
  });

  test('save then load round-trips all fields, including storage classes', () async {
    final store = AwsSettingsStore(store: FakeSecureStore());
    const settings = AwsSettings(
      accessKeyId: 'AKIA...',
      secretAccessKey: 'shh',
      region: 'us-east-1',
      bucket: 'my-photos',
      prefix: 'backup/',
      thumbnailStorageClass: S3StorageClass.standard,
      mediumStorageClass: S3StorageClass.standardIa,
      originalStorageClass: S3StorageClass.deepArchive,
    );

    await store.save(settings);
    final loaded = await store.load();

    expect(loaded.accessKeyId, settings.accessKeyId);
    expect(loaded.secretAccessKey, settings.secretAccessKey);
    expect(loaded.region, settings.region);
    expect(loaded.bucket, settings.bucket);
    expect(loaded.prefix, settings.prefix);
    expect(loaded.thumbnailStorageClass, S3StorageClass.standard);
    expect(loaded.mediumStorageClass, S3StorageClass.standardIa);
    expect(loaded.originalStorageClass, S3StorageClass.deepArchive);
    expect(loaded.hasCredentials, isTrue);
  });

  test('storage class defaults to null (bucket default) when unset', () async {
    final store = AwsSettingsStore(store: FakeSecureStore());
    await store.save(
      const AwsSettings(accessKeyId: 'a', secretAccessKey: 'b', region: 'r', bucket: 'buck'),
    );

    final loaded = await store.load();

    expect(loaded.thumbnailStorageClass, isNull);
    expect(loaded.mediumStorageClass, isNull);
    expect(loaded.originalStorageClass, isNull);
  });

  test('clear removes saved settings', () async {
    final fake = FakeSecureStore();
    final store = AwsSettingsStore(store: fake);
    await store.save(const AwsSettings(accessKeyId: 'a', secretAccessKey: 'b', region: 'r', bucket: 'buck'));

    await store.clear();

    final loaded = await store.load();
    expect(loaded.hasCredentials, isFalse);
  });
}
