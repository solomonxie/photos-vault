import 'package:photos_vault/photos/ai_analysis.dart';
import 'package:photos_vault/photos/ai_analysis_store.dart';
import 'package:photos_vault/photos/person.dart' show FaceRect;

/// Pure-Dart, in-memory stand-in for [AiAnalysisStore] — see
/// `fake_asset_record_store.dart` for why widget tests can't use the real
/// `sqflite_common_ffi`-backed store.
class FakeAiAnalysisStore implements AiAnalysisStore {
  final _analyses = <String, AiPhotoAnalysis>{};
  final _faces = <String, List<FaceRect>>{};

  @override
  Future<void> close() async {}

  @override
  Future<void> save(AiPhotoAnalysis analysis) async =>
      _analyses[analysis.localId] = analysis;

  @override
  Future<AiPhotoAnalysis?> get(String localId) async => _analyses[localId];

  @override
  Future<Map<String, AiPhotoAnalysis>> listAll() async => Map.of(_analyses);

  @override
  Future<void> saveFaceCount({
    required String localId,
    required int peopleCount,
    required DateTime analyzedAt,
    List<FaceRect> faces = const [],
  }) async {
    if (faces.isNotEmpty) _faces[localId] = faces;
    final existing = _analyses[localId];
    _analyses[localId] = AiPhotoAnalysis(
      localId: localId,
      peopleCount: peopleCount,
      eventLabel: existing?.eventLabel ?? '',
      analyzedAt: analyzedAt,
      tags: existing?.tags ?? const [],
      description: existing?.description ?? '',
      reviewed: existing?.reviewed ?? false,
    );
  }

  @override
  Future<void> saveSuggestion(AiPhotoAnalysis analysis) async {
    final existing = _analyses[analysis.localId];
    _analyses[analysis.localId] = AiPhotoAnalysis(
      localId: analysis.localId,
      peopleCount: existing?.peopleCount ?? analysis.peopleCount,
      eventLabel: analysis.eventLabel,
      analyzedAt: analysis.analyzedAt,
      tags: analysis.tags,
      description: analysis.description,
    );
  }

  @override
  Future<void> markReviewed(String localId) async {
    final existing = _analyses[localId];
    if (existing == null) return;
    _analyses[localId] = AiPhotoAnalysis(
      localId: existing.localId,
      peopleCount: existing.peopleCount,
      eventLabel: existing.eventLabel,
      analyzedAt: existing.analyzedAt,
      tags: existing.tags,
      description: existing.description,
      reviewed: true,
    );
  }

  @override
  Future<Map<String, List<FaceRect>>> facesByAsset() async => Map.of(_faces);

  @override
  Future<List<AiPhotoAnalysis>> unreviewed() async => [
    for (final analysis in _analyses.values)
      if (!analysis.reviewed && analysis.hasSuggestions) analysis,
  ];
}
