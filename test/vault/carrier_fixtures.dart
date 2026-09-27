import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// A real JPEG, for the decoy half of a carrier. Patterned rather than flat
/// so it survives a re-encode recognisably and weighs something.
Uint8List decoyJpeg({int width = 640, int height = 480}) {
  final image = img.Image(width: width, height: height);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      image.setPixelRgb(x, y, x % 255, y % 255, (x + y) % 255);
    }
  }
  return Uint8List.fromList(img.encodeJpg(image, quality: 50));
}

/// Smallest thing `parseMp4Boxes` accepts: ftyp + mdat + moov.
Uint8List decoyMp4() {
  final out = BytesBuilder();
  void box(String type, List<int> payload) {
    final size = 8 + payload.length;
    out.add([
      (size >> 24) & 0xFF,
      (size >> 16) & 0xFF,
      (size >> 8) & 0xFF,
      size & 0xFF,
      ...type.codeUnits,
      ...payload,
    ]);
  }

  box('ftyp', 'isomiso2avc1'.codeUnits);
  box('mdat', List.filled(2048, 7));
  box('moov', List.filled(512, 3));
  return out.toBytes();
}
