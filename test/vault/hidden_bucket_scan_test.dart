import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:photos_vault/settings/backup_targets_store.dart';
import 'package:photos_vault/settings/s3_backup_target.dart';
import 'package:photos_vault/storage/asset_record.dart';
import 'package:photos_vault/storage/bucket_object.dart';
import 'package:photos_vault/vault/album_index.dart';
import 'package:photos_vault/vault/bucket.dart';
import 'package:photos_vault/vault/carrier.dart';
import 'package:photos_vault/vault/cipher.dart';
import 'package:photos_vault/vault/hidden_bucket_scan.dart';
import 'package:photos_vault/vault/hidden_migration.dart';
import 'package:photos_vault/vault/keys.dart';
import 'package:photos_vault/vault/object_key.dart';
import 'package:photos_vault/vault/store.dart';

import '../settings/fake_secure_store.dart';
import '../support/fake_asset_record_store.dart';
import '../support/memory_bucket.dart';
import 'carrier_fixtures.dart';

class _NoExclusion extends BackupExclusion {
  const _NoExclusion();

  @override
  Future<bool> exclude(String path) async => true;
}

void main() {
  final keys = AlbumKeys(
    albumKey: Uint8List.fromList(List.generate(32, (i) => i)),
    entry: PassphraseEntry(
      id: 'e1',
      salt: Uint8List.fromList(List.generate(16, (i) => i * 3)),
      verifier: Uint8List(32),
      hint: '',
    ),
    outboxKey: Uint8List.fromList(List.generate(32, (i) => 255 - i)),
  );
  final other = AlbumKeys(
    albumKey: Uint8List.fromList(List.generate(32, (i) => 100 - i)),
    entry: keys.entry,
  );
  final cipher = PlatformCipher();

  late Directory dir;
  late FakeAssetRecordStore records;
  late BackupTargetsStore targets;
  late S3BackupTarget target;
  late MemoryBucket remote;
  late VaultStore store;
  late VaultBucket bucket;

  AssetRecord record(String id) => AssetRecord(
    localId: id,
    contentHash: 'h',
    platform: 'ios',
    createdAt: DateTime(2026),
    updatedAt: DateTime(2026),
  );

  Uint8List carrierFor(AlbumKeys k, AssetRecord r, DateTime taken) =>
      buildJpegCarrier(
        cipher: cipher,
        keys: k.carrier,
        masterSalt: k.entry.salt,
        decoy: decoyJpeg(),
        thumbnail: Uint8List.fromList(List.generate(3000, (i) => i % 200)),
        original: Uint8List.fromList(List.generate(20000, (i) => i % 250)),
        extension: 'jpg',
        nonce: hiddenNonce(k.carrier, r),
        meta: CarrierMeta(
          takenAt: taken,
          width: 30,
          height: 40,
          isVideo: false,
        ),
      )!;

  Future<void> list() => records.replaceBucketObjects(target.id, [
    for (final e in remote.objects.entries)
      BucketObject(
        targetId: target.id,
        key: e.key,
        size: e.value.length,
        lastModified: DateTime(2026),
      ),
  ]);

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('pv_scan_');
    records = FakeAssetRecordStore();
    targets = BackupTargetsStore(store: FakeSecureStore());
    target = await targets.add(
      accessKeyId: 'a',
      secretAccessKey: 'b',
      region: 'us-east-1',
      bucket: 'b',
      prefix: 'photos-vault/',
    );
    remote = MemoryBucket();
    store = VaultStore(
      directory: () async => dir,
      exclusion: const _NoExclusion(),
    );
    bucket = VaultBucket(
      targetsStore: targets,
      store: store,
      put: (url, {body}) async => http.Response('', 200),
      get: (url, {headers}) async => http.Response('', 404),
    );
  });
  tearDown(() => dir.deleteSync(recursive: true));

  HiddenBucketScan scan() => HiddenBucketScan(
    store: records,
    targetsStore: targets,
    bucket: bucket,
    passphrases: () async => [keys.entry],
    ops: remote,
  );

  test('a carrier of this album is added with its real date', () async {
    final r = record('photo:1');
    final name = '${hiddenBaseName(keys.carrier, r)}.jpg';
    remote.objects['photos-vault/originals/$name'] = carrierFor(
      keys,
      r,
      DateTime(2024, 5, 6, 7),
    );
    await list();

    expect(await scan().run(keys), 1);

    final entry = (await bucket.readAlbum(keys)).entries.single;
    expect(entry.objectKey, 'originals/$name');
    expect(entry.takenAt, DateTime(2024, 5, 6, 7));
    expect(entry.width, 30);
    expect(entry.height, 40);
  });

  test('it is added once, and another album finds nothing', () async {
    final r = record('photo:1');
    remote.objects['photos-vault/originals/${hiddenBaseName(keys.carrier, r)}.jpg'] =
        carrierFor(keys, r, DateTime(2024));
    await list();

    expect(await scan().run(other), 0);
    expect(await scan().run(keys), 1);
    expect(await scan().run(keys), 0);
    expect((await bucket.readAlbum(keys)).entries, hasLength(1));
  });

  test('an ordinary protocol name is not mistaken for a carrier', () async {
    final r = record('photo:1');
    remote.objects['photos-vault/originals/${ordinaryBaseName(r)}.jpg'] =
        decoyJpeg();
    await list();

    expect(await scan().run(keys), 0);
  });

  test('migration gives an old carrier a protocol name and repoints the '
      'index', () async {
    const oldKey = 'originals/photo_old_L0_001.jpg';
    final r = record('photo:old');
    final bytes = carrierFor(keys, r, DateTime(2023, 1, 2));
    remote.objects['photos-vault/$oldKey'] = bytes;
    await store.putCarrierBytes(keys, oldKey, bytes);
    await bucket.writeAlbum(
      keys: keys,
      entries: [
        IndexEntry(
          objectKey: oldKey,
          takenAt: DateTime(2023, 1, 2),
          width: 30,
          height: 40,
          isVideo: false,
        ),
      ],
      passphrases: [keys.entry],
    );

    final moved = await HiddenMigration(
      targetsStore: targets,
      vaultStore: store,
      bucket: bucket,
      passphrases: () async => [keys.entry],
      ops: remote,
    ).run(keys);

    expect(moved, 1);
    final entry = (await bucket.readAlbum(keys)).entries.single;
    expect(nameBelongsTo(entry.objectKey, keys.carrier.macKey), isTrue);
    expect(remote.objects.containsKey('photos-vault/$oldKey'), isFalse);
    expect(
      remote.objects.containsKey('photos-vault/${entry.objectKey}'),
      isTrue,
    );
    expect(await store.hasCarrier(keys, entry.objectKey), isTrue);
    expect(await store.hasCarrier(keys, oldKey), isFalse);
  });
}
