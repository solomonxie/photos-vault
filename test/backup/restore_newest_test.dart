import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:photos_vault/backup/app_snapshot.dart';
import 'package:photos_vault/backup/bucket_backup.dart';
import 'package:photos_vault/backup/icloud_backup.dart';
import 'package:photos_vault/backup/icloud_drive.dart';
import 'package:photos_vault/backup/pause_backup.dart';
import 'package:photos_vault/backup/snapshot_archive.dart';
import 'package:photos_vault/settings/backup_targets_store.dart';
import 'package:photos_vault/settings/s3_backup_target.dart';
import 'package:photos_vault/settings/s3_listing.dart';

import '../settings/fake_secure_store.dart';
import '../support/fake_album_store.dart';
import '../support/fake_asset_record_store.dart';
import '../support/fake_person_store.dart';

class _Drive implements ICloudDrive {
  final archives = <String, Uint8List>{};

  @override
  Future<ICloudState> status() async => ICloudState.available;

  @override
  Future<List<String>> list() async => archives.keys.toList();

  @override
  Future<Uint8List?> readBytes(String name) async => archives[name];

  @override
  Future<Uint8List?> readLatestBytes() async => null;

  @override
  Future<String?> readLatest() async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Bucket {
  final objects = <String, List<int>>{};

  Future<http.Response> get(Uri url) async {
    final body = objects['${url.host.split('.').first}${url.path}'];
    return body == null
        ? http.Response('', 404)
        : http.Response.bytes(body, 200);
  }

  Future<S3ListingResult> list({
    required S3BackupTarget target,
    String prefix = '',
    String? continuationToken,
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
              lastModified: DateTime(2026),
            ),
      ],
    ),
  );
}

AppSnapshot _snapshot(String localId, DateTime at) => AppSnapshot(
  version: AppSnapshot.currentVersion,
  exportedAt: at,
  assets: [
    {'localId': localId, 'contentHash': localId, 'platform': 'ios'},
  ],
  albums: const [],
  people: const [],
);

void main() {
  late FakeAssetRecordStore records;
  late AppSnapshotIo io;
  late _Drive drive;
  late _Bucket bucket;
  late ICloudBackup icloud;
  late BucketBackup bucketBackup;

  setUp(() async {
    records = FakeAssetRecordStore();
    io = AppSnapshotIo(
      assetRecordStore: records,
      albumStore: FakeAlbumStore(),
      personStore: FakePersonStore(),
    );
    drive = _Drive();
    bucket = _Bucket();
    final targets = BackupTargetsStore(store: FakeSecureStore());
    await targets.add(
      accessKeyId: 'a',
      secretAccessKey: 'b',
      region: 'us-east-1',
      bucket: 'my-bucket',
      prefix: 'photos/',
    );
    icloud = ICloudBackup(snapshots: io, settings: records, drive: drive);
    bucketBackup = BucketBackup(
      snapshots: io,
      settings: records,
      targetsStore: targets,
      get: bucket.get,
      list: bucket.list,
    );
  });

  void inICloud(String name, AppSnapshot s) =>
      drive.archives[name] = zipSnapshot(s);
  void inBucket(String name, AppSnapshot s) =>
      bucket.objects['my-bucket/photos/app-data/$name'] = zipSnapshot(s);

  Future<Set<String>> restoredIds() async => {
    for (final r in await records.listAll()) r.localId,
  };

  test('the bucket\'s newer copy wins over iCloud\'s older one', () async {
    inICloud('20261001.zip', _snapshot('photo:old', DateTime(2026, 10, 1)));
    inBucket('20261012.zip', _snapshot('photo:new', DateTime(2026, 10, 12)));

    expect(
      await restoreNewestOnFreshInstall(icloud: icloud, bucket: bucketBackup),
      1,
    );
    expect(await restoredIds(), {'photo:new'});
    // Neither layers its copy on later.
    expect(await records.getAppState(ICloudBackup.restoredKey), isNotNull);
    expect(await records.getAppState(BucketBackup.restoredKey), isNotNull);
  });

  test('and iCloud\'s, when it is the newer', () async {
    inICloud('20261014.zip', _snapshot('photo:new', DateTime(2026, 10, 14)));
    inBucket('20261012.zip', _snapshot('photo:old', DateTime(2026, 10, 12)));

    await restoreNewestOnFreshInstall(icloud: icloud, bucket: bucketBackup);
    expect(await restoredIds(), {'photo:new'});
  });

  test('a pre-deletion copy beats a newer daily one elsewhere', () async {
    inICloud(
      preDeletionArchiveName(DateTime(2026, 10, 2, 9)),
      _snapshot('photo:kept', DateTime(2026, 10, 2, 9)),
    );
    inBucket('20261012.zip', _snapshot('photo:after', DateTime(2026, 10, 12)));

    await restoreNewestOnFreshInstall(icloud: icloud, bucket: bucketBackup);
    expect(await restoredIds(), {'photo:kept'});
  });

  test('the newest across every page of a long app-data folder', () async {
    for (var day = 1; day <= 9; day++) {
      inBucket(
        '2026100$day.zip',
        _snapshot('photo:$day', DateTime(2026, 10, day)),
      );
    }
    final paged = BucketBackup(
      snapshots: io,
      settings: records,
      targetsStore: bucketBackup.targetsStore,
      get: bucket.get,
      // Three to a page, oldest first, like S3's key order.
      list: ({required target, prefix = '', continuationToken}) async {
        final all = (await bucket.list(
          target: target,
          prefix: prefix,
        )).page!.objects..sort((a, b) => a.key.compareTo(b.key));
        final start = int.parse(continuationToken ?? '0');
        final end = (start + 3).clamp(0, all.length);
        return S3ListingResult(
          S3ListingOutcome.ok,
          page: S3ListingPage(
            folders: const [],
            objects: all.sublist(start, end),
            nextToken: end < all.length ? '$end' : null,
          ),
        );
      },
    );

    expect(await paged.restoreIfFreshInstall(), 1);
    expect(await restoredIds(), {'photo:9'});
  });
}
