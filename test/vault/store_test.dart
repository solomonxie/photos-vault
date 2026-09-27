import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/vault/carrier.dart';
import 'package:photos_vault/vault/keys.dart';
import 'package:photos_vault/vault/store.dart';

import 'carrier_fixtures.dart';

AlbumKeys _keysFor(int seed) => AlbumKeys(
  albumKey: Uint8List.fromList(List.generate(32, (i) => (i + seed) % 256)),
  entry: PassphraseEntry(
    id: 'e$seed',
    salt: Uint8List(16),
    verifier: Uint8List(32),
    hint: 'hint $seed',
  ),
);

/// Never reaches the platform channel: there is nothing to exclude in a
/// unit test, and the recorded calls are what the "set it on creation"
/// promise is checked against.
class _RecordingExclusion extends BackupExclusion {
  const _RecordingExclusion(this.paths);
  final List<String> paths;

  @override
  Future<bool> exclude(String path) async {
    paths.add(path);
    return true;
  }
}

void main() {
  late Directory tempDir;
  late List<String> excluded;
  late VaultStore store;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('pv_vault_store_');
    excluded = [];
    store = VaultStore(
      directory: () async => tempDir,
      exclusion: _RecordingExclusion(excluded),
    );
  });
  tearDown(() => tempDir.deleteSync(recursive: true));

  Future<File> carrierOnDisk(Uint8List bytes) async {
    final file = File('${tempDir.path}/incoming-${bytes.length}.jpg');
    await file.writeAsBytes(bytes);
    return file;
  }

  test(
    'the directory is taken out of the device backup when it is made',
    () async {
      await store.writeIndex(Uint8List.fromList([1, 2, 3]));

      expect(excluded, hasLength(1));
      expect(excluded.single, endsWith('/${VaultStore.root}'));
    },
  );

  test('a carrier goes in, comes back whole, and is byte-identical', () async {
    final keys = _keysFor(1);
    final bytes = decoyJpeg();
    await store.putCarrier(keys, 'originals/a.jpg', await carrierOnDisk(bytes));

    expect(await store.hasCarrier(keys, 'originals/a.jpg'), isTrue);
    expect(await store.readCarrier(keys, 'originals/a.jpg'), equals(bytes));
  });

  test(
    'stored as-is: the file on disk is the carrier, not a second cipher',
    () async {
      // It is already encrypted and already a real picture. A second layer
      // would mean the local copy and the bucket's copy were different files,
      // and neither could be checked against the other.
      final keys = _keysFor(1);
      final bytes = decoyJpeg();
      await store.putCarrierBytes(keys, 'originals/a.jpg', bytes);

      final file = await store.carrierFile(keys, 'originals/a.jpg');
      expect(await file.readAsBytes(), equals(bytes));
    },
  );

  test('a tile is read with a seek, not by loading the photo', () async {
    final keys = _keysFor(1);
    // Comfortably longer than the prefix, so a whole-file read would show.
    final bytes = Uint8List.fromList(
      List.generate(thumbnailPrefixBytes * 3, (i) => i % 251),
    );
    await store.putCarrierBytes(keys, 'originals/big.jpg', bytes);

    final prefix = await store.carrierPrefix(keys, 'originals/big.jpg');

    expect(prefix, hasLength(thumbnailPrefixBytes));
    expect(prefix, equals(bytes.sublist(0, thumbnailPrefixBytes)));
  });

  test('two albums name the same object differently', () async {
    // A directory listing must not say how many albums there are, or let
    // two of them be matched up by filename.
    final one = _keysFor(1);
    final two = _keysFor(2);
    await store.putCarrierBytes(one, 'originals/a.jpg', decoyJpeg());
    await store.putCarrierBytes(two, 'originals/a.jpg', decoyJpeg());

    expect(
      (await store.carrierFile(one, 'originals/a.jpg')).path,
      isNot((await store.carrierFile(two, 'originals/a.jpg')).path),
    );
    // And neither can read the other's.
    expect(await store.hasCarrier(one, 'originals/a.jpg'), isTrue);
    expect((await store.usage()).carriers, 2);
  });

  test('a thumbnail is encrypted, unlike the carrier', () async {
    final keys = _keysFor(1);
    final tile = Uint8List.fromList(List.generate(4096, (i) => i % 200));
    await store.writeThumbnail(keys, 'originals/a.jpg', tile);

    expect(await store.readThumbnail(keys, 'originals/a.jpg'), equals(tile));
    // Not the plaintext on disk: a thumbnail alone has no decoy around it.
    final onDisk = File(
      '${tempDir.path}/${VaultStore.root}/${VaultStore.thumbnailsDir}'
      '/${(await store.carrierFile(keys, 'originals/a.jpg')).uri.pathSegments.last}',
    );
    expect(await onDisk.exists(), isTrue);
    expect(await onDisk.readAsBytes(), isNot(equals(tile)));
    // And the wrong album key cannot read it.
    expect(await store.readThumbnail(_keysFor(2), 'originals/a.jpg'), isNull);
  });

  test(
    'sending one back to the bucket keeps the tile and drops the photo',
    () async {
      final keys = _keysFor(1);
      final tile = Uint8List.fromList(List.generate(2048, (i) => i % 200));
      await store.putCarrierBytes(keys, 'originals/a.jpg', decoyJpeg());

      final sent = await store.sendBackToBucket(
        keys,
        'originals/a.jpg',
        thumbnail: tile,
      );

      expect(sent, isTrue);
      expect(await store.hasCarrier(keys, 'originals/a.jpg'), isFalse);
      // The grid still draws it, offline, and opening it downloads it again.
      expect(await store.readThumbnail(keys, 'originals/a.jpg'), equals(tile));
    },
  );

  test('nothing is evicted by age or size', () async {
    // The difference between this and `VaultCache`: a cache may throw
    // anything away, and this holds the photo.
    final keys = _keysFor(1);
    await store.putCarrierBytes(keys, 'originals/a.jpg', decoyJpeg());
    final file = await store.carrierFile(keys, 'originals/a.jpg');
    await file.setLastModified(DateTime(2020));

    expect(await store.readCarrier(keys, 'originals/a.jpg'), isNotNull);
  });

  test('the index survives a rewrite and says nothing when absent', () async {
    expect(await store.readIndex(), isNull);

    await store.writeIndex(Uint8List.fromList([1, 2, 3]));
    expect(await store.readIndex(), equals([1, 2, 3]));

    await store.writeIndex(Uint8List.fromList([4, 5]));
    expect(await store.readIndex(), equals([4, 5]));
  });

  test('one album can be emptied without touching another', () async {
    final one = _keysFor(1);
    final two = _keysFor(2);
    await store.putCarrierBytes(one, 'originals/a.jpg', decoyJpeg());
    await store.putCarrierBytes(two, 'originals/b.jpg', decoyJpeg());

    await store.removeAll(one, ['originals/a.jpg']);

    expect(await store.hasCarrier(one, 'originals/a.jpg'), isFalse);
    expect(await store.hasCarrier(two, 'originals/b.jpg'), isTrue);
  });

  test('clear takes the whole directory', () async {
    final keys = _keysFor(1);
    await store.putCarrierBytes(keys, 'originals/a.jpg', decoyJpeg());
    await store.writeIndex(Uint8List.fromList([1]));

    await store.clear();

    expect(
      Directory('${tempDir.path}/${VaultStore.root}').existsSync(),
      isFalse,
    );
    expect(await store.readIndex(), isNull);
  });

  test('usage separates the full copies from the tiles', () async {
    final keys = _keysFor(1);
    final carrier = decoyJpeg();
    await store.putCarrierBytes(keys, 'originals/a.jpg', carrier);
    await store.writeThumbnail(
      keys,
      'originals/b.jpg',
      Uint8List.fromList(List.filled(1024, 3)),
    );

    final usage = await store.usage();

    expect(usage.carriers, 1);
    expect(usage.carrierBytes, carrier.length);
    // 1024 plus the 16-byte IV in front of it.
    expect(usage.thumbnailBytes, 1024 + 16);
  });
}
