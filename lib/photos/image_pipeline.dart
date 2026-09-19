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

/// Decodes [bytes] as a still image and re-encodes it as lossy WebP —
/// smaller than the equivalent JPEG at similar visual quality, powering
/// the "Optimized" [BackupFormat](../settings/backup_targets_store.dart).
/// Returns null if [bytes] isn't a decodable still image (e.g. it's a
/// video file); the caller falls back to the original bytes in that case.
/// Pure Dart, no Flutter dependency, so it can run on `Isolate.run` off
/// the calling isolate — decode+encode of a full-size photo is heavy
/// enough to jank a frame otherwise.
Uint8List? reencodeAsWebP(Uint8List bytes) {
  final decoded = decodePhoto(bytes);
  if (decoded == null) return null;
  return Uint8List.fromList(img.encodeWebP(decoded));
}

/// Longest edge, in pixels, of a generated thumbnail. A 4-across grid tile
/// is ~100pt, so 320px still covers 3x retina with room to spare — and at
/// [_thumbnailQuality] that lands around 15-30 KB a photo rather than the
/// hundreds of KB a full-size re-encode costs.
const thumbnailMaxEdge = 320;

/// Low enough to keep thumbnails tiny, high enough that a grid tile doesn't
/// visibly block up.
const _thumbnailQuality = 70;

/// At or below this, a file is already thumbnail-sized: it still gets a
/// local cache copy (so the grid can draw it once the original is deleted
/// locally) but no separate `thumbnails/` upload, since the `originals/`
/// copy is no bigger.
const thumbnailSizeThresholdBytes = 64 * 1024;

/// Decodes [bytes] and re-encodes a [thumbnailMaxEdge]-bounded JPEG, or
/// returns the bytes unchanged when the image is already within that bound
/// (no point re-compressing something small). Null if [bytes] isn't a
/// decodable still image — videos have no thumbnail pipeline yet (T2.3
/// needs a frame extractor), so they keep the grid's play-icon placeholder.
/// Pure Dart, no Flutter dependency, so it runs on `Isolate.run`.
Uint8List? encodeThumbnail(Uint8List bytes) {
  final decoded = decodePhoto(bytes);
  if (decoded == null) return null;
  final longestEdge = decoded.width > decoded.height
      ? decoded.width
      : decoded.height;
  if (longestEdge <= thumbnailMaxEdge) return bytes;
  final resized = decoded.width >= decoded.height
      ? img.copyResize(decoded, width: thumbnailMaxEdge)
      : img.copyResize(decoded, height: thumbnailMaxEdge);
  return Uint8List.fromList(img.encodeJpg(resized, quality: _thumbnailQuality));
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
