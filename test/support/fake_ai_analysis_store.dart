import 'package:photos_vault/photos/ai_analysis.dart';
import 'package:photos_vault/photos/ai_analysis_store.dart';
import 'package:photos_vault/photos/face_matcher.dart';
import 'package:photos_vault/photos/on_device_vision.dart';
import 'package:photos_vault/photos/person.dart' show FaceRect;

/// Pure-Dart, in-memory stand-in for [AiAnalysisStore] — see
/// `fake_asset_record_store.dart` for why widget tests can't use the real
/// `sqflite_common_ffi`-backed store.
class FakeAiAnalysisStore implements AiAnalysisStore {
  final _analyses = <String, AiPhotoAnalysis>{};
  final _faces = <String, List<FaceRect>>{};

  /// Rows whose boxes are still in raw sensor space (schema v7).
  final legacy = <String>{};

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
    legacy.remove(localId);
    final moved = carryFaces([
      ..._descriptors
          .where((d) => d.localId == localId && d.personId != null)
          .map((d) => d.face),
      ..._descriptors
          .where((d) => d.localId == localId && d.personId == null)
          .map((d) => d.face),
    ], faces);
    _moveDescriptors(localId, (f) => moved[f]);
    _analyses[localId] = AiPhotoAnalysis(
      localId: localId,
      peopleCount: peopleCount,
      analyzedAt: analyzedAt,
    );
  }

  void _moveDescriptors(String localId, FaceRect? Function(FaceRect) to) {
    final mine = _descriptors.where((d) => d.localId == localId).toList();
    if (mine.every((d) => to(d.face) == d.face)) return;
    _descriptors.removeWhere((d) => d.localId == localId);
    for (final d in mine) {
      final next = to(d.face);
      if (next == null && d.personId == null) continue;
      _descriptors.add(
        DescribedFace(
          localId: localId,
          face: next ?? d.face,
          personId: d.personId,
          descriptor: d.descriptor,
        ),
      );
    }
    _suggestions.remove(localId);
  }

  @override
  Future<void> reorientFaces(String localId, int orientation) async {
    if (!legacy.remove(localId)) return;
    final faces = _faces[localId];
    if (faces != null) {
      _faces[localId] = [for (final f in faces) f.oriented(orientation)];
    }
    final a = _analyses[localId];
    if (a != null) {
      _analyses[localId] = AiPhotoAnalysis(
        localId: a.localId,
        peopleCount: a.peopleCount,
        analyzedAt: a.analyzedAt,
      );
    }
    _moveDescriptors(localId, (f) => f.oriented(orientation));
  }

  /// Seeds a row as a pre-v7 one: boxes measured on the raw buffer.
  void seedLegacy(String localId, List<FaceRect> faces) {
    _faces[localId] = faces;
    legacy.add(localId);
    _analyses[localId] = AiPhotoAnalysis(
      localId: localId,
      peopleCount: faces.length,
      analyzedAt: DateTime(2026),
      legacyBoxes: true,
    );
  }

  @override
  Future<Map<String, List<FaceRect>>> facesByAsset() async => Map.of(_faces);

  /// Never the same twice: the fake does not track its writes, so nothing
  /// may cache against it.
  @override
  int get revision => _reads++;
  var _reads = 0;

  @override
  Future<Map<String, int>> faceCounts() async => {
    for (final e in _faces.entries)
      if (e.value.isNotEmpty) e.key: e.value.length,
  };

  @override
  Future<Map<String, List<FaceRect>>> facesOf(
    Iterable<String> localIds,
  ) async => {
    for (final id in localIds)
      if (_faces[id] case final faces? when faces.isNotEmpty) id: faces,
  };

  @override
  Future<Map<String, Map<String, String>>> suggestionsOf(
    Iterable<String> localIds,
  ) async {
    final all = await suggestionsByAsset();
    return {for (final id in localIds) id: ?all[id]};
  }

  @override
  Future<Map<String, FaceDescriptor>> unnamedDescriptorsOf(
    Iterable<String> localIds,
  ) async {
    final ids = localIds.toSet();
    return {
      for (final d in _descriptors)
        if (d.personId == null && ids.contains(d.localId))
          AiAnalysisStore.faceKey(d.localId, d.face): d.descriptor,
    };
  }

  @override
  Future<List<FaceRect>> facesFor(String localId) async =>
      _faces[localId] ?? const [];

  final List<DescribedFace> _descriptors = [];
  final Map<String, Map<String, String?>> _suggestions = {};

  @override
  Future<void> saveDescriptor({
    required String localId,
    required FaceRect face,
    required FaceDescriptor descriptor,
    String? personId,
  }) async {
    if (descriptor.isEmpty) return;
    final kept = _descriptors
        .where((d) => d.localId == localId && d.face == face)
        .firstOrNull
        ?.personId;
    _descriptors.removeWhere((d) => d.localId == localId && d.face == face);
    _descriptors.add(
      DescribedFace(
        localId: localId,
        face: face,
        personId: personId ?? kept,
        descriptor: descriptor,
      ),
    );
  }

  @override
  Future<void> attachDescriptors(
    Iterable<({String localId, FaceRect face})> faces,
    String personId,
  ) async {
    for (final f in faces) {
      await attachDescriptor(f.localId, f.face, personId);
    }
  }

  @override
  Future<Map<String, FaceDescriptor>> descriptorsOf(
    Iterable<String> localIds,
  ) async {
    final ids = localIds.toSet();
    return {
      for (final d in _descriptors)
        if (ids.contains(d.localId))
          AiAnalysisStore.faceKey(d.localId, d.face): d.descriptor,
    };
  }

  @override
  Future<void> clearSuggestionsOf(Iterable<String> localIds) async {
    for (final id in localIds) {
      _suggestions.remove(id);
    }
  }

  @override
  Future<void> attachDescriptor(
    String localId,
    FaceRect face,
    String personId,
  ) async {
    final i = _descriptors.indexWhere(
      (d) => d.localId == localId && d.face == face,
    );
    if (i < 0) return;
    _descriptors[i] = DescribedFace(
      localId: localId,
      face: face,
      personId: personId,
      descriptor: _descriptors[i].descriptor,
    );
  }

  @override
  Future<FaceRect?> faceOfPersonIn(String localId, String personId) async {
    for (final d in _descriptors) {
      if (d.localId == localId && d.personId == personId) return d.face;
    }
    return null;
  }

  @override
  Future<FaceDescriptor?> descriptorFor(String localId, FaceRect face) async {
    for (final d in _descriptors) {
      if (d.localId == localId && d.face == face) return d.descriptor;
    }
    return null;
  }

  @override
  Future<List<DescribedFace>> allDescribedFaces() async =>
      List.of(_descriptors);

  @override
  Future<List<ConfirmedFace>> confirmedFaces({int perPerson = 12}) async {
    final kept = <String, int>{};
    return [
      for (final d in _descriptors.reversed)
        if (d.personId != null &&
            (kept[d.personId!] = (kept[d.personId!] ?? 0) + 1) <= perPerson)
          ConfirmedFace(
            personId: d.personId!,
            localId: d.localId,
            descriptor: d.descriptor,
          ),
    ];
  }

  @override
  Future<List<ConfirmedFace>> confirmedFacesFor(
    String personId, {
    int limit = 40,
  }) async => [
    for (final d in _descriptors.reversed)
      if (d.personId == personId)
        ConfirmedFace(
          personId: personId,
          localId: d.localId,
          descriptor: d.descriptor,
        ),
  ].take(limit).toList();

  @override
  Future<void> forgetFacesOf(Iterable<String> localIds) async {
    final ids = localIds.toSet();
    _descriptors.removeWhere((d) => ids.contains(d.localId));
    _suggestions.removeWhere((id, _) => ids.contains(id));
    _faces.removeWhere((id, _) => ids.contains(id));
  }

  @override
  Future<void> forgetAssets(Iterable<String> localIds) async {
    final ids = localIds.toSet();
    await forgetFacesOf(ids);
    _analyses.removeWhere((id, _) => ids.contains(id));
  }

  @override
  Future<void> forgetPerson(String personId) async {
    for (var i = 0; i < _descriptors.length; i++) {
      if (_descriptors[i].personId != personId) continue;
      _descriptors[i] = DescribedFace(
        localId: _descriptors[i].localId,
        face: _descriptors[i].face,
        descriptor: _descriptors[i].descriptor,
      );
    }
    for (final byFace in _suggestions.values) {
      byFace.removeWhere((_, id) => id == personId);
    }
  }

  @override
  Future<void> forgetPersonOn(String personId, String localId) async {
    for (var i = 0; i < _descriptors.length; i++) {
      final d = _descriptors[i];
      if (d.personId != personId || d.localId != localId) continue;
      _descriptors[i] = DescribedFace(
        localId: d.localId,
        face: d.face,
        descriptor: d.descriptor,
      );
    }
  }

  @override
  Future<void> forgetDescriptor(String localId, FaceRect face) async {
    for (var i = 0; i < _descriptors.length; i++) {
      if (_descriptors[i].localId != localId) continue;
      _descriptors[i] = DescribedFace(
        localId: _descriptors[i].localId,
        face: _descriptors[i].face,
        descriptor: _descriptors[i].descriptor,
      );
    }
  }

  @override
  Future<void> saveSuggestions(
    String localId,
    Map<String, String?> byFace,
  ) async => _suggestions.putIfAbsent(localId, () => {}).addAll(byFace);

  @override
  Future<Map<String, Map<String, String>>> suggestionsByAsset() async => {
    for (final entry in _suggestions.entries)
      if ({
            for (final e in entry.value.entries)
              if (e.value != null) e.key: e.value!,
          }
          case final named when named.isNotEmpty)
        entry.key: named,
  };

  @override
  Future<Map<String, String>> suggestionsFor(String localId) async => {
    for (final e in (_suggestions[localId] ?? const {}).entries)
      if (e.value != null) e.key: e.value!,
  };

  @override
  Future<Set<String>> matchedAssets() async => _suggestions.keys.toSet();

  @override
  Future<void> clearSuggestions(String localId) async =>
      _suggestions.remove(localId);

  @override
  Future<void> clearAll() async {
    _analyses.clear();
    _faces.clear();
    _descriptors.clear();
    _suggestions.clear();
  }

  @override
  Future<void> clearAllSuggestions() async => _suggestions.clear();

  @override
  Future<void> forgetFaces() async {
    _faces.clear();
    _suggestions.clear();
    for (final id in _analyses.keys.toList()) {
      final a = _analyses[id]!;
      _analyses[id] = AiPhotoAnalysis(
        localId: a.localId,
        peopleCount: -1,
        analyzedAt: a.analyzedAt,
      );
    }
  }

  @override
  Future<Set<String>> staleDescriptorAssets(Set<int> livePipelines) async => {
    for (final d in _descriptors)
      if (!livePipelines.contains(d.descriptor.pipeline)) d.localId,
  };

  @override
  Future<Set<String>> assetsWithDescriptors() async => {
    for (final d in _descriptors)
      if (d.personId != null) d.localId,
  };

  @override
  Future<bool> hasDescriptorsFor(String personId) async =>
      _descriptors.any((d) => d.personId == personId);

  @override
  Future<bool> copyTo(String dest, Set<String> hiddenIds) async => false;
}
