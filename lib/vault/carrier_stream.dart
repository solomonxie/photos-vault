import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'carrier.dart';
import 'cipher.dart';
import 'jpeg_segments.dart';
import 'mp4_boxes.dart';

/// Carriers written and opened a chunk at a time (BG-13), so a 1 GB hidden
/// video costs a few MB of heap, not three copies of itself. Byte for byte
/// what [buildJpegCarrier], [buildMp4Carrier] and [openCarrier] make and
/// read. Synchronous file I/O: for isolates only.

/// A multiple of the AES block, so each chunk starts on a counter.
const streamChunk = 1 << 20;

const _mac = 32;
const _sos = 0xDA;
const _eoi = 0xD9;

/// [iv] advanced by [block] blocks, as CommonCrypto's CTR mode counts:
/// big-endian in the low 64 bits, wrapping without a carry into the high
/// half (measured; `carrier_stream_test`).
Uint8List ctrIvAt(Uint8List iv, int block) {
  final out = Uint8List.fromList(iv);
  var carry = block;
  for (var i = 15; i >= 8 && carry != 0; i--) {
    final sum = out[i] + (carry & 0xFF);
    out[i] = sum & 0xFF;
    carry = (carry >> 8) + (sum >> 8);
  }
  return out;
}

/// The CTR transform of [data] found [offset] bytes (a block multiple)
/// into the stream started at [iv].
Uint8List ctrAt(
  VaultCipher cipher, {
  required Uint8List key,
  required Uint8List iv,
  required int offset,
  required Uint8List data,
}) {
  assert(offset % 16 == 0);
  return cipher.transform(key: key, iv: ctrIvAt(iv, offset ~/ 16), data: data);
}

/// Buffered writes, with each byte's place in the file known, so a MAC
/// written ahead of what it covers can be filled in after.
class _Out {
  _Out(this.file, {this.segmented = false});

  final RandomAccessFile file;

  /// JPEG: payload split into `APP7` segments of [maxSegmentPayload].
  final bool segmented;
  int _payloadLeft = 0;
  int _segmentLeft = 0;

  final _buffer = BytesBuilder(copy: false);
  int _flushed = 0;

  int get position => _flushed + _buffer.length;

  void raw(List<int> bytes) {
    _buffer.add(bytes);
    if (_buffer.length >= streamChunk) flush();
  }

  void startPayload(int length) => _payloadLeft = length;

  /// Where in the file each piece of [bytes] went.
  List<(int, int)> payload(Uint8List bytes) {
    final spans = <(int, int)>[];
    var at = 0;
    while (at < bytes.length) {
      if (segmented && _segmentLeft == 0) {
        _segmentLeft = _payloadLeft < maxSegmentPayload
            ? _payloadLeft
            : maxSegmentPayload;
        final length = _segmentLeft + 2;
        raw([0xFF, jpegCarrierMarker, (length >> 8) & 0xFF, length & 0xFF]);
      }
      final room = segmented ? _segmentLeft : bytes.length - at;
      final take = bytes.length - at < room ? bytes.length - at : room;
      spans.add((position, take));
      raw(Uint8List.sublistView(bytes, at, at + take));
      at += take;
      _payloadLeft -= take;
      if (segmented) _segmentLeft -= take;
    }
    return spans;
  }

  void flush() {
    if (_buffer.isEmpty) return;
    final bytes = _buffer.takeBytes();
    file.writeFromSync(bytes);
    _flushed += bytes.length;
  }

  void patch(List<(int, int)> spans, Uint8List bytes) {
    flush();
    var at = 0;
    for (final (position, length) in spans) {
      file
        ..setPositionSync(position)
        ..writeFromSync(bytes, at, at + length);
      at += length;
    }
    file.setPositionSync(_flushed);
  }
}

/// The carrier [buildJpegCarrier] (or, with [video], [buildMp4Carrier])
/// makes, written to [outPath] with the original read from [originalPath]
/// a chunk at a time. False when [decoy] is not of that kind.
bool writeCarrierFile({
  required VaultCipher cipher,
  required CarrierKeys keys,
  required Uint8List masterSalt,
  required Uint8List decoy,
  required bool video,
  required Uint8List thumbnail,
  required String originalPath,
  required String extension,
  required String outPath,
  Uint8List? nonce,
  CarrierMeta? meta,
  CarrierHeader? header,
}) {
  final jpeg = video ? null : parseJpeg(decoy);
  if (video ? parseMp4Boxes(decoy) == null : jpeg == null) return false;
  final source = File(originalPath).openSync();
  final file = File(outPath).openSync(mode: FileMode.write);
  var done = false;
  try {
    final originalLength = source.lengthSync();
    final thumbPlain = carrierThumbPlain(thumbnail, meta);
    header ??= newCarrierHeader(
      masterSalt: masterSalt,
      thumbLength: thumbPlain.length,
      originalLength: originalLength,
      extension: extension,
      nonce: nonce,
      meta: meta,
    );
    final head = header.toBytes(keys.macKey);
    final encThumb = cipher.transform(
      key: keys.encKey,
      iv: header.ivThumb,
      data: thumbPlain,
    );
    final payloadLength =
        head.length + _mac + encThumb.length + _mac + originalLength;

    final out = _Out(file, segmented: jpeg != null);
    if (jpeg != null) {
      out.raw(const [0xFF, 0xD8]);
      for (final segment in jpeg.segments) {
        if (segment.marker == jpegCarrierMarker) continue;
        final length = segment.data.length + 2;
        out
          ..raw([0xFF, segment.marker, (length >> 8) & 0xFF, length & 0xFF])
          ..raw(segment.data);
      }
    } else {
      final box = ByteData(16)
        ..setUint32(0, 1)
        ..setUint32(4, 0x66726565) // 'free'
        ..setUint64(8, 16 + mp4CarrierTag.length + payloadLength);
      out
        ..raw(decoy)
        ..raw(box.buffer.asUint8List())
        ..raw(mp4CarrierTag);
    }
    out
      ..startPayload(payloadLength)
      ..payload(head)
      ..payload(vaultHmacParts(keys.macKey, [head, encThumb]))
      ..payload(encThumb);
    final macAt = out.payload(Uint8List(_mac));

    late Digest digest;
    final mac = Hmac(sha256, keys.macKey).startChunkedConversion(
      ChunkedConversionSink<Digest>.withCallback((d) => digest = d.single),
    )..add(head);
    for (var at = 0; at < originalLength; at += streamChunk) {
      final want = originalLength - at < streamChunk
          ? originalLength - at
          : streamChunk;
      final plain = source.readSync(want);
      if (plain.length != want) {
        throw const FileSystemException('original changed while read');
      }
      final sealed = ctrAt(
        cipher,
        key: keys.encKey,
        iv: header.ivFull,
        offset: at,
        data: plain,
      );
      mac.add(sealed);
      out.payload(sealed);
    }
    mac.close();
    if (jpeg != null) out.raw(jpeg.scanOnward);
    out.patch(macAt, Uint8List.fromList(digest.bytes));
    file.flushSync();
    done = true;
    return true;
  } finally {
    file.closeSync();
    source.closeSync();
    if (!done) File(outPath).deleteSync();
  }
}

/// Where a carrier file keeps its payload: pieces of the file, in order,
/// as [payloadOf] would join them. Null for an ordinary file.
List<(int, int)>? payloadSpans(RandomAccessFile file) {
  final length = file.lengthSync();
  file.setPositionSync(0);
  final start = file.readSync(2);
  if (start.length == 2 && start[0] == 0xFF && start[1] == 0xD8) {
    final jpeg = _jpegSpans(file, length);
    // A JPEG never falls through to MP4, as in [payloadOf].
    if (jpeg != null) return jpeg.isEmpty ? null : jpeg;
  }
  return _mp4Span(file, length);
}

List<(int, int)>? _jpegSpans(RandomAccessFile file, int length) {
  final spans = <(int, int)>[];
  var i = 2;
  while (i + 3 < length) {
    file.setPositionSync(i);
    final h = file.readSync(4);
    if (h.length < 4 || h[0] != 0xFF) return null;
    if (h[1] == _sos || h[1] == _eoi) return spans;
    final size = (h[2] << 8) | h[3];
    if (size < 2 || i + 2 + size > length) return null;
    if (h[1] == jpegCarrierMarker && size > 2) spans.add((i + 4, size - 2));
    i += 2 + size;
  }
  return null;
}

/// The last tagged `free` box, as [mp4CarrierPayload] picks it.
List<(int, int)>? _mp4Span(RandomAccessFile file, int length) {
  if (length < 8) return null;
  (int, int)? found;
  var at = 0;
  var first = true;
  while (at + 8 <= length) {
    file.setPositionSync(at);
    final h = file.readSync(16);
    final view = ByteData.sublistView(h);
    var size = view.getUint32(0);
    final type = String.fromCharCodes(h.sublist(4, 8));
    var headerSize = 8;
    if (size == 1) {
      if (at + 16 > length || h.length < 16) return null;
      size = view.getUint64(8);
      headerSize = 16;
    } else if (size == 0) {
      size = length - at;
    }
    if (size < headerSize || at + size > length) return null;
    if (first && type != 'ftyp') return null;
    first = false;
    if (type == 'free') {
      final large = size >= (1 << 32) || headerSize == 16;
      final body = at + (large ? 16 : 8);
      if (body + mp4CarrierTag.length <= at + size) {
        file.setPositionSync(body);
        final tag = file.readSync(mp4CarrierTag.length);
        var same = tag.length == mp4CarrierTag.length;
        for (var k = 0; same && k < tag.length; k++) {
          same = tag[k] == mp4CarrierTag[k];
        }
        if (same) {
          final from = body + mp4CarrierTag.length;
          found = (from, at + size - from);
        }
      }
    }
    at += size;
  }
  return found == null ? null : [found];
}

/// Reads the payload's bytes by their offset in it, across its spans.
class _Payload {
  _Payload(this.file, this.spans)
    : length = spans.fold(0, (sum, s) => sum + s.$2);

  final RandomAccessFile file;
  final List<(int, int)> spans;
  final int length;

  Uint8List read(int offset, int count) {
    final out = Uint8List(count);
    var filled = 0;
    var base = 0;
    for (final (position, size) in spans) {
      if (filled == count) break;
      final end = base + size;
      final from = offset + filled;
      if (from < end) {
        final skip = from - base;
        final take = count - filled < size - skip
            ? count - filled
            : size - skip;
        file.setPositionSync(position + skip);
        final got = file.readIntoSync(out, filled, filled + take);
        if (got != take) throw const FileSystemException('carrier shrank');
        filled += take;
      }
      base = end;
    }
    if (filled != count) throw RangeError('past the payload');
    return out;
  }
}

/// [openCarrier] over the file at [path], the MAC checked over a stream
/// before anything is decrypted. With [toPath] the original is written to
/// the path it names for its extension, and [OpenedCarrier.original] is
/// empty; otherwise it is read into one buffer. Null when [keys] do not
/// open it.
OpenedCarrier? openCarrierFile({
  required VaultCipher cipher,
  required CarrierKeys keys,
  required String path,
  String Function(String extension)? toPath,
}) {
  final file = File(path).openSync();
  try {
    final spans = payloadSpans(file);
    if (spans == null) return null;
    final payload = _Payload(file, spans);
    if (payload.length < 1) return null;
    final first = payload.read(
      0,
      payload.length < headerBytesV2 ? payload.length : headerBytesV2,
    );
    final header = CarrierHeader.parse(first);
    if (header == null) return null;
    final head = Uint8List.sublistView(first, 0, header.length);
    if (!headerBelongsTo(header, keys.macKey)) return null;
    final fullMacAt = header.length + _mac + header.thumbLength;
    final fullAt = fullMacAt + _mac;
    final length = header.originalLength;
    if (length < 0 || payload.length < fullAt + length) return null;

    late Digest digest;
    final mac = Hmac(sha256, keys.macKey).startChunkedConversion(
      ChunkedConversionSink<Digest>.withCallback((d) => digest = d.single),
    )..add(head);
    for (var at = 0; at < length; at += streamChunk) {
      final take = length - at < streamChunk ? length - at : streamChunk;
      mac.add(payload.read(fullAt + at, take));
    }
    mac.close();
    if (!bytesMatch(payload.read(fullMacAt, _mac), digest.bytes)) return null;

    Uint8List chunk(int at) => ctrAt(
      cipher,
      key: keys.encKey,
      iv: header.ivFull,
      offset: at,
      data: payload.read(
        fullAt + at,
        length - at < streamChunk ? length - at : streamChunk,
      ),
    );
    if (toPath == null) {
      final original = Uint8List(length);
      for (var at = 0; at < length; at += streamChunk) {
        original.setAll(at, chunk(at));
      }
      return OpenedCarrier(original: original, extension: header.extension);
    }
    final target = toPath(header.extension);
    final part = '$target.part';
    final out = File(part).openSync(mode: FileMode.write);
    var done = false;
    try {
      for (var at = 0; at < length; at += streamChunk) {
        out.writeFromSync(chunk(at));
      }
      out.flushSync();
      done = true;
    } finally {
      out.closeSync();
      // Half a hidden photo in the clear is not left behind.
      if (!done) File(part).deleteSync();
    }
    File(part).renameSync(target);
    return OpenedCarrier(original: Uint8List(0), extension: header.extension);
  } finally {
    file.closeSync();
  }
}
