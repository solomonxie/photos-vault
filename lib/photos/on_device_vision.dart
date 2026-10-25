import 'package:flutter/services.dart';

import 'person.dart';

/// Where a face is in a photo, in Vision's normalised coordinates
/// (0–1, origin bottom-left).
class VisionFace {
  const VisionFace({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  final double x;
  final double y;
  final double width;
  final double height;

  /// Roughly how much of the frame this face fills — what tells a portrait
  /// from a crowd in the background.
  double get area => width * height;

  /// The same box in image coordinates (origin top-left), which is how a
  /// person's avatar records which face is theirs.
  FaceRect toPersonFace() => FaceRect(x, 1 - y - height, width, height);
}

/// Face detection on the phone: Apple's Vision framework, via
/// `ios/Runner/VisionAnalysisChannel.swift`.
///
/// Free, offline, nothing downloaded — the models are part of iOS — and
/// reliable in a way its scene *labels* were not, which is why only this
/// half survived contact with a real library.
///
/// Unavailable off iOS (and in tests), where every call returns empty
/// rather than throwing: analysis is an enrichment, and a library without
/// it is a library that simply has no tags yet.
class OnDeviceVisionService {
  OnDeviceVisionService({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName);

  static const channelName = 'byo.photos/vision';

  final MethodChannel _channel;

  /// Every method below takes a *source*: a file path, or a camera-roll
  /// asset named through this. An asset is rendered natively, straight
  /// into Vision at the size it uses — no full-size JPEG in tmp (BG-10).
  /// Files stay for what has no PhotoKit asset: held and hidden photos,
  /// manual adds.
  static String assetSource(String libraryId) => '$_assetScheme$libraryId';

  static bool isAssetSource(String source) => source.startsWith(_assetScheme);

  static const _assetScheme = 'photokit:';

  static Map<String, Object?> _source(String source) => isAssetSource(source)
      ? {'asset': source.substring(_assetScheme.length)}
      : {'path': source};

  Future<bool> get isAvailable async {
    try {
      await _channel.invokeMethod<List<Object?>>('faces', {'path': ''});
      return true;
    } on MissingPluginException {
      return false;
    } catch (_) {
      // Reached the platform and it complained about the empty path, which
      // is all this needed to know.
      return true;
    }
  }

  /// The file's EXIF orientation (1–8), from its header; null off iOS.
  Future<int?> orientation(String path) async {
    try {
      return await _channel.invokeMethod<int>('orientation', _source(path));
    } catch (_) {
      return null;
    }
  }

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
        ..._source(path),
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

  Future<List<VisionFace>> faces(String path) async =>
      await facesOrNull(path) ?? const [];

  /// [faces], or null when the platform couldn't read [source]: a skip,
  /// never "no faces".
  Future<List<VisionFace>?> facesOrNull(String source) async {
    try {
      final raw = await _channel.invokeListMethod<Object?>(
        'faces',
        _source(source),
      );
      if (raw == null) return null;
      return [
        for (final item in raw)
          if (item is Map) _faceOf(item),
      ];
    } catch (_) {
      return null;
    }
  }

  static VisionFace _faceOf(Map<Object?, Object?> item) => VisionFace(
    x: (item['x'] as num? ?? 0).toDouble(),
    y: (item['y'] as num? ?? 0).toDouble(),
    width: (item['width'] as num? ?? 0).toDouble(),
    height: (item['height'] as num? ?? 0).toDouble(),
  );
}
