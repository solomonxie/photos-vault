/// One asset's on-device analysis result: how many people it shows.
class AiPhotoAnalysis {
  const AiPhotoAnalysis({
    required this.localId,
    required this.peopleCount,
    required this.analyzedAt,
    this.legacyBoxes = false,
  });

  /// Its boxes were measured on the raw sensor buffer and still need
  /// turning upright (05#7) — see `AiAnalysisStore.reorientFaces`.
  final bool legacyBoxes;

  final String localId;
  final int peopleCount;

  /// A row left behind by a rescan, owed another look for faces. Negative
  /// because no scan can produce it — see `AiAnalysisStore.forgetFaces`.
  bool get needsLookingAt => peopleCount < 0;

  final DateTime analyzedAt;
}
