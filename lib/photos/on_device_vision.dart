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

  Future<List<VisionFace>> faces(String path) async {
    final raw = await _invoke('faces', {'path': path});
    return [
      for (final item in raw)
        if (item is Map)
          VisionFace(
            x: (item['x'] as num? ?? 0).toDouble(),
            y: (item['y'] as num? ?? 0).toDouble(),
            width: (item['width'] as num? ?? 0).toDouble(),
            height: (item['height'] as num? ?? 0).toDouble(),
          ),
    ];
  }

  Future<List<Object?>> _invoke(
    String method,
    Map<String, Object?> args,
  ) async {
    try {
      return await _channel.invokeMethod<List<Object?>>(method, args) ??
          const [];
    } catch (_) {
      // Not iOS, an unreadable file, or Vision refused it. An unanalysed
      // photo is a photo without tags, not an error the user has to see.
      return const [];
    }
  }
}
