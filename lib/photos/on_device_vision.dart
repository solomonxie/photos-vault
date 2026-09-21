import 'dart:math' as math;
import 'dart:typed_data';

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

/// What one crop of a photo looks like, as a vector — the thing that makes
/// "is this the same person?" answerable without a face-identity model.
///
/// [revision] is the Vision request revision that produced it. Prints are
/// only comparable within one: a vector from another revision isn't a worse
/// answer, it's a different space, so it's ignored rather than compared.
class FaceDescriptor {
  const FaceDescriptor({required this.vector, required this.revision});

  final Float32List vector;
  final int revision;

  bool get isEmpty => vector.isEmpty;

  /// How the crop was prepared before Vision saw it. Changing that
  /// changes the space as surely as a new Vision revision would, so the
  /// two travel as one number.
  ///
  /// 4 is SFace — a model trained on faces, fed the aligned 112px square
  /// it expects. 2 is Vision's general image print over an *unaligned*
  /// square, which is all a face whose eyes can't be found can get: its
  /// own space, never ranked against a model embedding, so those group
  /// among themselves rather than polluting everything else.
  ///
  /// 3 was the aligned image print — the best that was available before
  /// the model, and strictly worse than 4 now that it exists. Left out of
  /// [livePipelines] so those descriptors are made again rather than
  /// quietly kept.
  static const currentPipeline = 4;

  /// Spaces this build still speaks. A descriptor outside them is
  /// re-described rather than compared.
  static const livePipelines = {2, 4};

  static int combineRevision(int visionRevision, int pipeline) =>
      pipeline * 1000 + visionRevision;

  int get pipeline => revision ~/ 1000;

  /// Described by a preprocessing step this build no longer uses. Worth
  /// describing again — comparing across it would rank an unrelated face
  /// above a real match with no way to tell.
  bool get isStale => !isEmpty && !livePipelines.contains(pipeline);

  /// How far apart two descriptors are, as **cosine distance**: 0 for the
  /// same direction, ~1 for unrelated, 2 for opposite.
  ///
  /// Bounded on purpose. It was plain L2 to begin with, which has no
  /// scale anybody can reason about — the vectors Vision hands back are
  /// roughly unit-length, so real distances sat well under 1 while the
  /// threshold guarding them was 26. Everything passed, and every face
  /// grouped with every other face in the library.
  ///
  /// Computed here rather than through Vision's own `computeDistance` so
  /// matching is testable without a device; the ranking is the same.
  ///
  /// `null` when they can't be compared at all: different revisions,
  /// different lengths, an empty one, or a zero vector with no direction
  /// to speak of.
  double? distanceTo(FaceDescriptor other) {
    if (revision != other.revision) return null;
    if (vector.isEmpty || vector.length != other.vector.length) return null;
    var dot = 0.0;
    var normA = 0.0;
    var normB = 0.0;
    for (var i = 0; i < vector.length; i++) {
      dot += vector[i] * other.vector[i];
      normA += vector[i] * vector[i];
      normB += other.vector[i] * other.vector[i];
    }
    if (normA == 0 || normB == 0) return null;
    return 1 - dot / (math.sqrt(normA) * math.sqrt(normB));
  }

  /// `revision,v0,v1,…` — one column, same trade as [FaceRect.encode].
  Uint8List encode() =>
      vector.buffer.asUint8List(vector.offsetInBytes, vector.lengthInBytes);

  static FaceDescriptor decode(Uint8List? bytes, int revision) {
    if (bytes == null || bytes.lengthInBytes < 4) {
      return FaceDescriptor(vector: Float32List(0), revision: revision);
    }
    return FaceDescriptor(
      vector: Float32List.view(
        Uint8List.fromList(bytes).buffer,
        0,
        bytes.lengthInBytes ~/ 4,
      ),
      revision: revision,
    );
  }
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

  /// Whether the bundled face model is loaded.
  ///
  /// Worth asking out loud: without it faces are still described, just by
  /// the general image descriptor, and a working fallback is
  /// indistinguishable from a working model until the answers are poor
  /// and nobody can say which one produced them.
  Future<bool> get hasFaceModel async => await faceModelStatus == true;

  /// `true`, or why not — a string when the model didn't load. "Off" on
  /// its own is a symptom; this is the cause.
  Future<Object?> get faceModelStatus async {
    try {
      return await _channel.invokeMethod<Object?>('faceModel');
    } catch (e) {
      return '$e';
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

  /// A descriptor for one face, or the whole image when [face] is null.
  ///
  /// Empty off iOS and on anything Vision refuses — a photo without a
  /// descriptor is one the app has no guess about, which is where every
  /// photo starts.
  Future<FaceDescriptor> featurePrint(String path, {FaceRect? face}) async {
    try {
      final raw = await _channel.invokeMapMethod<String, Object?>(
        'featurePrint',
        {
          'path': path,
          if (face != null) ...{
            'x': face.x,
            'y': face.y,
            'width': face.width,
            'height': face.height,
          },
        },
      );
      final vector = raw?['vector'];
      if (vector is! Float32List) return _noDescriptor;
      return FaceDescriptor(
        vector: vector,
        revision: FaceDescriptor.combineRevision(
          (raw?['revision'] as num? ?? 0).toInt(),
          (raw?['pipeline'] as num? ?? FaceDescriptor.currentPipeline).toInt(),
        ),
      );
    } catch (_) {
      // See [_invoke].
      return _noDescriptor;
    }
  }

  static final _noDescriptor = FaceDescriptor(
    vector: Float32List(0),
    revision: 0,
  );

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
