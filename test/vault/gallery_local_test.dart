import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:photos_vault/settings/backup_targets_store.dart';
import 'package:photos_vault/settings/secure_store.dart';
import 'package:photos_vault/vault/album_index.dart';
import 'package:photos_vault/vault/bucket.dart';
import 'package:photos_vault/vault/carrier.dart';
import 'package:photos_vault/vault/cipher.dart';
import 'package:photos_vault/vault/gallery.dart';
import 'package:photos_vault/vault/keys.dart';
import 'package:photos_vault/vault/store.dart';

import 'carrier_fixtures.dart';

class _MemoryStore implements SecureStore {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}

AlbumKeys _keys() => AlbumKeys(
  albumKey: Uint8List.fromList(List.generate(32, (i) => i)),
  entry: PassphraseEntry(
    id: 'e1',
    salt: Uint8List(16),
    verifier: Uint8List(32),
    hint: 'hint',
  ),
);

const _key = 'originals/photo_1.jpg';

void main() {
  final cipher = PlatformCipher();
  final thumbnail = Uint8List.fromList(List.generate(20000, (i) => i % 251));
  final original = Uint8List.fromList(List.generate(400000, (i) => i % 253));

  late Directory tempDir;
  late Map<String, Uint8List> objects;
  late int remoteReads;
  late VaultStore store;
  late VaultBucket bucket;
  late AlbumKeys keys;

  Uint8List carrierBytes() => buildJpegCarrier(
    cipher: cipher,
    keys: keys.carrier,
    masterSalt: keys.entry.salt,
    decoy: decoyJpeg(),
    thumbnail: thumbnail,
    original: original,
    extension: 'heic',
  )!;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('pv_gallery_');
    objects = {};
    remoteReads = 0;
    keys = _keys();
    store = VaultStore(
      directory: () async => tempDir,
      exclusion: const _NoExclusion(),
    );
    final targets = BackupTargetsStore(store: _MemoryStore());
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
      put: (url, {body}) async {
        objects[url.path] = body is List<int>
            ? Uint8List.fromList(body)
            : Uint8List(0);
        return http.Response('', 200);
      },
      get: (url, {headers}) async {
        remoteReads++;
        // Matched by suffix: whether a presigned URL is path-style or
        // virtual-host-style depends on the provider, and this test is about
        // which object was asked for, not how the host was spelled.
        final bytes = objects.entries
            .where((e) => url.path.endsWith(e.key))
            .map((e) => e.value)
            .firstOrNull;
        if (bytes == null) return http.Response('', 404);
        final range = headers?['Range'];
        if (range == null) return http.Response.bytes(bytes, 200);
        final end = int.parse(range.split('-').last);
        return http.Response.bytes(
          bytes.sublist(0, end + 1 > bytes.length ? bytes.length : end + 1),
          206,
        );
      },
    );
  });
  tearDown(() => tempDir.deleteSync(recursive: true));

  VaultGallery galleryOver() =>
      VaultGallery(keys: keys, bucket: bucket, store: store);

  IndexEntry entry() => IndexEntry(
    objectKey: _key,
    takenAt: DateTime(2026, 2, 3),
    width: 4032,
    height: 3024,
    isVideo: false,
    name: 'IMG_1',
  );

  test('a tile comes off the local carrier, with no network at all', () async {
    await store.putCarrierBytes(keys, _key, carrierBytes());

    final tile = await galleryOver().thumbnail(_key);

    expect(tile, equals(thumbnail));
    expect(remoteReads, 0, reason: 'the phone already had it');
  });

  test('the photo itself comes off the local carrier too', () async {
    await store.putCarrierBytes(keys, _key, carrierBytes());

    final bytes = await galleryOver().original(entry());

    expect(bytes, equals(original));
    expect(remoteReads, 0);
  });

  test('a bucket that will not answer is not an empty album', () async {
    // The listing was mirrored locally the last time a bucket answered, so
    // an album opens offline. Falling back to "no index" would read as
    // everything having been deleted.
    final gallery = galleryOver();
    await bucket.writeAlbum(
      keys: keys,
      entries: [entry()],
      passphrases: [keys.entry],
    );
    expect((await gallery.list()).single.objectKey, _key);

    objects.clear();
    expect((await galleryOver().list()).single.objectKey, _key);
  });

  test('editing an album offline keeps every other album intact', () async {
    // The rewrite merges into the index as it stands — which offline is the
    // local mirror. Building on "no index" instead would hand back 32
    // sections of fresh noise, with every other album gone.
    final other = AlbumKeys(
      albumKey: Uint8List.fromList(List.generate(32, (i) => 255 - i)),
      entry: PassphraseEntry(
        id: 'e2',
        salt: Uint8List(16),
        verifier: Uint8List(32),
        hint: 'other',
      ),
    );
    await bucket.writeAlbum(
      keys: other,
      entries: [
        IndexEntry(
          objectKey: 'originals/other.jpg',
          takenAt: DateTime(2025),
          width: 1,
          height: 1,
          isVideo: false,
          name: 'OTHER',
        ),
      ],
      passphrases: [other.entry],
    );
    objects.clear(); // offline from here

    final index = await bucket.encodeAlbum(
      keys: keys,
      entries: [entry()],
      passphrases: [keys.entry],
    );
    await store.writeIndex(index!);

    expect((await galleryOver().list()).single.objectKey, _key);
    expect(
      (await VaultGallery(
        keys: other,
        bucket: bucket,
        store: store,
      ).list()).single.objectKey,
      'originals/other.jpg',
    );
  });

  test('which photos are here is answerable without asking a bucket', () async {
    await store.putCarrierBytes(keys, _key, carrierBytes());
    final absent = IndexEntry(
      objectKey: 'originals/away.jpg',
      takenAt: DateTime(2026),
      width: 1,
      height: 1,
      isVideo: false,
      name: 'AWAY',
    );

    final held = await galleryOver().localKeys([entry(), absent]);

    expect(held, {_key});
  });

  test('sending one back keeps the tile and frees the photo', () async {
    final carrier = carrierBytes();
    await store.putCarrierBytes(keys, _key, carrier);
    objects['photos/$_key'] = carrier;

    final gallery = galleryOver();
    expect(await gallery.sendBackToBucket(entry()), isTrue);

    expect(await store.hasCarrier(keys, _key), isFalse);
    // A fresh gallery, so nothing is being answered out of memory: the tile
    // still draws, from the thumbnail that was kept in its place.
    expect(await galleryOver().thumbnail(_key), equals(thumbnail));
  });

  test(
    'it refuses to free a photo the bucket cannot be shown to have',
    () async {
      // This app's copy is the only one until something else holds it, and
      // "free up space" must never be how a hidden photo stops existing.
      await store.putCarrierBytes(keys, _key, carrierBytes());

      expect(await galleryOver().sendBackToBucket(entry()), isFalse);
      expect(await store.hasCarrier(keys, _key), isTrue);
    },
  );

  test('downloading one puts it back on the phone', () async {
    objects['photos/$_key'] = carrierBytes();

    expect(await galleryOver().download(entry()), isTrue);

    expect(await store.hasCarrier(keys, _key), isTrue);
    expect(await galleryOver().original(entry()), equals(original));
  });

  test('a download that is not this album\'s carrier is not kept', () async {
    // Somebody else's object, or a truncated download. Storing it would
    // leave a photo that claims to be here and opens as nothing.
    objects['photos/$_key'] = decoyJpeg();

    expect(await galleryOver().download(entry()), isFalse);
    expect(await store.hasCarrier(keys, _key), isFalse);
  });
}

class _NoExclusion extends BackupExclusion {
  const _NoExclusion();

  @override
  Future<bool> exclude(String path) async => true;
}
