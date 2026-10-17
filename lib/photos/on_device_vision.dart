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

  /// [livePipelines] on a phone where the model didn't load (05#5): the
  /// aligned print is then the best there is, and re-describing it would
  /// only make it again. Nothing is stale until the model is back.
  static const livePipelinesWithoutModel = {2, 3, 4};

  static int combineRevision(int visionRevision, int pipeline) =>
      pipeline * 1000 + visionRevision;

  int get pipeline => revision ~/ 1000;

  /// Described by a preprocessing step this build no longer uses. Worth
  /// describing again — comparing across it would rank an unrelated face
  /// above a real match with no way to tell.
  bool get isStale => isStaleIn(livePipelines);

  bool isStaleIn(Set<int> live) => !isEmpty && !live.contains(pipeline);

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

  /// Why the model didn't load, as the platform said it; null when it
  /// did, or when there's no platform to ask (tests, not iOS).
  Future<String?> get faceModelFailure async {
    try {
      final status = await _channel.invokeMethod<Object?>('faceModel');
      return status is String ? status : null;
    } catch (_) {
      return null;
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

  /// [featurePrint] for every one of [faces], from one decode (05#14).
  /// Same length as [faces]; an empty descriptor where Vision refused.
  Future<List<FaceDescriptor>> featurePrints(
    String path,
    List<FaceRect> faces,
  ) async {
    if (faces.isEmpty) return const [];
    try {
      final raw = await _channel.invokeListMethod<Object?>('featurePrints', {
        ..._source(path),
        'faces': [
          for (final f in faces) [f.x, f.y, f.width, f.height],
        ],
      });
      if (raw != null && raw.length == faces.length) {
        return [for (final item in raw) _descriptorOf(item)];
      }
    } catch (_) {
      // An older platform side, or none: one call per face below.
    }
    return [for (final f in faces) await featurePrint(path, face: f)];
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

  Future<List<VisionFace>> faces(String path) async {
    final raw = await _invoke('faces', _source(path));
    return [
      for (final item in raw)
        if (item is Map) _faceOf(item),
    ];
  }

  static VisionFace _faceOf(Map<Object?, Object?> item) => VisionFace(
    x: (item['x'] as num? ?? 0).toDouble(),
    y: (item['y'] as num? ?? 0).toDouble(),
    width: (item['width'] as num? ?? 0).toDouble(),
    height: (item['height'] as num? ?? 0).toDouble(),
  );

  /// [faces] and, for each one of at least [minArea], the descriptor of
  /// its `FaceCrops.descriptorRect` grown by [padding] — from one picture,
  /// so a photo is rendered once for both (BG-10). Null when the platform
  /// couldn't read it or doesn't know the call: a skip, never "no faces".
  Future<List<({VisionFace face, FaceDescriptor print})>?> facesWithPrints(
    String source, {
    required double minArea,
    required double padding,
  }) async {
    try {
      final raw = await _channel.invokeListMethod<Object?>('facesWithPrints', {
        ..._source(source),
        'minArea': minArea,
        'padding': padding,
      });
      if (raw == null) return null;
      return [
        for (final item in raw)
          if (item is Map)
            (face: _faceOf(item), print: _descriptorOf(item['print'])),
      ];
    } catch (_) {
      return null;
    }
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
          ..._source(path),
          if (face != null) ...{
            'x': face.x,
            'y': face.y,
            'width': face.width,
            'height': face.height,
          },
        },
      );
      return _descriptorOf(raw);
    } catch (_) {
      // See [_invoke].
      return _noDescriptor;
    }
  }

  static FaceDescriptor _descriptorOf(Object? raw) {
    if (raw is! Map) return _noDescriptor;
    final vector = raw['vector'];
    if (vector is! Float32List) return _noDescriptor;
    return FaceDescriptor(
      vector: vector,
      revision: FaceDescriptor.combineRevision(
        (raw['revision'] as num? ?? 0).toInt(),
        (raw['pipeline'] as num? ?? FaceDescriptor.currentPipeline).toInt(),
      ),
    );
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
