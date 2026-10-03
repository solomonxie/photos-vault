import 'dart:typed_data';

import 'carrier.dart';
import 'jpeg_segments.dart';
import 'keys.dart';
import 'mp4_boxes.dart';

/// A carrier found by [CarrierProbe]: its parsed header, and the first
/// bytes of its payload - what `openThumbnail` and `openMeta` read.
class ProbedCarrier {
  const ProbedCarrier(this.header, this.payloadPrefix);

  final CarrierHeader header;
  final Uint8List payloadPrefix;
}

/// Reads bytes `[start, end)` of one object, or null when it cannot.
typedef RangeReader = Future<Uint8List?> Function(int start, int end);

/// Whether an object is a carrier, from a few ranged reads and never the
/// whole file: the first 64 KB of a JPEG, or a walk down an MP4's top-level
/// boxes (8 to 16 bytes each) to the `free` box that holds the payload.
class CarrierProbe {
  const CarrierProbe();

  static const _maxBoxes = 64;

  /// The carrier header in the object, or null for an ordinary file - and
  /// for anything whose header fails the sanity checks, so a photo with
  /// stray `APP7` or `free` data stays ordinary.
  Future<ProbedCarrier?> probe({
    required RangeReader read,
    required int size,
    required bool isVideo,
  }) async {
    final found = isVideo
        ? await _fromMp4(read, size)
        : await _fromJpeg(read, size);
    if (found == null) return null;
    final claimed = found.header.thumbLength + found.header.originalLength;
    if (claimed <= 0 || claimed > size) return null;
    return found;
  }

  Future<ProbedCarrier?> _fromJpeg(RangeReader read, int size) async {
    final prefix = await read(
      0,
      size < thumbnailPrefixBytes ? size : thumbnailPrefixBytes,
    );
    if (prefix == null) return null;
    final payload = carrierPayloadFromPrefix(prefix);
    if (payload.isEmpty) return null;
    final header = CarrierHeader.parse(payload);
    return header == null ? null : ProbedCarrier(header, payload);
  }

  Future<ProbedCarrier?> _fromMp4(RangeReader read, int size) async {
    var at = 0;
    for (var i = 0; i < _maxBoxes && at + 8 <= size; i++) {
      final head = await read(at, at + 16 > size ? size : at + 16);
      if (head == null || head.length < 8) return null;
      final view = ByteData.sublistView(head);
      var boxSize = view.getUint32(0);
      final type = String.fromCharCodes(head.sublist(4, 8));
      var headerSize = 8;
      if (boxSize == 1) {
        if (head.length < 16) return null;
        boxSize = view.getUint64(8);
        headerSize = 16;
      } else if (boxSize == 0) {
        boxSize = size - at;
      }
      if (boxSize < headerSize || at + boxSize > size) return null;
      if (type == 'free' &&
          boxSize >= headerSize + mp4CarrierTag.length + headerBytesV2) {
        final start = at + headerSize;
        final body = await read(
          start,
          start + mp4CarrierTag.length + headerBytesV2,
        );
        if (body != null &&
            body.length >= mp4CarrierTag.length + headerBytes &&
            _hasTag(body)) {
          final header = CarrierHeader.parse(
            Uint8List.sublistView(body, mp4CarrierTag.length),
          );
          if (header != null) {
            final bodyLength = boxSize - headerSize - mp4CarrierTag.length;
            final want = bodyLength < thumbnailPrefixBytes
                ? bodyLength
                : thumbnailPrefixBytes;
            final prefix = await read(
              start + mp4CarrierTag.length,
              start + mp4CarrierTag.length + want,
            );
            if (prefix == null) return null;
            return ProbedCarrier(header, prefix);
          }
        }
      }
      at += boxSize;
    }
    return null;
  }

  bool _hasTag(Uint8List body) {
    for (var i = 0; i < mp4CarrierTag.length; i++) {
      if (body[i] != mp4CarrierTag[i]) return false;
    }
    return true;
  }
}

/// A carrier written by one of this install's own passphrases. A salt that
/// is on no list belongs to another install, or a generation that is lost -
/// and such a file stays an ordinary photo, because calling it hidden would
/// make it vanish for good.
bool isKnownSalt(CarrierHeader header, List<PassphraseEntry> known) {
  for (final entry in known) {
    if (_same(entry.salt, header.masterSalt)) return true;
  }
  return false;
}

bool _same(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
