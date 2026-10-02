import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:image/image.dart' as img;

/// How small "Export Smaller" makes a photo: the longest edge, in pixels.
enum ExportSize {
  large(2048),
  medium(1280),
  small(640);

  const ExportSize(this.maxEdge);

  final int maxEdge;
}

const _quality = 82;

/// [bytes] as a JPEG no longer than [size] on its longest edge, or null when
/// they aren't a still the platform can decode.
///
/// Decoded by the engine (ImageIO on iOS, so HEIC works — the `image`
/// package has never read it), downsampled *during* the decode rather than
/// after, then JPEG-encoded on an isolate: CLAUDE.md, nothing heavy on the
/// UI isolate.
Future<Uint8List?> shrinkPhoto(Uint8List bytes, ExportSize size) async {
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  ui.Image? image;
  try {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    final (w, h) = fitWithin(descriptor.width, descriptor.height, size.maxEdge);
    codec = await descriptor.instantiateCodec(targetWidth: w, targetHeight: h);
    image = (await codec.getNextFrame()).image;
    final rgba = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (rgba == null) return null;
    final width = image.width;
    final height = image.height;
    final pixels = rgba.buffer.asUint8List();
    return await Isolate.run(
      () => encodeRgbaAsJpeg(pixels, width: width, height: height),
    );
  } catch (_) {
    return null;
  } finally {
    image?.dispose();
    codec?.dispose();
    descriptor?.dispose();
  }
}

/// The size [width]×[height] scales to so its longest edge is at most
/// [maxEdge]; unchanged when it already is.
(int, int) fitWithin(int width, int height, int maxEdge) {
  final longest = math.max(width, height);
  if (longest <= maxEdge || longest == 0) return (width, height);
  final scale = maxEdge / longest;
  return (
    math.max(1, (width * scale).round()),
    math.max(1, (height * scale).round()),
  );
}

Uint8List encodeRgbaAsJpeg(
  Uint8List rgba, {
  required int width,
  required int height,
}) {
  final image = img.Image.fromBytes(
    width: width,
    height: height,
    bytes: rgba.buffer,
    numChannels: 4,
  );
  return Uint8List.fromList(img.encodeJpg(image, quality: _quality));
}
