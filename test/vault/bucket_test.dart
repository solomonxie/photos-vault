import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:photos_vault/settings/backup_targets_store.dart';
import 'package:photos_vault/settings/s3_backup_target.dart';
import 'package:photos_vault/settings/secure_store.dart';
import 'package:photos_vault/vault/album_index.dart';
import 'package:photos_vault/vault/bucket.dart';
import 'package:photos_vault/vault/keys.dart';

class _MemoryStore implements SecureStore {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}

const _target = S3BackupTarget(
  id: 't1',
  accessKeyId: 'AKIAIOSFODNN7EXAMPLE',
  secretAccessKey: 'secret',
  region: 'us-east-1',
  bucket: 'my-bucket',
  prefix: '',
);

void main() {
  late Map<String, Uint8List> objects;
  late List<String> ranges;
  late VaultBucket bucket;

  setUp(() async {
    objects = {};
    ranges = [];
    final store = BackupTargetsStore(store: _MemoryStore());
    await store.add(
      accessKeyId: _target.accessKeyId,
      secretAccessKey: _target.secretAccessKey,
      region: _target.region,
      bucket: _target.bucket,
      prefix: _target.prefix,
    );
    bucket = VaultBucket(
      targetsStore: store,
      put: (url, {body}) async {
        objects[url.path] = body is List<int>
            ? Uint8List.fromList(body)
            : Uint8List(0);
        return http.Response('', 200);
      },
      get: (url, {headers}) async {
        if (headers?['Range'] != null) ranges.add(headers!['Range']!);
        final bytes = objects[url.path];
        if (bytes == null) return http.Response('', 404);
        final range = headers?['Range'];
        if (range == null) {
          return http.Response.bytes(bytes, 200);
        }
        final end = int.parse(range.split('-').last);
        return http.Response.bytes(
          bytes.sublist(0, end + 1 > bytes.length ? bytes.length : end + 1),
          206,
        );
      },
    );
  });

  AlbumKeys keysFor(int seed) => AlbumKeys(
    albumKey: Uint8List.fromList(List.generate(32, (i) => (i + seed) % 256)),
    entry: PassphraseEntry(
      id: 'e$seed',
      salt: Uint8List(16),
      verifier: Uint8List(32),
      hint: 'hint $seed',
    ),
  );

  test('an album round trips through the bucket', () async {
    final keys = keysFor(1);
    final wrote = await bucket.writeAlbum(
      keys: keys,
      entries: [
        IndexEntry(
          objectKey: 'originals/a.jpg',
          takenAt: DateTime(2026, 2, 3),
          width: 4032,
          height: 3024,
          isVideo: false,
          name: 'IMG_1',
        ),
      ],
      passphrases: [keys.entry],
    );
    expect(wrote, isTrue);

    final album = await bucket.readAlbum(keys);
    expect(album.entries.single.objectKey, 'originals/a.jpg');
    expect(album.passphrases.single.hint, 'hint 1');
  });

  test('the index object is the same size whatever is in it', () async {
    final keys = keysFor(1);
    await bucket.saveIndex(emptyIndex());
    final empty = objects.values.single.length;

    await bucket.writeAlbum(
      keys: keys,
      entries: [
        for (var i = 0; i < 300; i++)
          IndexEntry(
            objectKey: 'originals/$i.jpg',
            takenAt: DateTime(2026),
            width: 4032,
            height: 3024,
            isVideo: false,
          ),
      ],
      passphrases: [keys.entry],
    );
    expect(objects.values.single.length, empty);
    expect(empty, indexBytes);
  });

  test('another album key reads an empty album, not an error', () async {
    final mine = keysFor(1);
    await bucket.writeAlbum(
      keys: mine,
      entries: [
        IndexEntry(
          objectKey: 'originals/a.jpg',
          takenAt: DateTime(2026),
          width: 1,
          height: 1,
          isVideo: false,
        ),
      ],
      passphrases: [mine.entry],
    );
    expect((await bucket.readAlbum(keysFor(9))).entries, isEmpty);
  });

  test('a grid tile asks for 64 KB, not the whole object', () async {
    objects['/originals/a.jpg'] = Uint8List(200 * 1024);
    final prefix = await bucket.thumbnailPrefix('originals/a.jpg');
    expect(prefix!.length, 64 * 1024);
    expect(ranges.single, 'bytes=0-65535');
  });

  test('no index in the bucket is not an empty album', () async {
    expect(await bucket.loadIndex(), isNull);
  });
}
