import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'carrier.dart';
import 'cipher.dart';
import 'keys.dart';

/// The album's own listing, since the database no longer keeps one.
///
/// One object, `app-data/index.bin`, written by **every** install whether
/// anything is hidden or not — an encrypted blob that appears only when
/// somebody has a private album is the loudest object in a bucket; one
/// everybody has says nothing. Fixed size, fixed section count, padded out
/// with sections full of random bytes, so it cannot be watched for "they
/// hid something today" either.
///
/// ```text
/// plaintext header   version · entries JSON (salt · verifier · hint) · padding
/// section × 16       tag(16) · iv(16) · mac(32) · ciphertext, all one size
/// ```
///
/// A wrong 4-digit code produces a tag that matches no section, which is
/// also exactly what an unused album looks like.
///
/// **Which slot an album owns is derived from its key**, not searched for.
/// It has to be: telling a padding section from another album's real one
/// is precisely what this file is built to prevent, so a writer looking
/// for a "free" slot would be reading occupancy it must not have. The cost
/// is a birthday collision — two albums landing on one slot, the second
/// overwriting the first's *listing*. Rare, and it costs a listing, not
/// photos: [readSection] returning nothing falls back to rebuilding from
/// the bucket by testing every object's locator.
const indexObjectName = 'index.bin';
const _version = 1;
const _sections = 32;
const _sectionBytes = 64 * 1024;
const _headerBytes = 16 * 1024;
const indexBytes = _headerBytes + _sections * _sectionBytes;

class IndexEntry {
  const IndexEntry({
    required this.objectKey,
    required this.takenAt,
    required this.width,
    required this.height,
    required this.isVideo,
    this.name = '',
  });

  factory IndexEntry.fromJson(Map<String, dynamic> json) => IndexEntry(
    objectKey: json['k'] as String,
    takenAt: DateTime.fromMillisecondsSinceEpoch(json['t'] as int),
    width: json['w'] as int? ?? 0,
    height: json['h'] as int? ?? 0,
    isVideo: json['v'] as bool? ?? false,
    name: json['n'] as String? ?? '',
  );

  final String objectKey;
  final DateTime takenAt;
  final int width;
  final int height;
  final bool isVideo;
  final String name;

  Map<String, dynamic> toJson() => {
    'k': objectKey,
    't': takenAt.millisecondsSinceEpoch,
    'w': width,
    'h': height,
    'v': isVideo,
    'n': name,
  };
}

class VaultIndex {
  const VaultIndex({required this.entries, required this.passphrases});

  final List<IndexEntry> entries;

  /// Salt, verifier and hint for every passphrase this bucket has seen.
  /// Not secret, and they have to be readable before any key exists — a
  /// phone restored from nothing has only this.
  final List<PassphraseEntry> passphrases;
}

/// A blank index: what an install with nothing hidden still uploads.
Uint8List emptyIndex({List<PassphraseEntry> passphrases = const []}) =>
    _assemble(header: passphrases, sections: []);

Uint8List _assemble({
  required List<PassphraseEntry> header,
  required List<Uint8List> sections,
}) {
  final headerJson = utf8.encode(
    jsonEncode({
      'v': _version,
      'p': [for (final e in header) e.toJson()],
    }),
  );
  if (headerJson.length + 4 > _headerBytes) {
    throw StateError('index header does not fit');
  }
  final out = BytesBuilder();
  final length = ByteData(4)..setUint32(0, headerJson.length);
  out.add(length.buffer.asUint8List());
  out.add(headerJson);
  out.add(randomBytes(_headerBytes - 4 - headerJson.length));
  for (var i = 0; i < _sections; i++) {
    out.add(i < sections.length ? sections[i] : randomBytes(_sectionBytes));
  }
  return out.toBytes();
}

List<PassphraseEntry> passphrasesIn(Uint8List index) {
  if (index.length < 4) return const [];
  final length = ByteData.sublistView(index, 0, 4).getUint32(0);
  if (length + 4 > index.length) return const [];
  try {
    final json = jsonDecode(
      utf8.decode(Uint8List.sublistView(index, 4, 4 + length)),
    ) as Map<String, dynamic>;
    return [
      for (final e in json['p'] as List)
        PassphraseEntry.fromJson(e as Map<String, dynamic>),
    ];
  } catch (_) {
    return const [];
  }
}

Uint8List _sectionAt(Uint8List index, int i) => Uint8List.sublistView(
  index,
  _headerBytes + i * _sectionBytes,
  _headerBytes + (i + 1) * _sectionBytes,
);

/// This album's entries, or an empty list when no section answers to
/// [keys] — the same outcome for a code nobody has used and a code typed
/// wrong, which is the point.
List<IndexEntry> readSection({
  required VaultCipher cipher,
  required AlbumKeys keys,
  required Uint8List index,
}) {
  if (index.length < indexBytes) return const [];
  final tag = keys.sectionTag;
  for (var i = 0; i < _sections; i++) {
    final section = _sectionAt(index, i);
    if (!bytesMatch(Uint8List.sublistView(section, 0, 16), tag)) continue;
    final iv = Uint8List.sublistView(section, 16, 32);
    final mac = Uint8List.sublistView(section, 32, 64);
    final body = Uint8List.sublistView(section, 64);
    if (!bytesMatch(mac, vaultHmac(keys.carrier.macKey, body))) continue;
    final plain = cipher.transform(
      key: keys.carrier.encKey,
      iv: iv,
      data: body,
    );
    try {
      final length = ByteData.sublistView(plain, 0, 4).getUint32(0);
      if (length + 4 > plain.length) return const [];
      final json = jsonDecode(
        utf8.decode(gzip.decode(Uint8List.sublistView(plain, 4, 4 + length))),
      ) as List;
      return [
        for (final e in json) IndexEntry.fromJson(e as Map<String, dynamic>),
      ];
    } catch (_) {
      return const [];
    }
  }
  return const [];
}

/// [index] with this album's section replaced. Every other section — real
/// or padding — is copied through untouched, so one album never learns
/// anything about another and the object's size never moves.
Uint8List writeSection({
  required VaultCipher cipher,
  required AlbumKeys keys,
  required Uint8List? index,
  required List<IndexEntry> entries,
  required List<PassphraseEntry> passphrases,
}) {
  final existing = (index != null && index.length >= indexBytes)
      ? [for (var i = 0; i < _sections; i++) _sectionAt(index, i)]
      : [for (var i = 0; i < _sections; i++) randomBytes(_sectionBytes)];

  final json = gzip.encode(
    utf8.encode(jsonEncode([for (final e in entries) e.toJson()])),
  );
  final plain = BytesBuilder();
  final length = ByteData(4)..setUint32(0, json.length);
  plain.add(length.buffer.asUint8List());
  plain.add(json);
  final bodyBytes = _sectionBytes - 64;
  if (plain.length > bodyBytes) {
    throw StateError('too many entries for one section');
  }
  final padded = BytesBuilder()
    ..add(plain.toBytes())
    ..add(randomBytes(bodyBytes - plain.length));

  final iv = randomBytes(16);
  final body = cipher.transform(
    key: keys.carrier.encKey,
    iv: iv,
    data: padded.toBytes(),
  );
  final section =
      (BytesBuilder()
            ..add(keys.sectionTag)
            ..add(iv)
            ..add(vaultHmac(keys.carrier.macKey, body))
            ..add(body))
          .toBytes();

  // Derived, never searched for: see the note at the top of this file.
  final slot = keys.sectionTag.first % _sections;
  existing[slot] = section;
  return _assemble(header: passphrases, sections: existing);
}
