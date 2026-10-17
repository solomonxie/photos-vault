import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Decodes a still this app can actually be handed — JPEG, PNG, WebP, GIF
/// or BMP — dispatched on the file's magic bytes. Null for anything else,
/// which every caller already treats as "not a still image".
///
/// Deliberately *not* `img.decodeImage`, which identifies the format by
/// offering the bytes to every decoder the `image` package has. Because it
/// reaches all of them, AOT compilation has to keep all of them — TIFF,
/// PSD, EXR, PVR, TGA, ICO, PNM — none of which this app ever sees. See
/// CLAUDE.md's size budget.
///
/// HEIC isn't in the list because `image` has never decoded it either: the
/// OS hands those over through `photo_manager`, already decoded.
img.Image? decodePhoto(Uint8List bytes) {
  if (bytes.length < 12) return null;
  bool startsWith(List<int> magic, [int at = 0]) {
    for (var i = 0; i < magic.length; i++) {
      if (bytes[at + i] != magic[i]) return false;
    }
    return true;
  }

  // Read from the header first: a huge panorama or PNG decodes to
  // hundreds of MB, and jetsam takes the whole app (05#18).
  if ((pixelsOf(bytes) ?? 0) > maxDecodePixels) return null;
  if (startsWith([0xFF, 0xD8, 0xFF])) return img.decodeJpg(bytes);
  if (startsWith([0x89, 0x50, 0x4E, 0x47])) return img.decodePng(bytes);
  if (startsWith([0x47, 0x49, 0x46, 0x38])) return img.decodeGif(bytes);
  if (startsWith([0x52, 0x49, 0x46, 0x46]) &&
      startsWith([0x57, 0x45, 0x42, 0x50], 8)) {
    return img.decodeWebP(bytes);
  }
  if (startsWith([0x42, 0x4D])) return img.decodeBmp(bytes);
  return null;
}

/// The most pixels [decodePhoto] will decode: about 400 MB as RGBA.
const maxDecodePixels = 100 * 1000 * 1000;

/// Width × height from the file header, or null when it can't be read.
int? pixelsOf(Uint8List b) {
  int be16(int i) => b[i] << 8 | b[i + 1];
  int le16(int i) => b[i] | b[i + 1] << 8;
  int le24(int i) => b[i] | b[i + 1] << 8 | b[i + 2] << 16;
  int be32(int i) => be16(i) << 16 | be16(i + 2);
  int le32(int i) => (le16(i) | le16(i + 2) << 16).toSigned(32);
  final n = b.length;
  if (n < 12) return null;
  if (b[0] == 0xFF && b[1] == 0xD8) {
    var i = 2;
    while (i + 9 < n) {
      if (b[i] != 0xFF) return null;
      final marker = b[i + 1];
      if (marker == 0xFF) {
        i++;
        continue;
      }
      if (marker == 0x01 || (marker >= 0xD0 && marker <= 0xD8)) {
        i += 2;
        continue;
      }
      if (marker >= 0xC0 &&
          marker <= 0xCF &&
          marker != 0xC4 &&
          marker != 0xC8 &&
          marker != 0xCC) {
        return be16(i + 5) * be16(i + 7);
      }
      i += 2 + be16(i + 2);
    }
    return null;
  }
  if (b[0] == 0x89 && b[1] == 0x50 && n >= 24) return be32(16) * be32(20);
  if (b[0] == 0x47 && b[1] == 0x49) return le16(6) * le16(8);
  if (b[0] == 0x42 && b[1] == 0x4D && n >= 26) {
    return le32(18).abs() * le32(22).abs();
  }
  if (b[0] == 0x52 && b[8] == 0x57 && n >= 30) {
    final chunk = String.fromCharCodes(b.sublist(12, 16));
    if (chunk == 'VP8X') return (1 + le24(24)) * (1 + le24(27));
    if (chunk == 'VP8L') {
      final w = 1 + (b[21] | (b[22] & 0x3F) << 8);
      final h = 1 + (b[22] >> 6 | b[23] << 2 | (b[24] & 0x0F) << 10);
      return w * h;
    }
    if (chunk == 'VP8 ') return (le16(26) & 0x3FFF) * (le16(28) & 0x3FFF);
  }
  return null;
}

/// Longest edge, in pixels, of a generated thumbnail. A 4-across grid tile
/// is ~100pt, so 320px still covers 3x retina with room to spare — and at
/// [thumbnailQuality] that lands around 15-30 KB a photo rather than the
/// hundreds of KB a full-size re-encode costs.
const thumbnailMaxEdge = 320;

/// Low enough to keep thumbnails tiny, high enough that a grid tile doesn't
/// visibly block up. PhotoKit's thumbnails are asked for at this too.
const thumbnailQuality = 70;

/// Decodes [bytes] and re-encodes a [thumbnailMaxEdge]-bounded JPEG, or
/// returns the bytes unchanged when the image is already within that bound
/// (no point re-compressing something small). Null if [bytes] isn't a
/// decodable still image — videos have no thumbnail pipeline yet (T2.3
/// needs a frame extractor), so they keep the grid's play-icon placeholder.
/// Pure Dart, no Flutter dependency, so it runs on `Isolate.run`.
Uint8List? encodeThumbnail(Uint8List bytes, {int? maxBytes}) {
  final decoded = decodePhoto(bytes);
  if (decoded == null) return null;
  final longestEdge = decoded.width > decoded.height
      ? decoded.width
      : decoded.height;
  var out = longestEdge <= thumbnailMaxEdge
      ? bytes
      : _encodeAt(decoded, thumbnailMaxEdge, thumbnailQuality);
  if (maxBytes == null || out.length <= maxBytes) return out;
  // A small photo is its own thumbnail above, bytes and all — and a
  // 320px file can still be 100 KB. Where the caller has a byte budget
  // (a carrier's first 64 KB), re-encode down until it fits.
  for (final (edge, quality) in const [
    (thumbnailMaxEdge, thumbnailQuality),
    (thumbnailMaxEdge, 50),
    (240, 50),
    (160, 40),
  ]) {
    out = _encodeAt(decoded, edge, quality);
    if (out.length <= maxBytes) return out;
  }
  return null;
}

Uint8List _encodeAt(img.Image decoded, int edge, int quality) {
  final longest = decoded.width > decoded.height
      ? decoded.width
      : decoded.height;
  final sized = longest <= edge
      ? decoded
      : decoded.width >= decoded.height
      ? img.copyResize(decoded, width: edge)
      : img.copyResize(decoded, height: edge);
  return Uint8List.fromList(img.encodeJpg(sized, quality: quality));
}

/// Re-encodes [bytes], first shrinking the image so its longest edge is at
/// most [maxEdge] (null keeps the pixels as they are): JPEG at
/// [_optimizedQuality], or lossless WebP when it has an alpha channel (the
/// `image` package writes no lossy WebP). Returns the new bytes with their
/// dimensions, or null if [bytes] isn't a decodable still image. Pure Dart,
/// so it runs on `Isolate.run`.
///
/// What the "Optimize Storage" page hands a local copy that's bigger than
/// it needs to be — see `storage_optimizer.dart`.
(Uint8List bytes, int width, int height)? optimizeStill(
  Uint8List bytes, {
  int? maxEdge,
}) {
  final decoded = decodePhoto(bytes);
  if (decoded == null) return null;
  var image = decoded;
  if (maxEdge != null) {
    final longest = image.width > image.height ? image.width : image.height;
    if (longest > maxEdge) {
      image = image.width >= image.height
          ? img.copyResize(image, width: maxEdge)
          : img.copyResize(image, height: maxEdge);
    }
  }
  final out = image.hasAlpha
      ? img.encodeWebP(image)
      : img.encodeJpg(image, quality: _optimizedQuality);
  return (Uint8List.fromList(out), image.width, image.height);
}

const _optimizedQuality = 85;

/// A 64-bit difference hash: near for the same picture at another size or
/// quality, far for the next frame of a burst only when it moved.
int? differenceHash(Uint8List bytes) {
  final decoded = decodePhoto(bytes);
  if (decoded == null) return null;
  final small = img.copyResize(
    decoded,
    width: 9,
    height: 8,
    interpolation: img.Interpolation.average,
  );
  var hash = 0;
  for (var y = 0; y < 8; y++) {
    for (var x = 0; x < 8; x++) {
      final left = small.getPixel(x, y).luminance;
      final right = small.getPixel(x + 1, y).luminance;
      hash = (hash << 1) | (left > right ? 1 : 0);
    }
  }
  return hash;
}

/// 16×16 grey levels: finer than [differenceHash], enough to tell two
/// copies of one frame from the next frame of a burst.
List<int>? greyPrint(Uint8List bytes) {
  final decoded = decodePhoto(bytes);
  if (decoded == null) return null;
  final small = img.copyResize(
    decoded,
    width: 16,
    height: 16,
    interpolation: img.Interpolation.average,
  );
  return [
    for (var y = 0; y < 16; y++)
      for (var x = 0; x < 16; x++) small.getPixel(x, y).luminance.toInt(),
  ];
}

/// Mean grey-level difference, 0–255.
double printDistance(List<int> a, List<int> b) {
  var sum = 0;
  for (var i = 0; i < a.length; i++) {
    sum += (a[i] - b[i]).abs();
  }
  return sum / a.length;
}

int hashDistance(int a, int b) {
  var x = a ^ b;
  var n = 0;
  while (x != 0) {
    x &= x - 1;
    n++;
  }
  return n;
}
