import 'dart:isolate';

import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;

import 'image_pipeline.dart';

/// Still-image edits (crop, rotate), run off the calling isolate — decode+encode of a full-size photo janks frames otherwise.
/// Re-encodes in the source's own format so an in-place save doesn't leave
/// JPEG bytes inside a `.png`.
///
/// ImageIO first (`ImageEncodeChannel.swift`): it reads HEIC, which the
/// `image` package can't — hidden photos are often stored as HEIF — and
/// keeps EXIF. The Dart path is for what ImageIO can't write (WebP, GIF).

const _channel = MethodChannel('byo.photos/image_encode');

Future<Uint8List?> _editNatively(
  Uint8List bytes, {
  Rect? crop,
  double degrees = 0,
}) async {
  try {
    return await _channel.invokeMethod<Uint8List>('edit', {
      'bytes': bytes,
      if (crop != null) 'crop': [crop.left, crop.top, crop.right, crop.bottom],
      'degrees': degrees,
      'quality': 0.92,
    });
  } catch (_) {
    // No channel (tests), or the platform refused.
    return null;
  }
}

Future<Uint8List?> rotateImage({
  required Uint8List bytes,
  required double degrees,
  required String extension,
}) async =>
    await _editNatively(bytes, degrees: degrees) ??
    await Isolate.run(() {
      final decoded = decodePhoto(bytes);
      if (decoded == null) return null;
      return _encode(img.copyRotate(decoded, angle: degrees), extension);
    });

/// [fraction] is the kept area as 0..1 fractions of the source image, so
/// callers can hand over a rect measured in on-screen pixels.
Future<Uint8List?> cropImage({
  required Uint8List bytes,
  required Rect fraction,
  required String extension,
}) async =>
    await _editNatively(bytes, crop: fraction) ??
    await Isolate.run(() {
      final decoded = decodePhoto(bytes);
      if (decoded == null) return null;
      final x = (fraction.left * decoded.width).round().clamp(
        0,
        decoded.width - 1,
      );
      final y = (fraction.top * decoded.height).round().clamp(
        0,
        decoded.height - 1,
      );
      final width = (fraction.width * decoded.width).round().clamp(
        1,
        decoded.width - x,
      );
      final height = (fraction.height * decoded.height).round().clamp(
        1,
        decoded.height - y,
      );
      final cropped = img.copyCrop(
        decoded,
        x: x,
        y: y,
        width: width,
        height: height,
      );
      return _encode(cropped, extension);
    });

Uint8List _encode(img.Image image, String extension) =>
    switch (extension.toLowerCase()) {
      '.png' => Uint8List.fromList(img.encodePng(image)),
      '.webp' => Uint8List.fromList(img.encodeWebP(image)),
      _ => Uint8List.fromList(img.encodeJpg(image, quality: 92)),
    };
