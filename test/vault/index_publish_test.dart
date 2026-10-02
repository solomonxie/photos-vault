import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:photos_vault/settings/backup_targets_store.dart';
import 'package:photos_vault/settings/secure_store.dart';
import 'package:photos_vault/vault/album_index.dart';
import 'package:photos_vault/vault/bucket.dart';
import 'package:photos_vault/vault/keys.dart';
import 'package:photos_vault/vault/store.dart';

class _MemoryStore implements SecureStore {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}

void main() {
  late Map<String, Uint8List> objects;
  late bool offline;
  late Directory dir;
  late VaultStore store;
  late VaultBucket bucket;

  final keys = AlbumKeys(
    albumKey: Uint8List.fromList(List.generate(32, (i) => i)),
    entry: PassphraseEntry(
      id: 'e1',
      salt: Uint8List(16),
      verifier: Uint8List(32),
      hint: 'hint',
    ),
  );

  IndexEntry entry(String name) => IndexEntry(
    objectKey: 'originals/$name.jpg',
    takenAt: DateTime(2026),
    width: 1,
    height: 1,
    isVideo: false,
  );

  setUp(() async {
    objects = {};
    offline = false;
    dir = Directory.systemTemp.createTempSync('pv_index_publish_');
    store = VaultStore(directory: () async => dir);
    final targets = BackupTargetsStore(store: _MemoryStore());
    await targets.add(
      accessKeyId: 'AKIAIOSFODNN7EXAMPLE',
      secretAccessKey: 'secret',
      region: 'us-east-1',
      bucket: 'my-bucket',
      prefix: '',
    );
    bucket = VaultBucket(
      targetsStore: targets,
      store: store,
      put: (url, {body}) async {
        if (offline) throw const SocketException('offline');
        objects[url.path] = Uint8List.fromList(body as List<int>);
        return http.Response('', 200);
      },
      get: (url, {headers}) async {
        if (offline) throw const SocketException('offline');
        final bytes = objects[url.path];
        if (bytes == null) return http.Response('', 404);
        return http.Response.bytes(bytes, 200);
      },
    );
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('an index written offline is not replaced by the older bucket copy, '
      'and reaches the bucket once it answers', () async {
    await bucket.writeAlbum(
      keys: keys,
      entries: [entry('a')],
      passphrases: [keys.entry],
    );

    offline = true;
    final wrote = await bucket.writeAlbum(
      keys: keys,
      entries: [entry('a'), entry('b')],
      passphrases: [keys.entry],
    );
    expect(wrote, isFalse);
    expect(await store.isIndexUnpublished(), isTrue);

    offline = false;
    final album = await bucket.readAlbum(keys);
    expect(album.entries.map((e) => e.objectKey), [
      'originals/a.jpg',
      'originals/b.jpg',
    ]);
    expect(await store.isIndexUnpublished(), isFalse);
    expect(objects.values.single, await store.readIndex());
  });

  test('a published index defers to the bucket again', () async {
    await bucket.writeAlbum(
      keys: keys,
      entries: [entry('a')],
      passphrases: [keys.entry],
    );
    expect(await store.isIndexUnpublished(), isFalse);

    // Another phone's write.
    final other = VaultBucket(
      targetsStore: BackupTargetsStore(store: _MemoryStore()),
      store: VaultStore(
        directory: () async =>
            Directory.systemTemp.createTempSync('pv_index_other_'),
      ),
    );
    final theirs = await other.encodeAlbum(
      keys: keys,
      entries: [entry('c')],
      passphrases: [keys.entry],
    );
    objects[objects.keys.single] = theirs!;

    expect(
      (await bucket.readAlbum(keys)).entries.single.objectKey,
      'originals/c.jpg',
    );
  });
}
