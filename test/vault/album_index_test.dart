import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/vault/album_index.dart';
import 'package:photos_vault/vault/cipher.dart';
import 'package:photos_vault/vault/keys.dart';

AlbumKeys _keysFor(int seed) => AlbumKeys(
  albumKey: Uint8List.fromList(List.generate(32, (i) => (i * seed + 7) % 256)),
  entry: PassphraseEntry(
    id: 'entry$seed',
    salt: Uint8List(16),
    verifier: Uint8List(32),
    hint: 'hint $seed',
  ),
);

List<IndexEntry> _entries(int count) => [
  for (var i = 0; i < count; i++)
    IndexEntry(
      objectKey: 'originals/object-$i.jpg',
      takenAt: DateTime.fromMillisecondsSinceEpoch(1600000000000 + i * 1000),
      width: 4032,
      height: 3024,
      isVideo: i.isEven,
      name: 'IMG_$i',
    ),
];

void main() {
  final cipher = PlatformCipher();

  test('an empty index is the same size as a full one', () {
    final keys = _keysFor(1);
    final empty = emptyIndex();
    final full = writeSection(
      cipher: cipher,
      keys: keys,
      index: empty,
      entries: _entries(200),
      passphrases: [keys.entry],
    );
    expect(empty.length, indexBytes);
    expect(full.length, indexBytes);
  });

  test('a section round trips', () {
    final keys = _keysFor(1);
    final written = writeSection(
      cipher: cipher,
      keys: keys,
      index: null,
      entries: _entries(50),
      passphrases: [keys.entry],
    );
    final read = readSection(cipher: cipher, keys: keys, index: written);
    expect(read.length, 50);
    expect(read.first.objectKey, 'originals/object-0.jpg');
    expect(read[3].isVideo, isFalse);
    expect(read[4].width, 4032);
  });

  test('another album key reads nothing, and cannot tell why', () {
    final mine = _keysFor(1);
    final theirs = _keysFor(9);
    final written = writeSection(
      cipher: cipher,
      keys: mine,
      index: null,
      entries: _entries(10),
      passphrases: [mine.entry],
    );
    expect(readSection(cipher: cipher, keys: theirs, index: written), isEmpty);
    expect(
      readSection(cipher: cipher, keys: mine, index: emptyIndex()),
      isEmpty,
    );
  });

  test('two albums coexist when their slots differ', () {
    final a = _keysFor(1);
    final b = _keysFor(5);
    expect(
      a.sectionTag.first % 32 == b.sectionTag.first % 32,
      isFalse,
      reason: 'fixture needs two albums in different slots',
    );

    var index = writeSection(
      cipher: cipher,
      keys: a,
      index: null,
      entries: _entries(5),
      passphrases: [a.entry],
    );
    index = writeSection(
      cipher: cipher,
      keys: b,
      index: index,
      entries: _entries(9),
      passphrases: [a.entry, b.entry],
    );

    expect(readSection(cipher: cipher, keys: a, index: index).length, 5);
    expect(readSection(cipher: cipher, keys: b, index: index).length, 9);
  });

  test('passphrase entries survive in the plaintext header', () {
    final keys = _keysFor(2);
    final index = writeSection(
      cipher: cipher,
      keys: keys,
      index: null,
      entries: _entries(1),
      passphrases: [keys.entry],
    );
    final found = passphrasesIn(index);
    expect(found.single.id, 'entry2');
    expect(found.single.hint, 'hint 2');
  });

  test('a section holds a real library, compressed', () {
    final keys = _keysFor(3);
    final index = writeSection(
      cipher: cipher,
      keys: keys,
      index: null,
      entries: _entries(2000),
      passphrases: const [],
    );
    expect(readSection(cipher: cipher, keys: keys, index: index).length, 2000);
  });
}
