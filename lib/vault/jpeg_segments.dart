import 'dart:typed_data';

/// A JPEG is `FFD8`, a run of marker segments, the entropy-coded scan, then
/// `FFD9`. Decoders are required to skip `APPn` markers they don't know,
/// which is the whole reason a carrier works: the payload rides in `APP7`
/// segments *inside* the file rather than appended past `FFD9`, where a
/// `tail -c` would find it and some pipelines would truncate it away.
///
/// Just enough parsing to insert and read those segments — this never
/// decodes an image.
const jpegCarrierMarker = 0xE7;

const _soi = 0xD8;
const _eoi = 0xD9;
const _sos = 0xDA;

/// Payload a single segment can hold: 65 535 minus its own 2-byte length.
const maxSegmentPayload = 65533;

class JpegSegment {
  const JpegSegment(this.marker, this.data);

  /// The byte after `FF`, e.g. `0xE7` for `APP7`.
  final int marker;
  final Uint8List data;
}

/// Splits [bytes] into the segments before the scan, and everything from
/// the scan onward — which is where an insertion has to stop, since the
/// entropy-coded data is not segment-structured.
class JpegParts {
  const JpegParts({required this.segments, required this.scanOnward});

  final List<JpegSegment> segments;
  final Uint8List scanOnward;

  /// Every `APP7` payload, in order, concatenated.
  Uint8List carrierPayload() {
    final out = BytesBuilder();
    for (final segment in segments) {
      if (segment.marker == jpegCarrierMarker) out.add(segment.data);
    }
    return out.toBytes();
  }
}

/// Null when [bytes] isn't a JPEG at all, or ends before its scan does.
JpegParts? parseJpeg(Uint8List bytes) {
  if (bytes.length < 4 || bytes[0] != 0xFF || bytes[1] != _soi) return null;
  final segments = <JpegSegment>[];
  var i = 2;
  while (i + 3 < bytes.length) {
    if (bytes[i] != 0xFF) return null;
    final marker = bytes[i + 1];
    if (marker == _sos || marker == _eoi) {
      return JpegParts(
        segments: segments,
        scanOnward: Uint8List.sublistView(bytes, i),
      );
    }
    final length = (bytes[i + 2] << 8) | bytes[i + 3];
    if (length < 2 || i + 2 + length > bytes.length) return null;
    segments.add(
      JpegSegment(marker, Uint8List.sublistView(bytes, i + 4, i + 2 + length)),
    );
    i += 2 + length;
  }
  return null;
}

/// Rebuilds a JPEG from [parts] unchanged.
Uint8List writeJpegSegments(JpegParts parts) =>
    writeJpegWithPayload(parts, Uint8List(0));

/// Rebuilds a JPEG with [payload] split across as many `APP7` segments as
/// it takes, placed after the existing metadata segments and before the
/// image data. Any `APP7` already present is dropped, so rebuilding is
/// idempotent.
Uint8List writeJpegWithPayload(JpegParts parts, Uint8List payload) {
  final out = BytesBuilder()..add([0xFF, _soi]);

  void writeSegment(int marker, Uint8List data) {
    final length = data.length + 2;
    out.add([0xFF, marker, (length >> 8) & 0xFF, length & 0xFF]);
    out.add(data);
  }

  for (final segment in parts.segments) {
    if (segment.marker == jpegCarrierMarker) continue;
    writeSegment(segment.marker, segment.data);
  }
  for (var at = 0; at < payload.length; at += maxSegmentPayload) {
    final end = at + maxSegmentPayload;
    writeSegment(
      jpegCarrierMarker,
      Uint8List.sublistView(
        payload,
        at,
        end > payload.length ? payload.length : end,
      ),
    );
  }
  out.add(parts.scanOnward);
  return out.toBytes();
}

/// Reads the payload out of the first [prefix] bytes of a carrier, for the
/// ranged GET the grid does — the thumbnail sits in the first segments, so
/// a 64 KB read is enough and the rest of the object is never fetched.
/// Tolerates the truncation: stops at the first segment that runs past the
/// end instead of failing.
Uint8List carrierPayloadFromPrefix(Uint8List prefix) {
  if (prefix.length < 4 || prefix[0] != 0xFF || prefix[1] != _soi) {
    return Uint8List(0);
  }
  final out = BytesBuilder();
  var i = 2;
  while (i + 3 < prefix.length) {
    if (prefix[i] != 0xFF) break;
    final marker = prefix[i + 1];
    if (marker == _sos || marker == _eoi) break;
    final length = (prefix[i + 2] << 8) | prefix[i + 3];
    if (length < 2) break;
    final end = i + 2 + length;
    if (end > prefix.length) {
      if (marker == jpegCarrierMarker) {
        out.add(Uint8List.sublistView(prefix, i + 4));
      }
      break;
    }
    if (marker == jpegCarrierMarker) {
      out.add(Uint8List.sublistView(prefix, i + 4, end));
    }
    i = end;
  }
  return out.toBytes();
}
