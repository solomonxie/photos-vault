import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:image/image.dart' as img;

import 'image_pipeline.dart';

/// Still-image edits (crop, rotate) in pure Dart, run off the calling
/// isolate — decode+encode of a full-size photo janks frames otherwise.
/// Re-encodes in the source's own format so an in-place save doesn't leave
/// JPEG bytes inside a `.png`.

Future<Uint8List?> rotateImage({
  required Uint8List bytes,
  required double degrees,
  required String extension,
}) => Isolate.run(() {
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
}) => Isolate.run(() {
  final decoded = decodePhoto(bytes);
  if (decoded == null) return null;
  final x = (fraction.left * decoded.width).round().clamp(0, decoded.width - 1);
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
