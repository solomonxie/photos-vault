import '../storage/asset_record_store.dart';
import 'ai_analysis.dart';
import 'ai_analysis_store.dart';

/// Taking a suggestion, or turning it down.
///
/// Free functions rather than methods on the queue that produced them: a
/// suggestion is answered on the photo it's about, where the person can see
/// what they're saying yes to, and the photo screen has no business knowing
/// a queue exists.
///
/// Tags are *merged*, and an event or caption is only filled in where there
/// isn't one — accepting a suggestion adds to the work already done on a
/// photo, it never overwrites it.
Future<void> acceptSuggestion(
  AiPhotoAnalysis analysis, {
  required AssetRecordStore records,
  required AiAnalysisStore analyses,
  bool tags = true,
  bool event = true,
  bool description = true,
}) async {
  final record = await records.getByLocalId(analysis.localId);
  if (record != null) {
    if (tags && analysis.tags.isNotEmpty) {
      await records.setTags(
        record.localId,
        {...record.tags, ...analysis.tags}.toList(),
      );
    }
    if (event && analysis.eventLabel.isNotEmpty && record.event == null) {
      await records.setEvent(record.localId, analysis.eventLabel);
    }
    if (description &&
        analysis.description.isNotEmpty &&
        record.description.isEmpty) {
      await records.setDescription(record.localId, analysis.description);
    }
  }
  await analyses.markReviewed(analysis.localId);
}

/// Kept rather than deleted: the photo is never offered up again, and it
/// never costs a second vendor call to be told the same thing.
Future<void> dismissSuggestion(
  String localId, {
  required AiAnalysisStore analyses,
}) => analyses.markReviewed(localId);
