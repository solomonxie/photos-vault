import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Decodes [bytes] as a still image and re-encodes it as lossy WebP —
/// smaller than the equivalent JPEG at similar visual quality, powering
/// the "Optimized" [BackupFormat](../settings/backup_targets_store.dart).
/// Returns null if [bytes] isn't a decodable still image (e.g. it's a
/// video file); the caller falls back to the original bytes in that case.
/// Pure Dart, no Flutter dependency, so it can run on `Isolate.run` off
/// the calling isolate — decode+encode of a full-size photo is heavy
/// enough to jank a frame otherwise.
Uint8List? reencodeAsWebP(Uint8List bytes) {
  final decoded = img.decodeImage(bytes);
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
  final decoded = img.decodeImage(bytes);
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
