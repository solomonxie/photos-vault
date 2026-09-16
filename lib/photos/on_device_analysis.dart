import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import 'ai_analysis.dart';
import 'ai_analysis_store.dart';
import 'on_device_vision.dart';

/// Turns one photo into tags and a people count, entirely on the phone.
///
/// The cloud path ([AiVisionService]) asks a vision API the same questions
/// and answers them better — but it bills per photo, and this app is built
/// for libraries where "per photo" means six figures. So this is the
/// default and that is the upgrade, rather than the other way round.
///
/// What it writes:
///
///  * **Tags** — Vision's confident labels, merged into whatever tags the
///    photo already has. Merged, not replaced: a tag the user typed is
///    theirs, and a second analysis pass must never quietly drop it.
///  * **An analysis row** — people count from face detection, and the
///    strongest label as the event/scene guess, which is what the
///    People/Events smart collections already read.
class OnDeviceAnalysisService {
  OnDeviceAnalysisService({
    required this.recordStore,
    required this.analysisStore,
    OnDeviceVisionService? vision,
  }) : vision = vision ?? OnDeviceVisionService();

  final AssetRecordStore recordStore;
  final AiAnalysisStore analysisStore;
  final OnDeviceVisionService vision;

  /// Tagging a photo with twenty things is the same as not tagging it.
  static const maxTags = 5;

  /// Vision reports faces down to a few pixels across — a stadium crowd
  /// behind the subject is not "people in this photo" in any sense the
  /// user means, and counting it makes every holiday photo a group shot.
  static const minFaceArea = 0.004;

  /// Returns whether anything changed, so a caller can skip a redraw for
  /// the photos Vision had nothing to say about.
  Future<bool> analyze(AssetRecord record, String path) async {
    final result = await vision.analyze(path);
    final faces = result.faces.where((f) => f.area >= minFaceArea).length;
    final labels = result.labels.take(maxTags).map((l) => l.label).toList();

    var changed = false;
    final merged = {...record.tags, ...labels}.toList();
    if (merged.length != record.tags.length) {
      await recordStore.setTags(record.localId, merged);
      changed = true;
    }

    if (labels.isEmpty && faces == 0) return changed;
    await analysisStore.save(
      AiPhotoAnalysis(
        localId: record.localId,
        peopleCount: faces,
        eventLabel: labels.isEmpty ? '' : labels.first,
        analyzedAt: DateTime.now(),
      ),
    );
    return true;
  }
}
