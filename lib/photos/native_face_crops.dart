import 'package:flutter/services.dart';

import 'person.dart';

/// Face thumbnails cut on the phone, via
/// `ios/Runner/FaceCropChannel.swift`. The boxes come from the face import;
/// nothing here finds faces.
///
/// Off iOS (and in tests) every call returns null rather than throwing.
class NativeFaceCrops {
  NativeFaceCrops({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName);

  static const channelName = 'byo.photos/vision';

  final MethodChannel _channel;

  /// Square JPEG crops of [faces], cut natively from the upright picture
  /// (05#15: HEIC works, no Dart decode). Null when the platform can't.
  Future<List<Uint8List>?> crops(
    String path,
    List<FaceRect> faces, {
    required double padding,
    required int side,
  }) async {
    try {
      final raw = await _channel.invokeListMethod<Object?>('crops', {
        'path': path,
        'faces': [
          for (final f in faces) [f.x, f.y, f.width, f.height],
        ],
        'padding': padding,
        'side': side,
      });
      if (raw == null || raw.length != faces.length) return null;
      final out = [for (final item in raw) ?(item is Uint8List ? item : null)];
      return out.length == faces.length ? out : null;
    } catch (_) {
      return null;
    }
  }
}
