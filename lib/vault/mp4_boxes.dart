import 'dart:typed_data';

/// MP4 is a stream of boxes — `size`, four-character `type`, payload — and
/// `free` boxes exist precisely to be skipped. A video carrier appends one
/// **after `moov`**, so no sample-table offset (`stco`/`co64`) shifts and
/// nothing has to be rewritten. A trailing `free` box is structurally
/// ordinary, unlike trailing bytes on a JPEG.
///
/// Enough parsing to append and read one box; this never decodes a frame.
const _freeType = 'free';

/// `free` payloads start with this, so a reader can tell our box from a
/// `free` box a muxer left behind. Not a secret — the format is public.
const mp4CarrierTag = [0x50, 0x56, 0x43, 0x31]; // "PVC1"

class Mp4Box {
  const Mp4Box(this.type, this.start, this.end);

  final String type;
  final int start;
  final int end;
}

/// Top-level boxes only. Null when [bytes] isn't an MP4/QuickTime file.
List<Mp4Box>? parseMp4Boxes(Uint8List bytes) {
  if (bytes.length < 8) return null;
  final view = ByteData.sublistView(bytes);
  final boxes = <Mp4Box>[];
  var at = 0;
  while (at + 8 <= bytes.length) {
    var size = view.getUint32(at);
    final type = String.fromCharCodes(bytes.sublist(at + 4, at + 8));
    var headerSize = 8;
    if (size == 1) {
      if (at + 16 > bytes.length) return null;
      size = view.getUint64(at + 8);
      headerSize = 16;
    } else if (size == 0) {
      size = bytes.length - at;
    }
    if (size < headerSize || at + size > bytes.length) return null;
    boxes.add(Mp4Box(type, at, at + size));
    at += size;
  }
  if (boxes.isEmpty || boxes.first.type != 'ftyp') return null;
  return boxes;
}

/// [decoy] with [payload] appended in a `free` box. 64-bit box size, since
/// a hidden video's bytes routinely pass 4 GB's 32-bit ceiling.
Uint8List writeMp4WithPayload(Uint8List decoy, Uint8List payload) {
  final header = ByteData(16)
    ..setUint32(0, 1)
    ..setUint32(
      4,
      _freeType.codeUnitAt(0) << 24 |
          _freeType.codeUnitAt(1) << 16 |
          _freeType.codeUnitAt(2) << 8 |
          _freeType.codeUnitAt(3),
    )
    ..setUint64(8, 16 + mp4CarrierTag.length + payload.length);
  return (BytesBuilder()
        ..add(decoy)
        ..add(header.buffer.asUint8List())
        ..add(mp4CarrierTag)
        ..add(payload))
      .toBytes();
}

/// The payload out of a whole carrier, or null if there isn't one.
Uint8List? mp4CarrierPayload(Uint8List bytes) {
  final boxes = parseMp4Boxes(bytes);
  if (boxes == null) return null;
  for (final box in boxes.reversed) {
    if (box.type != _freeType) continue;
    final start = box.end - box.start >= (1 << 32) || _isLargeBox(bytes, box)
        ? box.start + 16
        : box.start + 8;
    if (start + mp4CarrierTag.length > box.end) continue;
    final tag = Uint8List.sublistView(
      bytes,
      start,
      start + mp4CarrierTag.length,
    );
    if (!_sameBytes(tag, mp4CarrierTag)) continue;
    return Uint8List.sublistView(bytes, start + mp4CarrierTag.length, box.end);
  }
  return null;
}

bool _isLargeBox(Uint8List bytes, Mp4Box box) =>
    ByteData.sublistView(bytes).getUint32(box.start) == 1;

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
