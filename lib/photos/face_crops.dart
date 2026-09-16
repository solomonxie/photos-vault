import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import 'on_device_vision.dart';

/// Cuts the detected faces out of a photo so they can be shown and tapped.
///
/// The app can find faces for free (Vision) but can't tell whose they are —
/// iOS keeps face *identity* to itself, and a model that could do it is a
/// download and a pile of clustering nobody asked for. So the face is the
/// question and the user is the answer: here's a face, who is this? One tap
/// links it to a person, which is both more accurate than any clustering
/// and, for the handful of people anyone actually tags, no slower.
class FaceCrops {
  /// How much room to leave around Vision's box. It hugs the features, and
  /// a crop that tight is a nose and two eyes — hard to recognise at
  /// thumbnail size. Some hair and chin makes it a person.
  static const padding = 0.45;

  static const _outputSize = 160;

  /// One square thumbnail per face, in the order Vision found them.
  /// Silently short on anything it can't decode — a missing crop is a face
  /// you can't tag, not an error worth a dialog.
  static Future<List<Uint8List>> of(String path, List<VisionFace> faces) async {
    if (faces.isEmpty) return const [];
    try {
      final bytes = await File(path).readAsBytes();
      return await compute(_cropAll, (bytes, faces.map(_toRect).toList()));
    } catch (_) {
      return const [];
    }
  }

  /// Vision measures from the bottom-left in 0–1; images are indexed from
  /// the top-left in pixels.
  static _NormalisedRect _toRect(VisionFace face) => (
    x: face.x,
    y: 1 - face.y - face.height,
    width: face.width,
    height: face.height,
  );
}

typedef _NormalisedRect = ({double x, double y, double width, double height});

/// Runs off the UI isolate: decoding a full-size photo to cut four
/// thumbnails out of it is easily a dropped frame otherwise.
List<Uint8List> _cropAll((Uint8List, List<_NormalisedRect>) args) {
  final decoded = img.decodeImage(args.$1);
  if (decoded == null) return const [];
  final crops = <Uint8List>[];
  for (final rect in args.$2) {
    final side = (rect.width * decoded.width * (1 + FaceCrops.padding * 2))
        .round();
    final height = (rect.height * decoded.height * (1 + FaceCrops.padding * 2))
        .round();
    final box = side > height ? side : height;
    if (box <= 0) continue;
    final centreX = (rect.x + rect.width / 2) * decoded.width;
    final centreY = (rect.y + rect.height / 2) * decoded.height;
    final left = (centreX - box / 2).round().clamp(0, decoded.width - 1);
    final top = (centreY - box / 2).round().clamp(0, decoded.height - 1);
    final cropped = img.copyCrop(
      decoded,
      x: left,
      y: top,
      width: box.clamp(1, decoded.width - left),
      height: box.clamp(1, decoded.height - top),
    );
    crops.add(
      Uint8List.fromList(
        img.encodeJpg(
          img.copyResize(
            cropped,
            width: FaceCrops._outputSize,
            height: FaceCrops._outputSize,
          ),
          quality: 80,
        ),
      ),
    );
  }
  return crops;
}
