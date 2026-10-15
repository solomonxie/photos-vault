import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:photos_vault/settings/backup_targets_store.dart';
import 'package:photos_vault/storage/asset_record.dart';
import 'package:photos_vault/vault/album_index.dart';
import 'package:photos_vault/vault/bucket.dart';
import 'package:photos_vault/vault/carrier.dart';
import 'package:photos_vault/vault/cipher.dart';
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
  const still = 'originals/photo_old_L0_001.jpg';
  const motion = 'originals/photo_old_L0_001.mov';
  final motionBytes = Uint8List.fromList(List.generate(3000, (i) => i % 97));

  late Directory dir;
  late BackupTargetsStore targets;
  late MemoryBucket remote;
  late VaultStore store;
  late VaultBucket bucket;

  Uint8List carrier() => buildJpegCarrier(
    cipher: PlatformCipher(),
    keys: keys.carrier,
    masterSalt: keys.entry.salt,
    decoy: decoyJpeg(),
    thumbnail: Uint8List.fromList(List.generate(3000, (i) => i % 200)),
    original: Uint8List.fromList(List.generate(20000, (i) => i % 250)),
    extension: 'jpg',
    nonce: hiddenNonce(
      keys.carrier,
      AssetRecord(
        localId: 'photo:old',
        contentHash: 'h',
        platform: 'ios',
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      ),
    ),
    meta: CarrierMeta(
      takenAt: DateTime(2023),
      width: 30,
      height: 40,
      isVideo: false,
    ),
  )!;

  Future<void> file() => bucket.writeAlbum(
    keys: keys,
    entries: [
      IndexEntry(
        objectKey: still,
        takenAt: DateTime(2023),
        width: 30,
        height: 40,
        isVideo: false,
        hasMotion: true,
      ),
    ],
    passphrases: [keys.entry],
  );

  Future<int> migrate() => HiddenMigration(
    targetsStore: targets,
    vaultStore: store,
    bucket: bucket,
    passphrases: () async => [keys.entry],
    recordStore: FakeAssetRecordStore(),
    ops: remote,
  ).run(keys);

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('pv_migrate_');
    targets = BackupTargetsStore(store: FakeSecureStore());
    await targets.add(
      accessKeyId: 'k',
      secretAccessKey: 's',
      region: 'us-east-1',
      bucket: 'one',
      prefix: 'a/',
    );
    await targets.add(
      accessKeyId: 'k',
      secretAccessKey: 's',
      region: 'us-east-1',
      bucket: 'two',
      prefix: 'b/',
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

  test('each bucket loses an old name only where the new one is proven; '
      'a 404 there is nothing to move', () async {
    final bytes = carrier();
    remote.objects['a/$still'] = bytes;
    remote.objects['a/$motion'] = motionBytes;
    remote.objects['b/$still'] = bytes;
    await file();

    expect(await migrate(), 1);

    final moved = (await bucket.readAlbum(keys)).entries.single.objectKey;
    final movedMotion = '${moved.substring(0, moved.lastIndexOf('.'))}.mov';
    expect(
      remote.objects.keys,
      unorderedEquals(['a/$moved', 'a/$movedMotion', 'b/$moved']),
    );
    expect(
      remote.deleted,
      unorderedEquals(['a/$still', 'a/$motion', 'b/$still']),
    );
  });

  test('a bucket that does not answer for the motion half holds the whole '
      'photo back, everywhere', () async {
    final bytes = carrier();
    remote.objects['a/$still'] = bytes;
    remote.objects['a/$motion'] = motionBytes;
    remote.objects['b/$still'] = bytes;
    remote.objects['b/$motion'] = motionBytes;
    remote.silent.add('b/$motion');
    await file();

    expect(await migrate(), 0);

    expect(remote.deleted, isEmpty);
    expect(remote.objects, contains('a/$motion'));
    expect(remote.objects, contains('b/$motion'));
    expect((await bucket.readAlbum(keys)).entries.single.objectKey, still);
  });
}
