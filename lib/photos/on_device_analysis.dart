import '../storage/asset_record.dart';
import 'ai_analysis.dart';
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

  Future<List<VisionFace>> analyze(AssetRecord record, String path) async {
    final faces = (await vision.faces(path))
        .where((f) => f.area >= minFaceArea)
        .toList();
    if (faces.isEmpty) return faces;
    // The count is what the People/Events smart collections read.
    await analysisStore.save(
      AiPhotoAnalysis(
        localId: record.localId,
        peopleCount: faces.length,
        eventLabel: '',
        analyzedAt: DateTime.now(),
      ),
    );
    return faces;
  }
}
