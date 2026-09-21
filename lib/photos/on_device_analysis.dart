import '../storage/asset_record.dart';
import 'person.dart' show FaceRect;
import 'ai_analysis_store.dart';
import 'on_device_vision.dart';

/// Finds the faces in one photo, on the phone.
///
/// It used to suggest tags from Vision's scene labels too. Tried against a
/// real library, those were poor enough to be worse than nothing —
/// confident, plausible and wrong often enough that every tag then had to
/// be checked, which is more work than typing the right one. Tagging is
/// left to the vendor models, which are good at it and are paid for by the
/// photo; faces are left here, where detection is genuinely reliable and
/// genuinely free.
///
/// Identity still isn't answered — iOS won't say whose face it is — so what
/// comes back is "here are the faces", for the user to put names to.
class OnDeviceAnalysisService {
  OnDeviceAnalysisService({
    required this.analysisStore,
    OnDeviceVisionService? vision,
  }) : vision = vision ?? OnDeviceVisionService();

  final AiAnalysisStore analysisStore;
  final OnDeviceVisionService vision;

  /// Vision reports faces down to a few pixels across — a stadium crowd
  /// behind the subject is not "people in this photo" in any sense the
  /// user means, and counting it makes every holiday photo a group shot.
  static const minFaceArea = 0.004;

  /// Vision measures from the bottom-left in 0-1; everything that *draws*
  /// a box — the avatar crop, `FaceCrops` — indexes from the top-left.
  static FaceRect toFaceRect(VisionFace face) =>
      FaceRect(face.x, 1 - face.y - face.height, face.width, face.height);

  Future<List<VisionFace>> analyze(AssetRecord record, String path) async {
    final faces = (await vision.faces(path))
        .where((f) => f.area >= minFaceArea)
        .toList();
    // A photo of a beach is still a photo that's been looked at. Written
    // even at zero, because "no faces here" and "never checked" are the
    // same absence otherwise — and the analyze queue, which asks exactly
    // that question to decide what's left, would hand this photo back to
    // itself forever.
    //
    // The count is what the People/Events smart collections read. Written
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
