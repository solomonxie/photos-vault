import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import 'image_pipeline.dart';
import 'on_device_vision.dart';

import 'person.dart' show FaceRect;

/// Cuts the detected faces out of a photo so they can be shown and tapped.
///
/// The app can find faces for free (Vision); whose they are is the user's
/// answer, helped by the bundled SFace model's guesses. Here's a face, who
/// is this? One tap links it to a person.
class FaceCrops {
  /// How much room to leave around Vision's box. It hugs the features, and
  /// a crop that tight is a nose and two eyes — hard to recognise at
  /// thumbnail size. Some hair and chin makes it a person.
  static const padding = 0.45;

  static const _outputSize = 160;

  /// One square thumbnail per face, in the order they were found.
  /// Silently short on anything it can't decode — a missing crop is a face
  /// you can't tag, not an error worth a dialog.
  ///
  /// Takes [FaceRect], the top-left form that gets stored and drawn, rather
  /// than Vision's bottom-left `VisionFace`: these crops are made both from
  /// a fresh scan and from boxes read back out of the database, and one of
  /// the two would otherwise be flipped.
  ///
  /// Cut natively where there's a platform (05#15): from the upright,
  /// downsampled picture, and HEIC too. The Dart decode is the fallback.
  static Future<List<Uint8List>> of(
    String path,
    List<FaceRect> faces, {
    OnDeviceVisionService? vision,
  }) async {
    if (faces.isEmpty) return const [];
    final native = await (vision ?? OnDeviceVisionService()).crops(
      path,
      faces,
      padding: padding,
      side: _outputSize,
    );
    if (native != null) return native;
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
