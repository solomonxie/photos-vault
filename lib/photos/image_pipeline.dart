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

/// Longest edge, in pixels, of a generated thumbnail. A 4-across grid tile
/// is ~100pt, so 320px still covers 3x retina with room to spare — and at
/// [_thumbnailQuality] that lands around 15-30 KB a photo rather than the
/// hundreds of KB a full-size re-encode costs.
const thumbnailMaxEdge = 320;

/// Low enough to keep thumbnails tiny, high enough that a grid tile doesn't
/// visibly block up.
const _thumbnailQuality = 70;

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
      : _encodeAt(decoded, thumbnailMaxEdge, _thumbnailQuality);
  if (maxBytes == null || out.length <= maxBytes) return out;
  // A small photo is its own thumbnail above, bytes and all — and a
  // 320px file can still be 100 KB. Where the caller has a byte budget
  // (a carrier's first 64 KB), re-encode down until it fits.
  for (final (edge, quality) in const [
    (thumbnailMaxEdge, _thumbnailQuality),
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

/// Re-encodes [bytes] as lossy WebP, first shrinking the image so its
/// longest edge is at most [maxEdge] (null keeps the pixels as they are).
/// Returns the new bytes with their dimensions, or null if [bytes] isn't a
/// decodable still image. Pure Dart, so it runs on `Isolate.run`.
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
  return (Uint8List.fromList(img.encodeWebP(image)), image.width, image.height);
}
