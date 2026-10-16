import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:photos_vault/photos/face_crops.dart';
import 'package:photos_vault/photos/image_pipeline.dart';
import 'package:photos_vault/photos/person.dart';

/// A 60x40 raw buffer, white, with a red "face" at [face] (normalised, raw
/// space), tagged with EXIF [orientation] — what a phone camera writes.
Uint8List _fixture(int orientation, FaceRect face) {
  final raw = img.Image(width: 60, height: 40);
  img.fill(raw, color: img.ColorRgb8(255, 255, 255));
  img.fillRect(
    raw,
    x1: (face.x * 60).round(),
    y1: (face.y * 40).round(),
    x2: ((face.x + face.width) * 60).round() - 1,
    y2: ((face.y + face.height) * 40).round() - 1,
    color: img.ColorRgb8(255, 0, 0),
  );
  raw.exif.imageIfd.orientation = orientation;
  return img.encodeJpg(raw, quality: 100);
}

bool _isRed(img.Image image, double x, double y) {
  final pixel = image.getPixel(
    (x * image.width).floor().clamp(0, image.width - 1),
    (y * image.height).floor().clamp(0, image.height - 1),
  );
  return pixel.r > 200 && pixel.g < 90 && pixel.b < 90;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const face = FaceRect(0.1, 0.2, 0.2, 0.4);

  for (var orientation = 1; orientation <= 8; orientation++) {
    test('a raw-buffer box turned upright lands on the face, '
        'orientation $orientation (05#7)', () {
      final upright = decodePhoto(_fixture(orientation, face))!;
      expect(upright.width, orientation >= 5 ? 40 : 60, reason: 'baked');

      final box = face.oriented(orientation);
      expect(
        _isRed(upright, box.x + box.width / 2, box.y + box.height / 2),
        isTrue,
      );
      // Corners just inside the box, and just outside it.
      expect(_isRed(upright, box.x + 0.03, box.y + 0.03), isTrue);
      expect(
        _isRed(upright, box.x + box.width - 0.03, box.y + box.height - 0.03),
        isTrue,
      );
      expect(_isRed(upright, box.x + box.width + 0.06, box.y), isFalse);
    });
  }

  test('crops from an upright box show the face on a rotated photo', () async {
    final dir = Directory.systemTemp.createTempSync('face_orientation_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/portrait.jpg')
      ..writeAsBytesSync(_fixture(6, face));

    final crops = await FaceCrops.of(file.path, [face.oriented(6)]);

    final crop = img.decodeJpg(crops.single)!;
    expect(_isRed(crop, 0.5, 0.5), isTrue);
  });
}
