import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:photos_vault/settings/backup_targets_store.dart';
import 'package:photos_vault/settings/secure_store.dart';
import 'package:photos_vault/vault/album_index.dart';
import 'package:photos_vault/vault/bucket.dart';
import 'package:photos_vault/vault/cipher.dart';
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

class _NoExclusion extends BackupExclusion {
  const _NoExclusion();

  @override
  Future<bool> exclude(String path) async => true;
}

/// Buckets as maps of path → bytes. [down] makes one answer nothing.
class _Buckets {
  final objects = <String, Uint8List>{};
  final down = <String>{};
  var puts = 0;

  Future<http.Response> put(Uri url, {Object? body}) async {
    if (down.any(url.toString().contains)) {
      throw const SocketException('offline');
    }
    puts++;
    objects['${url.host}${url.path}'] = Uint8List.fromList(body as List<int>);
    return http.Response('', 200);
  }

  Future<http.Response> get(Uri url, {Map<String, String>? headers}) async {
    if (down.any(url.toString().contains)) {
      throw const SocketException('offline');
    }
    final bytes = objects['${url.host}${url.path}'];
    if (bytes == null) return http.Response('', 404);
    return http.Response.bytes(bytes, 200);
  }

  Uint8List? indexOf(String bucket) => objects.entries
      .where((e) => e.key.contains(bucket) && e.key.endsWith(indexObjectName))
      .firstOrNull
      ?.value;
}

/// One phone: its own keychain and vault directory, the shared buckets.
class _Phone {
  _Phone(this.buckets, this.targets, this.dir)
    : keychain = _MemoryStore(),
      store = VaultStore(
        directory: () async => dir,
        exclusion: const _NoExclusion(),
      );

  final _Buckets buckets;
  final BackupTargetsStore targets;
  final Directory dir;
  final _MemoryStore keychain;
  final VaultStore store;

  late final keys = VaultKeys(store: keychain);
  late final bucket = VaultBucket(
    targetsStore: targets,
    store: store,
    put: buckets.put,
    get: buckets.get,
  );
}

void main() {
  late _Buckets buckets;
  late BackupTargetsStore targets;
  late List<Directory> dirs;

  Future<void> addBucket(String name) => targets.add(
    accessKeyId: 'AKIAIOSFODNN7EXAMPLE',
    secretAccessKey: 'secret',
    region: 'us-east-1',
    bucket: name,
    prefix: '',
  );

  _Phone phone() {
    final dir = Directory.systemTemp.createTempSync('pv_index_recovery_');
    dirs.add(dir);
    return _Phone(buckets, targets, dir);
  }

  IndexEntry entry(String name) => IndexEntry(
    objectKey: 'originals/$name.jpg',
    takenAt: DateTime(2026),
    width: 1,
    height: 1,
    isVideo: false,
  );

  setUp(() async {
    buckets = _Buckets();
    targets = BackupTargetsStore(store: _MemoryStore());
    dirs = [];
    await addBucket('bucket-a');
  });
  tearDown(() {
    for (final dir in dirs) {
      dir.deleteSync(recursive: true);
    }
  });

  test('an install with nothing hidden still leaves an index, and a new '
      'phone typing the old passphrase opens the old album', () async {
    final old = phone();
    expect(await old.bucket.ensurePublished(const []), isTrue);
    expect(isWholeIndex(buckets.indexOf('bucket-a')), isTrue);

    // Setup on the old phone, then a photo listed in the album.
    await old.keys.setUp(
      'the old passphrase',
      known: await old.bucket.knownPassphrases(),
    );
    expect(await old.bucket.ensurePublished(await old.keys.entries()), isTrue);
    final oldAlbum = (await old.keys.albumKeys('1234')).single;
    await old.bucket.writeAlbum(
      keys: oldAlbum,
      entries: [entry('a')],
      passphrases: await old.keys.entries(),
    );

    // A new phone: nothing in its keychain or vault, only the bucket.
    final fresh = phone();
    final known = await fresh.bucket.knownPassphrases();
    expect(known.map((e) => e.id), [oldAlbum.entry.id]);
    await fresh.keys.setUp('the old passphrase', known: known);
    final album = (await fresh.keys.albumKeys('1234')).single;
    expect(album.albumKey, oldAlbum.albumKey);
    expect(
      (await fresh.bucket.readAlbum(album)).entries.single.objectKey,
      'originals/a.jpg',
    );
  });

  test('publishing only adds: other albums and older entries stay', () async {
    final old = phone();
    await old.keys.add('the old passphrase');
    final oldAlbum = (await old.keys.albumKeys('1234')).single;
    await old.bucket.writeAlbum(
      keys: oldAlbum,
      entries: [entry('a')],
      passphrases: await old.keys.entries(),
    );

    // A phone that set up before it ever saw the bucket.
    final other = phone();
    await other.keys.add('a different one');
    expect(
      await other.bucket.ensurePublished(await other.keys.entries()),
      isTrue,
    );

    final header = passphrasesIn(buckets.indexOf('bucket-a')!);
    expect(header.map((e) => e.id), [
      oldAlbum.entry.id,
      (await other.keys.entries()).single.id,
    ]);
    expect(
      (await old.bucket.readAlbum(oldAlbum)).entries.single.objectKey,
      'originals/a.jpg',
    );

    // A rewrite that names only its own entry keeps the others too.
    final otherAlbum = (await other.keys.albumKeys('1111')).single;
    await other.bucket.writeAlbum(
      keys: otherAlbum,
      entries: [entry('b')],
      passphrases: await other.keys.entries(),
    );
    expect(passphrasesIn(buckets.indexOf('bucket-a')!), hasLength(2));
  });

  test('first contact is checked once per bucket and set of entries', () async {
    final p = phone();
    await p.keys.add('the passphrase');
    await p.bucket.ensurePublished(await p.keys.entries());
    final writes = buckets.puts;

    await p.bucket.ensurePublished(await p.keys.entries());
    expect(buckets.puts, writes);

    await addBucket('bucket-b');
    await p.bucket.ensurePublished(await p.keys.entries());
    expect(buckets.indexOf('bucket-b'), buckets.indexOf('bucket-a'));
  });

  test('a new bucket is not given a blank index while another bucket that '
      'may hold one does not answer', () async {
    final p = phone();
    await p.keys.add('the passphrase');
    await p.bucket.ensurePublished(await p.keys.entries());
    final album = (await p.keys.albumKeys('1234')).single;
    await p.bucket.writeAlbum(
      keys: album,
      entries: [entry('a')],
      passphrases: await p.keys.entries(),
    );

    // Another phone, no mirror of its own; bucket A is unreachable.
    final fresh = phone();
    await addBucket('bucket-b');
    buckets.down.add('bucket-a');
    expect(await fresh.bucket.ensurePublished(const []), isFalse);
    expect(buckets.indexOf('bucket-b'), isNull);

    buckets.down.clear();
    expect(await fresh.bucket.ensurePublished(const []), isTrue);
    expect(buckets.indexOf('bucket-b'), buckets.indexOf('bucket-a'));
  });

  test('a torn index is never pushed, and a torn bucket copy is never read '
      'or overwritten', () async {
    final p = phone();
    await p.keys.add('the passphrase');
    final album = (await p.keys.albumKeys('1234')).single;
    await p.bucket.writeAlbum(
      keys: album,
      entries: [entry('a')],
      passphrases: await p.keys.entries(),
    );
    final published = buckets.indexOf('bucket-a')!;

    // Killed mid-write with an unpublished edit pending.
    await p.store.setIndexUnpublished(true);
    File('${dirs.first.path}/${VaultStore.root}/${VaultStore.indexFileName}')
        .writeAsBytesSync(Uint8List.sublistView(published, 0, 4096));
    expect(await p.bucket.currentIndex(), published);
    expect(buckets.indexOf('bucket-a'), published);

    final torn = Uint8List.sublistView(published, 0, indexBytes - 1);
    expect(await p.bucket.saveIndex(torn), isFalse);
    expect(await p.bucket.publishIndex(torn), isFalse);
    expect(buckets.indexOf('bucket-a'), published);

    // The bucket's own copy torn: skipped, and not replaced by a blank one.
    final key = buckets.objects.keys.single;
    buckets.objects[key] = Uint8List.fromList(torn);
    final fresh = phone();
    expect(await fresh.bucket.loadIndex(), isNull);
    expect(await fresh.bucket.ensurePublished(const []), isFalse);
    expect(buckets.objects[key], torn);
  });

  test('writing a section into a short index never drops its entries', () {
    final cipher = PlatformCipher();
    final keys = AlbumKeys(
      albumKey: Uint8List.fromList(List.generate(32, (i) => i)),
      entry: PassphraseEntry(
        id: 'e1',
        salt: Uint8List(16),
        verifier: Uint8List(32),
        hint: 'h',
      ),
    );
    final whole = emptyIndex(passphrases: [keys.entry]);
    final short = Uint8List.sublistView(whole, 0, 20000);
    final written = writeSection(
      cipher: cipher,
      keys: keys,
      index: short,
      entries: [entry('a')],
      passphrases: const [],
    );
    expect(isWholeIndex(written), isTrue);
    expect(passphrasesIn(written).single.id, 'e1');
  });
}
