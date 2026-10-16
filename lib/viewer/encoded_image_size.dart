import 'dart:typed_data';
import 'dart:ui' as ui;

/// Pixel size from the file header, without decoding a single pixel.
/// `null` when the bytes aren't an image the engine can read.
Future<ui.Size?> encodedImageSize(Uint8List bytes) async {
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  try {
    buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    return ui.Size(descriptor.width.toDouble(), descriptor.height.toDouble());
  } catch (_) {
    return null;
  } finally {
    descriptor?.dispose();
    buffer?.dispose();
  }
}
