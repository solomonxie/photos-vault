import '../storage/asset_record.dart';
import 'person.dart' show FaceRect;
import 'ai_analysis_store.dart';
import 'on_device_vision.dart';

/// Finds the faces in one photo, on the phone.
///
/// It used to suggest tags from Vision's scene labels too. Tried against a
/// real library, those were poor enough to be worse than nothing —
/// confident, plausible and wrong often enough that every tag then had to
/// be checked, which is more work than typing the right one. Tags are typed
/// by the user; faces are left here, where detection is genuinely reliable
/// and genuinely free.
///
/// Identity still isn't answered — iOS won't say whose face it is — so what
/// comes back is "here are the faces", for the user to put names to.
class OnDeviceAnalysisService {
  OnDeviceAnalysisService({
    required this.analysisStore,
    OnDeviceVisionService? vision,
    this.onReoriented,
  }) : vision = vision ?? OnDeviceVisionService();

  final AiAnalysisStore analysisStore;
  final OnDeviceVisionService vision;

  /// Told when a photo's old boxes were turned upright, so whatever else
  /// holds one of them (a person's avatar) can follow.
  final Future<void> Function(String localId, int orientation)? onReoriented;

  /// Turns boxes measured on the raw sensor buffer upright (05#7), once
  /// per photo. False when the orientation can't be read yet.
  Future<bool> settleBoxes(AssetRecord record, String path) async {
    final existing = await analysisStore.get(record.localId);
    if (existing == null || !existing.legacyBoxes) return true;
    final orientation = await vision.orientation(path);
    if (orientation == null) return false;
    await analysisStore.reorientFaces(record.localId, orientation);
    if (orientation > 1) await onReoriented?.call(record.localId, orientation);
    return true;
  }

  /// Vision reports faces down to a few pixels across — a stadium crowd
  /// behind the subject is not "people in this photo" in any sense the
  /// user means, and counting it makes every holiday photo a group shot.
  ///
  /// 0.004 (a face ~6% of the frame across) dropped the people in ordinary
  /// group shots; the faces kept piled up right at that line. ~3% across
  /// still leaves a crowd out.
  static const minFaceArea = 0.001;

  /// Photos looked at under the old, larger cutoff and found empty are
  /// looked at again.
  static final smallerFacesSince = DateTime(2026, 10, 24);

  /// Vision measures from the bottom-left in 0-1; everything that *draws*
  /// a box — the avatar crop, `FaceCrops` — indexes from the top-left.
  static FaceRect toFaceRect(VisionFace face) =>
      FaceRect(face.x, 1 - face.y - face.height, face.width, face.height);

  /// Finds and records [record]'s faces from [source] (a path, or an
  /// `OnDeviceVisionService.assetSource`). Null when an asset couldn't
  /// be rendered: a skip, not "no faces".
  Future<List<VisionFace>?> analyze(AssetRecord record, String source) async {
    // First, so a fresh look can carry names over to boxes in its own space.
    try {
      await settleBoxes(record, source);
    } catch (_) {
      // Left marked; the analyze pass tries again.
    }
    final found = await vision.facesOrNull(source);
    if (found == null && OnDeviceVisionService.isAssetSource(source)) {
      return null;
    }
    final faces = [
      for (final f in found ?? const <VisionFace>[])
        if (f.area >= minFaceArea) f,
    ];
    // A photo of a beach is still a photo that's been looked at. Written
    // even at zero, because "no faces here" and "never checked" are the
    // same absence otherwise — and the analyze queue, which asks exactly
    // that question to decide what's left, would hand this photo back to
    // itself forever.
    //
    // The count is what the People smart collection reads. Written
    // on its own so a suggestion waiting to be reviewed on the same photo
    // isn't overwritten by a pass that knows nothing about it.
    await analysisStore.saveFaceCount(
      localId: record.localId,
      peopleCount: faces.length,
      analyzedAt: DateTime.now(),
      faces: faces.map(toFaceRect).toList(),
    );
    return faces;
  }
}
