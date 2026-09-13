/// One asset's AI analysis result — people count and a short event/scene
/// label — powering the People/Events smart collections. See
/// IMPLEMENTATION_PLAN.md T4.4.
class AiPhotoAnalysis {
  const AiPhotoAnalysis({
    required this.localId,
    required this.peopleCount,
    required this.eventLabel,
    required this.analyzedAt,
  });

  final String localId;
  final int peopleCount;

  /// Empty when the model couldn't tell — grouped as "Uncategorized".
  final String eventLabel;
  final DateTime analyzedAt;
}
