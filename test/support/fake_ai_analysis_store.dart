import 'package:bring_your_own_photos/photos/ai_analysis.dart';
import 'package:bring_your_own_photos/photos/ai_analysis_store.dart';

/// Pure-Dart, in-memory stand-in for [AiAnalysisStore] — see
/// `fake_asset_record_store.dart` for why widget tests can't use the real
/// `sqflite_common_ffi`-backed store.
class FakeAiAnalysisStore implements AiAnalysisStore {
  final _analyses = <String, AiPhotoAnalysis>{};

  @override
  Future<void> close() async {}

  @override
  Future<void> save(AiPhotoAnalysis analysis) async =>
      _analyses[analysis.localId] = analysis;

  @override
  Future<Map<String, AiPhotoAnalysis>> listAll() async => Map.of(_analyses);
}
