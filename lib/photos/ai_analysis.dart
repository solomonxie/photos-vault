/// One asset's AI analysis result — people count and a short event/scene
/// label — powering the People/Events smart collections. See
/// IMPLEMENTATION_PLAN.md T4.4.
class AiPhotoAnalysis {
  const AiPhotoAnalysis({
    required this.localId,
    required this.peopleCount,
    required this.eventLabel,
    required this.analyzedAt,
    this.tags = const [],
  });

  final String localId;
  final int peopleCount;

  /// Empty when the model couldn't tell — grouped as "Uncategorized".
  final String eventLabel;
  final DateTime analyzedAt;

  /// Suggested tags. Deliberately *not* persisted here: tags belong to the
  /// photo, so they're merged onto its record and live there — this is
  /// just how one analysis hands them over.
  final List<String> tags;
}
