import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:photos_vault/settings/backup_targets_store.dart';
import 'package:photos_vault/settings/s3_backup_target.dart';
import 'package:photos_vault/upload/pending_deletes.dart';
import 'package:photos_vault/upload/s3_uploader.dart';
import 'package:photos_vault/vault/album_index.dart';
import 'package:photos_vault/vault/bucket.dart';
import 'package:photos_vault/vault/carrier.dart';
import 'package:photos_vault/vault/cipher.dart';
import 'package:photos_vault/vault/gallery.dart';
import 'package:photos_vault/vault/hidden_removal.dart';
import 'package:photos_vault/vault/hidden_restore.dart';
import 'package:photos_vault/vault/keys.dart';
import 'package:photos_vault/vault/store.dart';

import '../settings/fake_secure_store.dart';
import '../support/fake_asset_record_store.dart';
import 'carrier_fixtures.dart';

AlbumKeys _keys() => AlbumKeys(
  albumKey: Uint8List.fromList(List.generate(32, (i) => i)),
  entry: PassphraseEntry(
    id: 'e1',
    salt: Uint8List(16),
    verifier: Uint8List(32),
    hint: '',
  ),
);

class _NoExclusion extends BackupExclusion {
  const _NoExclusion();

  @override
  Future<bool> exclude(String path) async => true;
}

class _Uploader implements S3Uploader {
  final puts = <String>[];

  @override
  Future<bool> put({
    required String filePath,
    required String key,
    required S3BackupTarget target,
  }) async {
    puts.add(key);
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

typedef _Saved = ({List<int> still, List<int>? motion, DateTime createdAt});

const _still = 'originals/photo_a.jpg';
const _motion = 'originals/photo_a.mov';

void main() {
  final cipher = PlatformCipher();
  final keys = _keys();
  final original = Uint8List.fromList(List.generate(5000, (i) => i % 251));
  final movie = Uint8List.fromList(List.generate(3000, (i) => i % 241));

  late Directory tempDir;
  late Map<String, Uint8List> objects;
  late bool online;
  late VaultStore store;
  late VaultBucket bucket;
  late _Uploader uploader;
  late VaultGallery gallery;
  late List<_Saved> saved;
  late HiddenRestore restore;

  Uint8List carrier(Uint8List payload, String extension) => buildJpegCarrier(
    cipher: cipher,
    keys: keys.carrier,
    masterSalt: keys.entry.salt,
    decoy: decoyJpeg(),
    thumbnail: Uint8List.fromList(List.generate(500, (i) => i % 7)),
    original: payload,
    extension: extension,
  )!;

  final entry = IndexEntry(
    objectKey: _still,
    takenAt: DateTime(2019, 5, 6),
    width: 1,
    height: 1,
    isVideo: false,
  );

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('pv_restore_');
    objects = {};
    online = true;
    saved = [];
    uploader = _Uploader();
    store = VaultStore(
      directory: () async => tempDir,
      exclusion: const _NoExclusion(),
    );
    final targets = BackupTargetsStore(store: FakeSecureStore());
    await targets.add(
      accessKeyId: 'AKIAIOSFODNN7EXAMPLE',
      secretAccessKey: 'secret',
      region: 'us-east-1',
      bucket: 'my-bucket',
      prefix: 'photos/',
    );
    bucket = VaultBucket(
      targetsStore: targets,
      store: store,
      uploader: uploader,
      put: (url, {body}) async {
        objects[url.path] = Uint8List.fromList(body as List<int>);
        return http.Response('', 200);
      },
      get: (url, {headers}) async {
        if (!online) throw const SocketException('offline');
        final bytes = objects.entries
            .where((e) => url.path.endsWith(e.key))
            .map((e) => e.value)
            .firstOrNull;
        return bytes == null
            ? http.Response('', 404)
            : http.Response.bytes(bytes, 200);
      },
    );
    gallery = VaultGallery(keys: keys, bucket: bucket, store: store);
    restore = HiddenRestore(
      gallery: gallery,
      temporaryDirectory: () => tempDir.createTemp('t'),
      saveFiles:
          ({
            required File still,
            File? motion,
            required bool isVideo,
            required DateTime createdAt,
          }) async {
            saved.add((
              still: still.readAsBytesSync(),
              motion: motion?.readAsBytesSync(),
              createdAt: createdAt,
            ));
            return 'NEW-ID';
          },
    );
  });
  tearDown(() => tempDir.deleteSync(recursive: true));

  test('a filed still goes back to Photos with its own date', () async {
    await store.putCarrierBytes(keys, _still, carrier(original, 'heic'));

    expect(await restore.restore(entry), 'photo:NEW-ID');
    expect(saved.single.still, original);
    expect(saved.single.motion, isNull);
    expect(saved.single.createdAt, DateTime(2019, 5, 6));
  });

  test('a Live Photo goes back moving', () async {
    await store.putCarrierBytes(keys, _still, carrier(original, 'heic'));
    await store.putCarrierBytes(keys, _motion, carrier(movie, 'mov'));

    await restore.restore(entry);

    expect(saved.single.motion, movie);
  });

  test('motion that can only be fetched later is not dropped', () async {
    await store.putCarrierBytes(keys, _still, carrier(original, 'heic'));
    online = false;

    expect(await restore.restore(entry), isNull);
    expect(saved, isEmpty);
  });

  test('released carriers leave the index and this phone, and the '
      "bucket's copies wait for the plain upload", () async {
    final records = FakeAssetRecordStore();
    await bucket.writeAlbum(
      keys: keys,
      entries: [entry],
      passphrases: [keys.entry],
    );
    await store.putCarrierBytes(keys, _still, carrier(original, 'heic'));
    final targets = BackupTargetsStore(store: FakeSecureStore());
    await targets.add(
      accessKeyId: 'AKIAIOSFODNN7EXAMPLE',
      secretAccessKey: 'secret',
      region: 'us-east-1',
      bucket: 'my-bucket',
      prefix: 'photos/',
    );
    final removal = HiddenRemoval(
      store: records,
      targetsStore: targets,
      vaultStore: store,
      bucket: bucket,
      pendingDeletes: PendingDeletes(
        store: records,
        delete: ({required S3BackupTarget target, required String key}) async =>
            true,
      ),
    );

    expect(
      await removal.release(keys: keys, plainIds: {_still: 'photo:NEW-ID'}),
      isTrue,
    );

    expect((await bucket.readAlbum(keys)).entries, isEmpty);
    expect(await store.hasCarrier(keys, _still), isFalse);
    final waiting = await DeferredDeletes(store: records).waiting();
    expect(
      waiting['photo:NEW-ID']!.map((t) => t.objectKey),
      containsAll(['photos/$_still', 'photos/$_motion']),
    );
    expect(await PendingDeletes(store: records).pending(), isEmpty);
  });

  test('a carrier filed with no bucket goes up once one exists', () async {
    await store.putCarrierBytes(keys, _still, carrier(original, 'heic'));
    await store.setUnsent(keys, _still, true);

    expect(await gallery.sendUnsent([entry]), 1);
    expect(uploader.puts, ['photos/$_still']);
    expect(await store.isUnsent(keys, _still), isFalse);

    expect(await gallery.sendUnsent([entry]), 0);
  });

  test('a still the index marks motionless un-hides offline', () async {
    await store.putCarrierBytes(keys, _still, carrier(original, 'heic'));
    online = false;
    final still = IndexEntry(
      objectKey: _still,
      takenAt: DateTime(2019, 5, 6),
      width: 1,
      height: 1,
      isVideo: false,
      hasMotion: false,
    );

    expect(await restore.restore(still), 'photo:NEW-ID');
    expect(saved.single.motion, isNull);
  });

  test('the motion flag survives the index round trip, and old entries '
      'read as unknown', () {
    final json = IndexEntry(
      objectKey: _still,
      takenAt: DateTime(2019),
      width: 1,
      height: 1,
      isVideo: false,
      hasMotion: true,
    ).toJson();
    expect(IndexEntry.fromJson(json).hasMotion, isTrue);
    expect(IndexEntry.fromJson({...json}..remove('m')).hasMotion, isNull);
  });

  test('a sealed unsent carrier goes up with no album open', () async {
    final outbox = Uint8List.fromList(List.generate(32, (i) => 200 - i));
    final sealing = AlbumKeys(
      albumKey: keys.albumKey,
      entry: keys.entry,
      outboxKey: outbox,
    );
    await store.putCarrierBytes(keys, _still, carrier(original, 'heic'));
    await store.setUnsent(sealing, _still, true);

    final sent = await store.sendUnsent(
      outboxKey: (id) async => id == keys.entry.id ? outbox : null,
      put: bucket.putEverywhere,
    );

    expect(sent, 1);
    expect(uploader.puts, ['photos/$_still']);
    expect(await store.isUnsent(keys, _still), isFalse);
  });

  test('a marker it cannot open waits for its album', () async {
    await store.putCarrierBytes(keys, _still, carrier(original, 'heic'));
    // Legacy bare marker: no outbox key when it was written.
    await store.setUnsent(keys, _still, true);

    final sent = await store.sendUnsent(
      outboxKey: (_) async => Uint8List(32),
      put: bucket.putEverywhere,
    );

    expect(sent, 0);
    expect(uploader.puts, isEmpty);
    expect(await store.isUnsent(keys, _still), isTrue);
  });
}
