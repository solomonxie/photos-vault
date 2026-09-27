/// One asset's AI analysis result — a people count, plus the suggested tags
/// and caption waiting to be accepted. See IMPLEMENTATION_PLAN.md T4.4.
class AiPhotoAnalysis {
  const AiPhotoAnalysis({
    required this.localId,
    required this.peopleCount,
    required this.analyzedAt,
    this.tags = const [],
    this.description = '',
    this.reviewed = false,
  });

  final String localId;
  final int peopleCount;

  /// A row left behind by a rescan: the paid half is still in it, but the
  /// photo is owed another look for faces. Negative because no scan can
  /// produce it — see `AiAnalysisStore.forgetFaces`.
  bool get needsLookingAt => peopleCount < 0;

  final DateTime analyzedAt;

  /// Suggested tags. Persisted here until they're reviewed, then merged
  /// onto the photo's own record, which is where a tag lives once it's
  /// been accepted — a suggestion isn't a tag yet.
  final List<String> tags;

  /// A suggested one-line caption, empty when the model didn't offer one.
  final String description;

  /// Whether the user has been shown this suggestion and said yes or no.
  /// What keeps the review list from offering the same photo forever.
  final bool reviewed;

  /// Whether there's anything here worth asking about.
  bool get hasSuggestions => tags.isNotEmpty || description.isNotEmpty;
}
