import 'dart:math';
import 'dart:typed_data';

import 'cipher.dart';
import 'jpeg_segments.dart';
import 'mp4_boxes.dart';

/// One hidden photo is one object: a decoy that opens as an ordinary photo,
/// carrying an encrypted thumbnail and the encrypted original inside it.
///
/// The thumbnail comes first so the grid can fetch it with a ranged GET of
/// the first [thumbnailPrefixBytes] and never pull the original - or even
/// the decoy's pixels, which sit at the end of the file.
///
/// Payload layout, whether it rides in JPEG `APP7` segments or an MP4
/// `free` box:
///
/// ```text
/// header      69 B
/// thumbMac    32 B
/// encThumb    thumbLength
/// fullMac     32 B
/// encFull     the rest
/// ```
const thumbnailPrefixBytes = 64 * 1024;

/// The most an encrypted thumbnail may be, so header, MACs and thumbnail
/// all sit inside [thumbnailPrefixBytes] with room for the decoy's own
/// leading segments. Past it, a tile drawn from the prefix has nothing.
const carrierThumbnailBudget = 60 * 1024;

const _version = 1;
const _versionV2 = 2;
const headerBytes = 69;

/// v2 adds an 8-byte nonce and widens the locator to 8 bytes:
/// `locator = HMAC(macKey, nonce)[0:8]`. Both go into the object's name, so
/// a carrier can be recognised by name alone.
const headerBytesV2 = 81;
const nonceBytes = 8;
const _macBytes = 32;

class CarrierKeys {
  const CarrierKeys({
    required this.encKey,
    required this.macKey,
    required this.nameKey,
  });

  /// One album's key material. Per album, not per file: a per-file
  /// derivation buys nothing an attacker could not also compute, and the
  /// random IV per file is what actually keeps two files off one counter.
  factory CarrierKeys.forAlbum(Uint8List albumKey) {
    final material = hkdf(key: albumKey, info: 'pv-carrier-v1'.codeUnits);
    return CarrierKeys(
      encKey: Uint8List.sublistView(material, 0, 32),
      macKey: Uint8List.sublistView(material, 32, 64),
      nameKey: hkdf(key: albumKey, info: 'pv-name-v1'.codeUnits, length: 32),
    );
  }

  final Uint8List encKey;
  final Uint8List macKey;

  /// Derives what a photo's object name is made of, so the name can be
  /// worked out again from the record alone - see `object_key.dart`.
  final Uint8List nameKey;
}

/// What a v2 carrier says about its photo, inside the encrypted thumbnail
/// section: enough to list it in an album from the first 64 KB alone.
class CarrierMeta {
  const CarrierMeta({
    required this.takenAt,
    required this.width,
    required this.height,
    required this.isVideo,
  });

  static const bytes = 20;

  final DateTime takenAt;
  final int width;
  final int height;
  final bool isVideo;

  Uint8List toBytes() {
    final out = ByteData(bytes)
      ..setInt64(0, takenAt.millisecondsSinceEpoch)
      ..setUint32(8, width)
      ..setUint32(12, height)
      ..setUint8(16, isVideo ? 1 : 0);
    return out.buffer.asUint8List();
  }

  static CarrierMeta fromBytes(Uint8List raw) {
    final view = ByteData.sublistView(raw);
    return CarrierMeta(
      takenAt: DateTime.fromMillisecondsSinceEpoch(view.getInt64(0)),
      width: view.getUint32(8),
      height: view.getUint32(12),
      isVideo: view.getUint8(16) == 1,
    );
  }
}

class CarrierHeader {
  const CarrierHeader({
    required this.masterSalt,
    required this.ivThumb,
    required this.ivFull,
    required this.thumbLength,
    required this.originalLength,
    required this.extension,
    this.nonce,
    this.storedLocator,
  });

  /// The passphrase's KDF salt travels with every carrier, so a file is
  /// openable with a passphrase alone - no index, no database, no app
  /// state. That is what makes "point the app at a bucket and get it all
  /// back" work.
  final Uint8List masterSalt;
  final Uint8List ivThumb;
  final Uint8List ivFull;
  final int thumbLength;
  final int originalLength;
  final String extension;

  /// v2 only: random per photo, and the input of [locator].
  final Uint8List? nonce;

  /// What the file says its locator is; set by [parse], null when built.
  final Uint8List? storedLocator;

  bool get isV2 => nonce != null;
  int get length => isV2 ? headerBytesV2 : headerBytes;
  int get locatorBytes => isV2 ? 8 : 4;

  Uint8List get _locatorInput =>
      (BytesBuilder()
            ..add(masterSalt)
            ..add(ivThumb)
            ..add(ivFull))
          .toBytes();

  /// Keyed to *this file* rather than to the album, so carriers share no
  /// constant a bucket could be grouped by. It says "this key opens this
  /// file", it is not a secret.
  Uint8List locator(Uint8List macKey) => isV2
      ? Uint8List.sublistView(vaultHmac(macKey, nonce!), 0, 8)
      : Uint8List.sublistView(vaultHmac(macKey, _locatorInput), 0, 4);

  Uint8List toBytes(Uint8List macKey) {
    final numbers = ByteData(12)
      ..setUint32(0, thumbLength)
      ..setUint64(4, originalLength);
    final ext = extension.padRight(4, ' ').substring(0, 4);
    return (BytesBuilder()
          ..addByte(isV2 ? _versionV2 : _version)
          ..add(masterSalt)
          ..add(ivThumb)
          ..add(ivFull)
          ..add(numbers.buffer.asUint8List())
          ..add(ext.codeUnits)
          ..add(nonce ?? const <int>[])
          ..add(locator(macKey)))
        .toBytes();
  }

  static CarrierHeader? parse(Uint8List bytes) {
    if (bytes.isEmpty) return null;
    final version = bytes[0];
    if (version != _version && version != _versionV2) return null;
    final v2 = version == _versionV2;
    final length = v2 ? headerBytesV2 : headerBytes;
    if (bytes.length < length) return null;
    final numbers = ByteData.sublistView(bytes, 49, 61);
    return CarrierHeader(
      masterSalt: Uint8List.sublistView(bytes, 1, 17),
      ivThumb: Uint8List.sublistView(bytes, 17, 33),
      ivFull: Uint8List.sublistView(bytes, 33, 49),
      thumbLength: numbers.getUint32(0),
      originalLength: numbers.getUint64(4),
      extension: String.fromCharCodes(Uint8List.sublistView(bytes, 61, 65))
          .trim(),
      nonce: v2 ? Uint8List.sublistView(bytes, 65, 65 + nonceBytes) : null,
      storedLocator: Uint8List.sublistView(
        bytes,
        v2 ? 65 + nonceBytes : 65,
        length,
      ),
    );
  }
}

class OpenedCarrier {
  const OpenedCarrier({required this.original, required this.extension});

  final Uint8List original;
  final String extension;
}

Uint8List randomBytes(int length) {
  final random = Random.secure();
  return Uint8List.fromList(List.generate(length, (_) => random.nextInt(256)));
}

/// The encrypted blob both container formats carry.
Uint8List buildPayload({
  required VaultCipher cipher,
  required CarrierKeys keys,
  required Uint8List masterSalt,
  required Uint8List thumbnail,
  required Uint8List original,
  required String extension,
  Uint8List? nonce,
  CarrierMeta? meta,
}) {
  // v2 carries its metadata in front of the thumbnail, inside the same
  // encryption, so the first 64 KB still says everything.
  final thumbPlain = meta == null
      ? thumbnail
      : (BytesBuilder()
              ..add(meta.toBytes())
              ..add(thumbnail))
            .toBytes();
  final header = CarrierHeader(
    masterSalt: masterSalt,
    ivThumb: randomBytes(16),
    ivFull: randomBytes(16),
    thumbLength: thumbPlain.length,
    originalLength: original.length,
    extension: extension,
    nonce: meta == null ? null : (nonce ?? randomBytes(nonceBytes)),
  );
  final head = header.toBytes(keys.macKey);
  final encThumb = cipher.transform(
    key: keys.encKey,
    iv: header.ivThumb,
    data: thumbPlain,
  );
  final encFull = cipher.transform(
    key: keys.encKey,
    iv: header.ivFull,
    data: original,
  );
  return (BytesBuilder()
        ..add(head)
        ..add(vaultHmacParts(keys.macKey, [head, encThumb]))
        ..add(encThumb)
        ..add(vaultHmacParts(keys.macKey, [head, encFull]))
        ..add(encFull))
      .toBytes();
}

/// A JPEG carrier: [decoy] with the payload in `APP7` segments before the
/// image data. Null if [decoy] is not a JPEG.
Uint8List? buildJpegCarrier({
  required VaultCipher cipher,
  required CarrierKeys keys,
  required Uint8List masterSalt,
  required Uint8List decoy,
  required Uint8List thumbnail,
  required Uint8List original,
  required String extension,
  Uint8List? nonce,
  CarrierMeta? meta,
}) {
  final parts = parseJpeg(decoy);
  if (parts == null) return null;
  return writeJpegWithPayload(
    parts,
    buildPayload(
      cipher: cipher,
      keys: keys,
      masterSalt: masterSalt,
      thumbnail: thumbnail,
      original: original,
      extension: extension,
      nonce: nonce,
      meta: meta,
    ),
  );
}

/// A video carrier: [decoy] with the payload in a trailing `free` box.
/// Null if [decoy] is not an MP4.
Uint8List? buildMp4Carrier({
  required VaultCipher cipher,
  required CarrierKeys keys,
  required Uint8List masterSalt,
  required Uint8List decoy,
  required Uint8List poster,
  required Uint8List original,
  required String extension,
  Uint8List? nonce,
  CarrierMeta? meta,
}) {
  if (parseMp4Boxes(decoy) == null) return null;
  return writeMp4WithPayload(
    decoy,
    buildPayload(
      cipher: cipher,
      keys: keys,
      masterSalt: masterSalt,
      thumbnail: poster,
      original: original,
      extension: extension,
      nonce: nonce,
      meta: meta,
    ),
  );
}

/// The payload inside a carrier of either kind, or null for an ordinary
/// photo or video.
Uint8List? payloadOf(Uint8List object) {
  final jpeg = parseJpeg(object);
  if (jpeg != null) {
    final payload = jpeg.carrierPayload();
    return payload.isEmpty ? null : payload;
  }
  return mp4CarrierPayload(object);
}

bool _locatorMatches(CarrierHeader header, Uint8List payload, Uint8List mac) =>
    bytesMatch(
      header.locator(mac),
      Uint8List.sublistView(
        payload,
        header.length - header.locatorBytes,
        header.length,
      ),
    );

/// Whether [macKey] opens the carrier whose header is [header]: the check
/// an album runs over a name or a cached header, with no network.
bool headerBelongsTo(CarrierHeader header, Uint8List macKey) {
  final stored = header.storedLocator;
  return stored != null && bytesMatch(header.locator(macKey), stored);
}

/// Decrypts the thumbnail out of the *first bytes* of a carrier - what the
/// grid gets from a ranged GET. Null when [keys] do not open it, which is
/// also what an ordinary photo looks like.
Uint8List? openThumbnail({
  required VaultCipher cipher,
  required CarrierKeys keys,
  required Uint8List payloadPrefix,
}) {
  final header = CarrierHeader.parse(payloadPrefix);
  if (header == null) return null;
  if (!_locatorMatches(header, payloadPrefix, keys.macKey)) return null;
  final head = Uint8List.sublistView(payloadPrefix, 0, header.length);
  final thumbAt = header.length + _macBytes;
  if (payloadPrefix.length < thumbAt + header.thumbLength) return null;
  final encThumb = Uint8List.sublistView(
    payloadPrefix,
    thumbAt,
    thumbAt + header.thumbLength,
  );
  if (!bytesMatch(
    Uint8List.sublistView(payloadPrefix, header.length, thumbAt),
    vaultHmacParts(keys.macKey, [head, encThumb]),
  )) {
    return null;
  }
  final plain = cipher.transform(
    key: keys.encKey,
    iv: header.ivThumb,
    data: encThumb,
  );
  return header.isV2 ? Uint8List.sublistView(plain, CarrierMeta.bytes) : plain;
}

/// A v2 carrier's own description of its photo, from the first bytes of it.
/// Null for v1, and for a key that does not open it.
CarrierMeta? openMeta({
  required VaultCipher cipher,
  required CarrierKeys keys,
  required Uint8List payloadPrefix,
}) {
  final header = CarrierHeader.parse(payloadPrefix);
  if (header == null || !header.isV2) return null;
  if (!_locatorMatches(header, payloadPrefix, keys.macKey)) return null;
  final thumbAt = header.length + _macBytes;
  if (payloadPrefix.length < thumbAt + CarrierMeta.bytes) return null;
  final head = Uint8List.sublistView(payloadPrefix, 0, header.length);
  if (payloadPrefix.length < thumbAt + header.thumbLength) return null;
  final encThumb = Uint8List.sublistView(
    payloadPrefix,
    thumbAt,
    thumbAt + header.thumbLength,
  );
  if (!bytesMatch(
    Uint8List.sublistView(payloadPrefix, header.length, thumbAt),
    vaultHmacParts(keys.macKey, [head, encThumb]),
  )) {
    return null;
  }
  final plain = cipher.transform(
    key: keys.encKey,
    iv: header.ivThumb,
    data: encThumb,
  );
  return CarrierMeta.fromBytes(
    Uint8List.sublistView(plain, 0, CarrierMeta.bytes),
  );
}

/// Decrypts the original out of a whole carrier. Null when [keys] do not
/// open it, or when a byte of it has been changed.
OpenedCarrier? openCarrier({
  required VaultCipher cipher,
  required CarrierKeys keys,
  required Uint8List payload,
}) {
  final header = CarrierHeader.parse(payload);
  if (header == null) return null;
  if (!_locatorMatches(header, payload, keys.macKey)) return null;
  final head = Uint8List.sublistView(payload, 0, header.length);
  final fullMacAt = header.length + _macBytes + header.thumbLength;
  final fullAt = fullMacAt + _macBytes;
  if (payload.length < fullAt + header.originalLength) return null;
  final encFull = Uint8List.sublistView(
    payload,
    fullAt,
    fullAt + header.originalLength,
  );
  if (!bytesMatch(
    Uint8List.sublistView(payload, fullMacAt, fullAt),
    vaultHmacParts(keys.macKey, [head, encFull]),
  )) {
    return null;
  }
  return OpenedCarrier(
    original: cipher.transform(
      key: keys.encKey,
      iv: header.ivFull,
      data: encFull,
    ),
    extension: header.extension,
  );
}
