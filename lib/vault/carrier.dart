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

const _version = 1;
const headerBytes = 69;
const _macBytes = 32;

class CarrierKeys {
  const CarrierKeys({required this.encKey, required this.macKey});

  /// One album's key material. Per album, not per file: a per-file
  /// derivation buys nothing an attacker could not also compute, and the
  /// random IV per file is what actually keeps two files off one counter.
  factory CarrierKeys.forAlbum(Uint8List albumKey) {
    final material = hkdf(key: albumKey, info: 'pv-carrier-v1'.codeUnits);
    return CarrierKeys(
      encKey: Uint8List.sublistView(material, 0, 32),
      macKey: Uint8List.sublistView(material, 32, 64),
    );
  }

  final Uint8List encKey;
  final Uint8List macKey;
}

class CarrierHeader {
  const CarrierHeader({
    required this.masterSalt,
    required this.ivThumb,
    required this.ivFull,
    required this.thumbLength,
    required this.originalLength,
    required this.extension,
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

  Uint8List get _locatorInput =>
      (BytesBuilder()
            ..add(masterSalt)
            ..add(ivThumb)
            ..add(ivFull))
          .toBytes();

  /// Keyed to *this file* rather than to the album, so carriers share no
  /// constant a bucket could be grouped by. Four bytes: it says "this key
  /// opens this file", it is not a secret.
  Uint8List locator(Uint8List macKey) =>
      Uint8List.sublistView(vaultHmac(macKey, _locatorInput), 0, 4);

  Uint8List toBytes(Uint8List macKey) {
    final numbers = ByteData(12)
      ..setUint32(0, thumbLength)
      ..setUint64(4, originalLength);
    final ext = extension.padRight(4, ' ').substring(0, 4);
    return (BytesBuilder()
          ..addByte(_version)
          ..add(masterSalt)
          ..add(ivThumb)
          ..add(ivFull)
          ..add(numbers.buffer.asUint8List())
          ..add(ext.codeUnits)
          ..add(locator(macKey)))
        .toBytes();
  }

  static CarrierHeader? parse(Uint8List bytes) {
    if (bytes.length < headerBytes || bytes[0] != _version) return null;
    final numbers = ByteData.sublistView(bytes, 49, 61);
    return CarrierHeader(
      masterSalt: Uint8List.sublistView(bytes, 1, 17),
      ivThumb: Uint8List.sublistView(bytes, 17, 33),
      ivFull: Uint8List.sublistView(bytes, 33, 49),
      thumbLength: numbers.getUint32(0),
      originalLength: numbers.getUint64(4),
      extension: String.fromCharCodes(Uint8List.sublistView(bytes, 61, 65))
          .trim(),
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
}) {
  final header = CarrierHeader(
    masterSalt: masterSalt,
    ivThumb: randomBytes(16),
    ivFull: randomBytes(16),
    thumbLength: thumbnail.length,
    originalLength: original.length,
    extension: extension,
  );
  final head = header.toBytes(keys.macKey);
  final encThumb = cipher.transform(
    key: keys.encKey,
    iv: header.ivThumb,
    data: thumbnail,
  );
  final encFull = cipher.transform(
    key: keys.encKey,
    iv: header.ivFull,
    data: original,
  );
  return (BytesBuilder()
        ..add(head)
        ..add(vaultHmac(keys.macKey, [...head, ...encThumb]))
        ..add(encThumb)
        ..add(vaultHmac(keys.macKey, [...head, ...encFull]))
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
      Uint8List.sublistView(payload, headerBytes - 4, headerBytes),
    );

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
  final head = Uint8List.sublistView(payloadPrefix, 0, headerBytes);
  final thumbAt = headerBytes + _macBytes;
  if (payloadPrefix.length < thumbAt + header.thumbLength) return null;
  final encThumb = Uint8List.sublistView(
    payloadPrefix,
    thumbAt,
    thumbAt + header.thumbLength,
  );
  if (!bytesMatch(
    Uint8List.sublistView(payloadPrefix, headerBytes, thumbAt),
    vaultHmac(keys.macKey, [...head, ...encThumb]),
  )) {
    return null;
  }
  return cipher.transform(key: keys.encKey, iv: header.ivThumb, data: encThumb);
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
  final head = Uint8List.sublistView(payload, 0, headerBytes);
  final fullMacAt = headerBytes + _macBytes + header.thumbLength;
  final fullAt = fullMacAt + _macBytes;
  if (payload.length < fullAt + header.originalLength) return null;
  final encFull = Uint8List.sublistView(
    payload,
    fullAt,
    fullAt + header.originalLength,
  );
  if (!bytesMatch(
    Uint8List.sublistView(payload, fullMacAt, fullAt),
    vaultHmac(keys.macKey, [...head, ...encFull]),
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
