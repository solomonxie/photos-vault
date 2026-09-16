import 'package:flutter/services.dart';

/// One label Vision put on a photo.
class VisionLabel {
  const VisionLabel(this.label, this.confidence);

  final String label;
  final double confidence;
}

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
}

class VisionAnalysis {
  const VisionAnalysis({this.labels = const [], this.faces = const []});

  final List<VisionLabel> labels;
  final List<VisionFace> faces;
}

/// Photo analysis that runs on the phone: Apple's Vision framework, via
/// `ios/Runner/VisionAnalysisChannel.swift`.
///
/// It exists because the cloud path doesn't scale to the library this app
/// is for. Analysing a hundred thousand photos through a vision API is a
/// bill nobody wants; the same hundred thousand run locally cost nothing
/// but time, need no key, work on a plane, and send not one byte anywhere.
/// Nothing is downloaded either — the models are part of iOS.
///
/// Unavailable off iOS (and in tests), where every call returns empty
/// rather than throwing: analysis is an enrichment, and a library without
/// it is a library that simply has no tags yet.
class OnDeviceVisionService {
  OnDeviceVisionService({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName);

  static const channelName = 'byo.photos/vision';

  final MethodChannel _channel;

  /// Below this, Vision's guesses stop being worth showing to anyone. It
  /// returns a confidence for all ~1,300 labels it knows, most of them
  /// near zero, so a cut-off is the whole difference between tags and
  /// noise.
  static const minConfidence = 0.4;

  /// Vision's labels run from the specific ("golden retriever") to the
  /// nearly contentless ("outdoor", "plant"). The vague ones are true of
  /// half a camera roll and make a tag list useless as a filter.
  static const _uselessLabels = {
    'outdoor',
    'indoor',
    'people',
    'adult',
    'material',
    'structure',
    'plant',
    'object',
    'nature',
    'daylight',
    'sky',
  };

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

  /// Labels worth keeping for [path], strongest first.
  Future<List<VisionLabel>> classify(String path, {int limit = 20}) async {
    final raw = await _invoke('classify', {'path': path, 'limit': limit});
    return [
      for (final item in raw)
        if (item is Map &&
            item['label'] is String &&
            (item['confidence'] as num? ?? 0) >= minConfidence &&
            !_uselessLabels.contains(item['label']))
          VisionLabel(
            item['label'] as String,
            (item['confidence'] as num).toDouble(),
          ),
    ];
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

  Future<VisionAnalysis> analyze(String path) async =>
      VisionAnalysis(labels: await classify(path), faces: await faces(path));

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
