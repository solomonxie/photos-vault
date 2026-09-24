import 'dart:io';

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

  @override
  Future<void> close() async {}

  /// No file behind an in-memory fake — the snapshot just has one fewer
  /// database to copy, which is what it did before this one joined.
  @override
  Future<File?> checkpointedFile() async => null;

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
    _descriptors.removeWhere((d) => d.localId == localId && d.face == face);
    _descriptors.add(
      DescribedFace(
        localId: localId,
        face: face,
        personId: personId,
        descriptor: descriptor,
      ),
    );
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
        eventLabel: a.eventLabel,
        analyzedAt: a.analyzedAt,
        tags: a.tags,
        description: a.description,
        reviewed: a.reviewed,
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
  Future<List<AiPhotoAnalysis>> unreviewed() async => [
    for (final analysis in _analyses.values)
      if (!analysis.reviewed && analysis.hasSuggestions) analysis,
  ];
}
