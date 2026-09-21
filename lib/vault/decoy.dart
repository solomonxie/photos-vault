import 'dart:math';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../photos/image_pipeline.dart';
import 'jpeg_segments.dart';

/// What a carrier looks like from the outside: somebody else's photo.
///
/// Chosen by **file size**, not by time. A decoy taken minutes from the
/// hidden photo would put a timestamp within hours of it on every carrier,
/// which announces when the hidden photo was taken. Size says nothing about
/// time — and it is the axis that makes the object plausible, since the
/// carrier weighs the decoy's resolution plus the payload's bytes. Pick a
/// decoy that really weighs about that much and the result is what a second
/// copy of that photo would weigh.
///
/// The pixels are that photo's *thumbnail*, upscaled. JPEG size tracks
/// detail rather than pixel count, so an upscaled 320 px thumbnail encodes
/// to a few hundred kilobytes even at 12 MP — visibly soft up close,
/// ordinary in a grid, and about a tenth of what a real re-encode costs.
class DecoySource {
  const DecoySource({
    required this.id,
    required this.sizeBytes,
    required this.width,
    required this.height,
    required this.takenAt,
    required this.isVideo,
  });

  final String id;
  final int sizeBytes;
  final int width;
  final int height;
  final DateTime takenAt;
  final bool isVideo;
}

/// The candidate closest in size to [payloadBytes], picked at random from
/// the nearest [spread] so the choice is not reproducible from the library
/// alone. Null when nothing of the right kind is available, which is the
/// signal to refuse the upload rather than invent a decoy that stands out.
DecoySource? chooseDecoy({
  required List<DecoySource> candidates,
  required int payloadBytes,
  required bool wantVideo,
  Map<String, int> usedCounts = const {},
  int spread = 8,
  Random? random,
}) {
  final pool = [
    for (final c in candidates)
      if (c.isVideo == wantVideo && (usedCounts[c.id] ?? 0) < 2) c,
  ];
  if (pool.isEmpty) return null;
  pool.sort(
    (a, b) => (a.sizeBytes - payloadBytes).abs().compareTo(
      (b.sizeBytes - payloadBytes).abs(),
    ),
  );
  final near = pool.take(spread).toList();
  return near[(random ?? Random.secure()).nextInt(near.length)];
}

/// An `APP1` EXIF block carrying nothing but a date — written by hand
/// rather than through the `image` package's Exif encoder, which would drag
/// more of that package into the AOT snapshot than the whole feature is
/// allowed to cost.
Uint8List exifApp1(DateTime when) {
  String two(int v) => v.toString().padLeft(2, '0');
  final stamp =
      '${when.year}:${two(when.month)}:${two(when.day)} '
      '${two(when.hour)}:${two(when.minute)}:${two(when.second)}';
  final text = Uint8List(20)..setAll(0, stamp.codeUnits);

  // Offsets are from the start of the TIFF header, i.e. after "Exif\0\0".
  const ifd0At = 8;
  const exifIfdAt = 38;
  const dateTimeAt = 56;
  const dateTimeOriginalAt = 76;

  final tiff = ByteData(96);
  var at = 0;
  void u16(int v) {
    tiff.setUint16(at, v, Endian.little);
    at += 2;
  }

  void u32(int v) {
    tiff.setUint32(at, v, Endian.little);
    at += 4;
  }

  u16(0x4949); // "II", little-endian
  u16(0x002A);
  u32(ifd0At);

  u16(2); // IFD0 entries
  u16(0x0132); // DateTime
  u16(2); // ASCII
  u32(20);
  u32(dateTimeAt);
  u16(0x8769); // ExifIFDPointer
  u16(4); // LONG
  u32(1);
  u32(exifIfdAt);
  u32(0); // no IFD1

  u16(1); // Exif IFD entries
  u16(0x9003); // DateTimeOriginal
  u16(2);
  u32(20);
  u32(dateTimeOriginalAt);
  u32(0);

  final out = tiff.buffer.asUint8List();
  out.setAll(dateTimeAt, text);
  out.setAll(dateTimeOriginalAt, text);
  return (BytesBuilder()
        ..add('Exif'.codeUnits)
        ..add([0, 0])
        ..add(out))
      .toBytes();
}

/// [thumbnail] blown up to [width] x [height] and encoded as a JPEG wearing
/// [takenAt]. Pure Dart with no Flutter dependency, so it runs on
/// `Isolate.run` — a 12 MP resize is far too heavy for the UI isolate.
Uint8List? buildDecoyJpeg({
  required Uint8List thumbnail,
  required int width,
  required int height,
  required DateTime takenAt,
  int quality = 50,
}) {
  final decoded = decodePhoto(thumbnail);
  if (decoded == null || width <= 0 || height <= 0) return null;
  final resized = img.copyResize(
    decoded,
    width: width,
    height: height,
    interpolation: img.Interpolation.linear,
  );
  final encoded = Uint8List.fromList(img.encodeJpg(resized, quality: quality));
  final parts = parseJpeg(encoded);
  if (parts == null) return encoded;
  return writeJpegSegments(
    JpegParts(
      segments: [
        for (final s in parts.segments)
          if (s.marker != 0xE1) s,
        JpegSegment(0xE1, exifApp1(takenAt)),
      ],
      scanOnward: parts.scanOnward,
    ),
  );
}
