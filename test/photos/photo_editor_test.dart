import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:bring_your_own_photos/photos/photo_editor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main() {
  Uint8List sourceJpg() {
    final image = img.Image(width: 40, height: 20);
    img.fill(image, color: img.ColorRgb8(10, 120, 250));
    return Uint8List.fromList(img.encodeJpg(image));
  }

  test('rotating a quarter turn swaps the dimensions', () async {
    final rotated = await rotateImage(
      bytes: sourceJpg(),
      degrees: 90,
      extension: '.jpg',
    );

    final decoded = img.decodeImage(rotated!)!;
    expect(decoded.width, 20);
    expect(decoded.height, 40);
  });

  test('cropping keeps the fraction of the source it was given', () async {
    final cropped = await cropImage(
      bytes: sourceJpg(),
      fraction: const Rect.fromLTRB(0, 0, 0.5, 1),
      extension: '.jpg',
    );

    final decoded = img.decodeImage(cropped!)!;
    expect(decoded.width, 20);
    expect(decoded.height, 20);
  });

  test(
    're-encodes in the source format so an edit keeps its extension',
    () async {
      final png = Uint8List.fromList(
        img.encodePng(img.Image(width: 8, height: 8)),
      );

      final rotated = await rotateImage(
        bytes: png,
        degrees: 90,
        extension: '.png',
      );

      expect(img.findFormatForData(rotated!), img.ImageFormat.png);
    },
  );
}
