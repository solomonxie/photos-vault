import 'dart:typed_data';

import '../vault/carrier_probe.dart';

/// How close a name's date stamp may sit to the time the object reached the
/// bucket before the stamp is taken to *be* that time — an upload or rename
/// stamp, not the camera's. Wider than a day: a rename copies the object,
/// which moves its LastModified on by however long it waited.
const leftoverWindow = Duration(hours: 72);

/// An unclaimed original whose only date is a stamp written when it was
/// uploaded or renamed, with no capture date of its own: most likely an
/// old copy of a photo this library already had, not a new photo.
bool isLikelyLeftover({
  required DateTime? nameStamp,
  required DateTime reference,
  required DateTime? captureDate,
}) {
  if (captureDate != null || nameStamp == null) return false;
  return nameStamp.difference(reference).abs() <= leftoverWindow;
}

/// The camera's own date from a still image's first bytes: EXIF
/// DateTimeOriginal (or DateTime) in a JPEG, a WebP `EXIF` chunk, or a
/// HEIC Exif item when it sits inside [bytes]. Null when none is there.
DateTime? stillCaptureDate(Uint8List bytes) {
  if (_ascii(bytes, 0, 'RIFF') && _ascii(bytes, 8, 'WEBP')) {
    return _webpExifDate(bytes);
  }
  final marker = _indexOf(bytes, const [0x45, 0x78, 0x69, 0x66, 0, 0]);
  if (marker < 0) return null;
  return _tiffDate(bytes, marker + 6);
}

/// `mvhd` creation time from the start of a `moov` box's contents, or null.
DateTime? mvhdCreationTime(Uint8List moov) {
  final view = ByteData.sublistView(moov);
  var at = 0;
  while (at + 8 <= moov.length) {
    final size = view.getUint32(at);
    final type = String.fromCharCodes(moov.sublist(at + 4, at + 8));
    if (type == 'mvhd') {
      if (at + 16 > moov.length) return null;
      final version = moov[at + 8];
      final int seconds;
      if (version == 1) {
        if (at + 20 > moov.length) return null;
        seconds = view.getUint64(at + 12);
      } else {
        seconds = view.getUint32(at + 12);
      }
      if (seconds == 0) return null;
      final when = DateTime.utc(1904).add(Duration(seconds: seconds));
      return when.year < 1971 ? null : when.toLocal();
    }
    if (size < 8) return null;
    at += size;
  }
  return null;
}

/// Walks an MP4/MOV's top-level boxes with small ranged reads to its
/// `moov`, then reads the start of it for `mvhd`. Never the whole file.
Future<DateTime?> videoCaptureDate(RangeReader read, int size) async {
  var at = 0;
  for (var i = 0; i < 64 && at + 8 <= size; i++) {
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
    if (boxSize < headerSize) return null;
    if (type == 'moov') {
      final start = at + headerSize;
      final end = at + boxSize < start + 4096 ? at + boxSize : start + 4096;
      final body = await read(start, end > size ? size : end);
      return body == null ? null : mvhdCreationTime(body);
    }
    at += boxSize;
  }
  return null;
}

DateTime? _webpExifDate(Uint8List bytes) {
  var at = 12;
  while (at + 8 <= bytes.length) {
    final size = ByteData.sublistView(
      bytes,
      at + 4,
      at + 8,
    ).getUint32(0, Endian.little);
    if (_ascii(bytes, at, 'EXIF')) {
      final start = at + 8;
      final exifHeader = _ascii(bytes, start, 'Exif');
      return _tiffDate(bytes, exifHeader ? start + 6 : start);
    }
    at += 8 + size + (size.isOdd ? 1 : 0);
  }
  return null;
}

/// DateTimeOriginal (0x9003) from the Exif IFD, else DateTime (0x0132) from
/// IFD0, out of the TIFF structure starting at [tiff].
DateTime? _tiffDate(Uint8List bytes, int tiff) {
  if (tiff + 8 > bytes.length) return null;
  final Endian endian;
  if (bytes[tiff] == 0x49 && bytes[tiff + 1] == 0x49) {
    endian = Endian.little;
  } else if (bytes[tiff] == 0x4D && bytes[tiff + 1] == 0x4D) {
    endian = Endian.big;
  } else {
    return null;
  }
  final view = ByteData.sublistView(bytes);
  int u16(int at) => view.getUint16(at, endian);
  int u32(int at) => view.getUint32(at, endian);

  ({int? exifIfd, DateTime? original, DateTime? plain}) readIfd(int offset) {
    final at = tiff + offset;
    if (offset <= 0 || at + 2 > bytes.length) {
      return (exifIfd: null, original: null, plain: null);
    }
    final count = u16(at);
    int? exifIfd;
    DateTime? original;
    DateTime? plain;
    for (var i = 0; i < count; i++) {
      final entry = at + 2 + i * 12;
      if (entry + 12 > bytes.length) break;
      final tag = u16(entry);
      if (tag == 0x8769) {
        exifIfd = u32(entry + 8);
      } else if (tag == 0x9003 || tag == 0x0132) {
        final value = tiff + u32(entry + 8);
        final date = value + 19 <= bytes.length
            ? _exifDateTime(String.fromCharCodes(bytes, value, value + 19))
            : null;
        if (tag == 0x9003) {
          original = date;
        } else {
          plain = date;
        }
      }
    }
    return (exifIfd: exifIfd, original: original, plain: plain);
  }

  final ifd0 = readIfd(u32(tiff + 4));
  final exif = ifd0.exifIfd == null ? null : readIfd(ifd0.exifIfd!);
  return exif?.original ?? ifd0.original ?? ifd0.plain;
}

/// `2024:07:04 18:30:05`, the camera's local time.
DateTime? _exifDateTime(String text) {
  final m = RegExp(r'^(\d{4}):(\d{2}):(\d{2}) (\d{2}):(\d{2}):(\d{2})$')
      .firstMatch(text);
  if (m == null) return null;
  final parts = [for (var i = 1; i <= 6; i++) int.parse(m[i]!)];
  if (parts[0] < 1971 || parts[1] < 1 || parts[1] > 12) return null;
  return DateTime(parts[0], parts[1], parts[2], parts[3], parts[4], parts[5]);
}

bool _ascii(Uint8List bytes, int at, String text) {
  if (at + text.length > bytes.length) return false;
  for (var i = 0; i < text.length; i++) {
    if (bytes[at + i] != text.codeUnitAt(i)) return false;
  }
  return true;
}

int _indexOf(Uint8List bytes, List<int> pattern) {
  outer:
  for (var i = 0; i + pattern.length <= bytes.length; i++) {
    for (var j = 0; j < pattern.length; j++) {
      if (bytes[i + j] != pattern[j]) continue outer;
    }
    return i;
  }
  return -1;
}
