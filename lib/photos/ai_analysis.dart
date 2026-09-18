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
    this.description = '',
    this.reviewed = false,
  });

  final String localId;
  final int peopleCount;

  /// Empty when the model couldn't tell — grouped as "Uncategorized".
  final String eventLabel;
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
  bool get hasSuggestions =>
      tags.isNotEmpty || eventLabel.isNotEmpty || description.isNotEmpty;
}
