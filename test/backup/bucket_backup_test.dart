import 'dart:convert';

import 'package:bring_your_own_photos/backup/app_snapshot.dart';
import 'package:bring_your_own_photos/backup/bucket_backup.dart';
import 'package:bring_your_own_photos/backup/snapshot_archive.dart';
import 'package:bring_your_own_photos/settings/s3_backup_target.dart';
import 'package:bring_your_own_photos/settings/s3_listing.dart';
import 'package:bring_your_own_photos/settings/backup_targets_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../settings/fake_secure_store.dart';
import '../support/fake_album_store.dart';
import '../support/fake_asset_record_store.dart';
import '../support/fake_person_store.dart';

/// A bucket that lives in a map, keyed the way the real one would be — the
/// file and where it lands is what these cases are about, not the signing.
class _FakeBucket {
  final objects = <String, List<int>>{};

  /// Presigned URLs carry the bucket in the host and the key in the path,
  /// which is enough to file the object without teaching the fake anything
  /// about signatures.
  Future<http.Response> put(Uri url, {Object? body}) async {
    objects[_name(url)] = body! as List<int>;
    return http.Response('', 200);
  }

  Future<http.Response> get(Uri url) async {
    final body = objects[_name(url)];
    return body == null
        ? http.Response('', 404)
        : http.Response.bytes(body, 200);
  }

  /// Enough of a listing for "what's the newest month in there?".
  Future<S3ListingResult> list({
    required S3BackupTarget target,
    String prefix = '',
  }) async => S3ListingResult(
    S3ListingOutcome.ok,
    page: S3ListingPage(
      folders: const [],
      objects: [
        for (final key in objects.keys)
          if (key.startsWith('${target.bucket}/$prefix'))
            S3Object(
              key: key.substring(target.bucket.length + 1),
              size: objects[key]!.length,
              lastModified: DateTime(2026, 9, 17),
            ),
      ],
    ),
  );

  static String _name(Uri url) => '${url.host.split('.').first}${url.path}';
}

({
  FakeAssetRecordStore assets,
  FakeAlbumStore albums,
  FakePersonStore people,
  AppSnapshotIo io,
})
_stores() {
  final assets = FakeAssetRecordStore();
  final albums = FakeAlbumStore();
  final people = FakePersonStore();
  return (
    assets: assets,
    albums: albums,
    people: people,
    io: AppSnapshotIo(
      assetRecordStore: assets,
      albumStore: albums,
      personStore: people,
    ),
  );
}

Future<BackupTargetsStore> _storeWithBucket({
  String bucket = 'my-bucket',
  String prefix = 'photos/',
}) async {
  final store = BackupTargetsStore(store: FakeSecureStore());
  await store.add(
    accessKeyId: 'a',
    secretAccessKey: 'b',
    region: 'us-east-1',
    bucket: bucket,
    prefix: prefix,
  );
  return store;
}

void main() {
  setUpAll(sqfliteFfiInit);

  BucketBackup build({
    required AppSnapshotIo snapshots,
    required FakeAssetRecordStore settings,
    required BackupTargetsStore targets,
    required _FakeBucket bucket,
  }) => BucketBackup(
    snapshots: snapshots,
    settings: settings,
    targetsStore: targets,
    put: bucket.put,
    get: bucket.get,
    list: bucket.list,
  );

  test('the switch writes the snapshot under the bucket prefix', () async {
    final source = _stores();
    await source.assets.upsert(
      localId: 'photo:PH1',
      contentHash: 'PH1',
      platform: 'ios',
    );
    await source.assets.setTags('photo:PH1', ['temple']);
    final targets = await _storeWithBucket();
    final bucket = _FakeBucket();
    final backup = build(
      snapshots: source.io,
      settings: source.assets,
      targets: targets,
      bucket: bucket,
    );

    expect(await backup.isEnabled(), isFalse);
    await backup.setEnabled(true);

    expect(await backup.isEnabled(), isTrue);
    // Flipping it on wrote at once, in its own folder beside the photos,
    // as this month's archive.
    final name = monthlyArchiveName(DateTime.now());
    expect(bucket.objects.keys.single, 'my-bucket/photos/app-data/$name');
    expect(
      unzipSnapshot(bucket.objects.values.single)!.encode(),
      contains('temple'),
    );
    expect(await backup.lastBackupAt(), isNotNull);
  });

  test('with no bucket configured there is nothing to write to', () async {
    final source = _stores();
    final bucket = _FakeBucket();
    final backup = build(
      snapshots: source.io,
      settings: source.assets,
      targets: BackupTargetsStore(store: FakeSecureStore()),
      bucket: bucket,
    );

    expect(await backup.backUpNow(), isFalse);
    expect(bucket.objects, isEmpty);
    expect(await backup.lastBackupAt(), isNull);
  });

  test('a reinstall gets its library back from the bucket', () async {
    final source = _stores();
    await source.assets.upsert(
      localId: 'photo:PH1',
      contentHash: 'PH1',
      platform: 'ios',
      libraryId: 'PH1',
    );
    await source.assets.setDescription('photo:PH1', 'The maple one');
    final album = await source.albums.upsert(id: 'a1', name: 'Japan');
    await source.albums.addAssets(album.id, ['photo:PH1']);
    final person = await source.people.create(name: 'Mia');
    await source.people.addAssets(person.id, ['photo:PH1']);
    final targets = await _storeWithBucket();
    final bucket = _FakeBucket();
    await build(
      snapshots: source.io,
      settings: source.assets,
      targets: targets,
      bucket: bucket,
    ).setEnabled(true);

    // Same bucket, same keychain credentials, a brand new empty app.
    final fresh = _stores();
    final restored = await build(
      snapshots: fresh.io,
      settings: fresh.assets,
      targets: targets,
      bucket: bucket,
    ).restoreIfFreshInstall();

    expect(restored, 1);
    final photo = (await fresh.assets.getByLocalId('photo:PH1'))!;
    expect(photo.description, 'The maple one');
    expect(await fresh.albums.localIdsIn('a1'), ['photo:PH1']);
    expect((await fresh.people.listAll()).single.name, 'Mia');
  });

  test('a restore takes the newest month it can find', () async {
    final targets = await _storeWithBucket();
    final bucket = _FakeBucket();
    final older = _stores();
    await older.assets.upsert(
      localId: 'photo:old',
      contentHash: 'old',
      platform: 'ios',
    );
    final newer = _stores();
    await newer.assets.upsert(
      localId: 'photo:new',
      contentHash: 'new',
      platform: 'ios',
    );
    bucket.objects['my-bucket/photos/app-data/202607.zip'] = zipSnapshot(
      await older.io.export(),
    );
    bucket.objects['my-bucket/photos/app-data/202609.zip'] = zipSnapshot(
      await newer.io.export(),
    );

    final fresh = _stores();
    final restored = await build(
      snapshots: fresh.io,
      settings: fresh.assets,
      targets: targets,
      bucket: bucket,
    ).restoreIfFreshInstall();

    expect(restored, 1);
    expect(await fresh.assets.getByLocalId('photo:new'), isNotNull);
    expect(
      await fresh.assets.getByLocalId('photo:old'),
      isNull,
      reason: 'September is newer than July, and names sort that way',
    );
  });

  test(
    'a backup written before this app zipped anything still reads',
    () async {
      final targets = await _storeWithBucket();
      final bucket = _FakeBucket();
      final source = _stores();
      await source.assets.upsert(
        localId: 'photo:a',
        contentHash: 'a',
        platform: 'ios',
      );
      bucket.objects['my-bucket/photos/app-data/library.json'] = utf8.encode(
        (await source.io.export()).encode(),
      );

      final fresh = _stores();
      final restored = await build(
        snapshots: fresh.io,
        settings: fresh.assets,
        targets: targets,
        bucket: bucket,
      ).restoreIfFreshInstall();

      expect(restored, 1);
      expect(await fresh.assets.getByLocalId('photo:a'), isNotNull);
    },
  );

  test('a library that already has photos in it is left alone', () async {
    final source = _stores();
    await source.assets.upsert(
      localId: 'photo:PH1',
      contentHash: 'PH1',
      platform: 'ios',
    );
    final targets = await _storeWithBucket();
    final bucket = _FakeBucket();
    await build(
      snapshots: source.io,
      settings: source.assets,
      targets: targets,
      bucket: bucket,
    ).setEnabled(true);

    // Not a fresh install: restoring here would layer a stale snapshot
    // over live work.
    final live = _stores();
    await live.assets.upsert(
      localId: 'photo:PH2',
      contentHash: 'PH2',
      platform: 'ios',
    );
    final restored = await build(
      snapshots: live.io,
      settings: live.assets,
      targets: targets,
      bucket: bucket,
    ).restoreIfFreshInstall();

    expect(restored, 0);
    expect(await live.assets.getByLocalId('photo:PH1'), isNull);
  });
}
