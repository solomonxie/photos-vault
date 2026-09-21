import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import 'image_pipeline.dart';

import 'person.dart' show FaceRect;

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

  /// How much room to leave around a box being *described* rather than
  /// shown. Much tighter than [padding]: the descriptor is a general image
  /// feature print, so whatever else is in the crop is in the answer, and a
  /// generous margin around two people on the same beach describes the
  /// beach. Not zero — Vision's box cuts the chin and hairline off, and
  /// those are face, not background.
  static const descriptorPadding = 0.08;

  /// The box to hand Vision for a descriptor: [face] grown by
  /// [descriptorPadding], squared off, and kept inside the frame.
  static FaceRect descriptorRect(FaceRect face) {
    final side =
        math.max(face.width, face.height) * (1 + descriptorPadding * 2);
    final centreX = face.x + face.width / 2;
    final centreY = face.y + face.height / 2;
    final box = math.min(side, 1.0);
    return FaceRect(
      (centreX - box / 2).clamp(0.0, 1.0 - box),
      (centreY - box / 2).clamp(0.0, 1.0 - box),
      box,
      box,
    );
  }

  /// One square thumbnail per face, in the order they were found.
  /// Silently short on anything it can't decode — a missing crop is a face
  /// you can't tag, not an error worth a dialog.
  ///
  /// Takes [FaceRect], the top-left form that gets stored and drawn, rather
  /// than Vision's bottom-left `VisionFace`: these crops are made both from
  /// a fresh scan and from boxes read back out of the database, and one of
  /// the two would otherwise be flipped.
  static Future<List<Uint8List>> of(String path, List<FaceRect> faces) async {
    if (faces.isEmpty) return const [];
    try {
      final bytes = await File(path).readAsBytes();
      return await compute(_cropAll, (bytes, faces.map(_toRect).toList()));
    } catch (_) {
      return const [];
    }
  }

  static _NormalisedRect _toRect(FaceRect face) =>
      (x: face.x, y: face.y, width: face.width, height: face.height);
}

typedef _NormalisedRect = ({double x, double y, double width, double height});

/// Runs off the UI isolate: decoding a full-size photo to cut four
/// thumbnails out of it is easily a dropped frame otherwise.
List<Uint8List> _cropAll((Uint8List, List<_NormalisedRect>) args) {
  final decoded = decodePhoto(args.$1);
  if (decoded == null) return const [];
  final crops = <Uint8List>[];
  for (final rect in args.$2) {
    final width = rect.width * decoded.width;
    final height = rect.height * decoded.height;
    final padded =
        (width > height ? width : height) * (1 + FaceCrops.padding * 2);
    // Never wider than the photo, and slid back inside it rather than
    // shrunk against its edge — a face at the frame's edge is exactly the
    // group-shot case, and a short-sided crop there resizes to a stretched
    // face. One crop per face either way: the caller pairs them up by
    // index, so a skipped one would name the wrong person.
    final shortest = decoded.width < decoded.height
        ? decoded.width
        : decoded.height;
    final box = padded.round().clamp(1, shortest);
    final centreX = (rect.x + rect.width / 2) * decoded.width;
    final centreY = (rect.y + rect.height / 2) * decoded.height;
    final left = (centreX - box / 2).round().clamp(0, decoded.width - box);
    final top = (centreY - box / 2).round().clamp(0, decoded.height - box);
    final cropped = img.copyCrop(
      decoded,
      x: left,
      y: top,
      width: box,
      height: box,
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
