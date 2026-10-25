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
  Future<List<({String localId, FaceRect face})>> facesOfPerson(
    String personId, {
    int limit = 60,
  }) async {
    final seen = <String>{};
    return [
      for (final d in _descriptors.reversed)
        if (d.personId == personId && seen.add(d.localId))
          (localId: d.localId, face: d.face),
    ].take(limit).toList();
  }

  @override
  Future<Map<FaceRect, String>> namedFacesIn(String localId) async => {
    for (final d in _descriptors)
      if (d.localId == localId && d.personId != null) d.face: d.personId!,
  };

  @override
  Future<Map<String, Map<FaceRect, String>>> namedFacesOf(
    Iterable<String> localIds,
  ) async => {
    for (final id in localIds.toSet())
      if (await namedFacesIn(id) case final named when named.isNotEmpty)
        id: named,
  };

  @override
  Future<Map<String, ({List<FaceRect> faces, bool legacy})>> faceRowsOf(
    Iterable<String> localIds,
  ) async => {
    for (final id in localIds.toSet())
      if (_analyses[id] case final a?)
        id: (
          faces: a.needsLookingAt ? const <FaceRect>[] : _faces[id] ?? const [],
          legacy: !a.needsLookingAt && legacy.contains(id),
        ),
  };

  /// Group id → (suggest, dismissed); face key → (group, removed).
  final _groups = <String, ({String? suggest, bool dismissed})>{};
  final _members =
      <String, ({String localId, FaceRect face, String group, bool removed})>{};

  @override
  Future<FaceImportWrite> importNamedFaces(
    List<FaceLink> links, {
    Map<String, List<FaceRect>> added = const {},
    List<GroupedFace> grouped = const [],
    Map<String, String?> groups = const {},
    bool clearAll = true,
  }) async {
    added.forEach((id, boxes) {
      if (legacy.contains(id)) return;
      final pending = _analyses[id]?.needsLookingAt ?? true;
      final faces = [
        if (!pending) ...?_faces[id],
        for (final b in boxes)
          if (pending || !(_faces[id]?.contains(b) ?? false)) b,
      ];
      _faces[id] = faces;
      _analyses[id] = AiPhotoAnalysis(
        localId: id,
        peopleCount: faces.length,
        analyzedAt: DateTime.now(),
      );
    });
    final linked = <FaceLink>[];
    final undescribed = <String>{};
    for (final l in links) {
      if (legacy.contains(l.localId)) continue;
      final at = _descriptors.indexWhere(
        (d) => d.localId == l.localId && d.face == l.face,
      );
      if (at >= 0 && _descriptors[at].personId != null) continue;
      _descriptors.add(
        DescribedFace(
          localId: l.localId,
          face: l.face,
          personId: l.personId,
          descriptor: at >= 0
              ? _descriptors.removeAt(at).descriptor
              : FaceDescriptor.decode(null, 0),
        ),
      );
      if (at < 0) undescribed.add(l.localId);
      _members.remove(faceKey(l.localId, l.face));
      linked.add(l);
    }
    for (final g in grouped) {
      _groups.putIfAbsent(
        g.groupId,
        () => (suggest: groups[g.groupId], dismissed: false),
      );
    }
    var count = 0;
    for (final g in grouped) {
      if (legacy.contains(g.localId)) continue;
      if (_descriptors.any(
        (d) => d.localId == g.localId && d.face == g.face && d.personId != null,
      )) {
        continue;
      }
      final key = faceKey(g.localId, g.face);
      final had = _members[key];
      bool dead(String id) => _groups[id]?.dismissed ?? false;
      if (had == null ||
          (had.group != g.groupId &&
              (had.removed || dead(had.group)) &&
              !dead(g.groupId))) {
        _members[key] = (
          localId: g.localId,
          face: g.face,
          group: g.groupId,
          removed: false,
        );
      }
      count++;
    }
    if (clearAll) {
      _suggestions.clear();
    } else {
      for (final l in linked) {
        _suggestions.remove(l.localId);
      }
    }
    return (linked: linked, undescribed: undescribed, grouped: count);
  }

  static String faceKey(String localId, FaceRect face) =>
      AiAnalysisStore.faceKey(localId, face);

  @override
  Future<Map<String, Set<String>>> groupedFaces() async {
    final out = <String, Set<String>>{};
    for (final m in _members.values) {
      if (m.removed || (_groups[m.group]?.dismissed ?? true)) continue;
      (out[m.localId] ??= {}).add(m.face.encode());
    }
    return out;
  }

  @override
  Future<List<StoredFaceGroup>> faceGroups() async {
    final faces = <String, List<({String localId, FaceRect face})>>{};
    for (final m in _members.values) {
      if (m.removed || (_groups[m.group]?.dismissed ?? true)) continue;
      if (_descriptors.any(
        (d) => d.localId == m.localId && d.face == m.face && d.personId != null,
      )) {
        continue;
      }
      (faces[m.group] ??= []).add((localId: m.localId, face: m.face));
    }
    return [
      for (final MapEntry(:key, :value) in faces.entries)
        StoredFaceGroup(id: key, suggest: _groups[key]!.suggest, faces: value),
    ];
  }

  @override
  Future<Set<String>> returnToGroup(
    String personId,
    String groupId,
    List<({String localId, FaceRect face})> faces,
  ) async {
    for (final f in faces) {
      final at = _descriptors.indexWhere(
        (d) =>
            d.localId == f.localId &&
            d.face == f.face &&
            d.personId == personId,
      );
      if (at >= 0) {
        final d = _descriptors.removeAt(at);
        _descriptors.add(
          DescribedFace(
            localId: d.localId,
            face: d.face,
            personId: null,
            descriptor: d.descriptor,
          ),
        );
      }
      _members[faceKey(f.localId, f.face)] = (
        localId: f.localId,
        face: f.face,
        group: groupId,
        removed: false,
      );
    }
    final ids = {for (final f in faces) f.localId};
    return {
      for (final id in ids)
        if (!_descriptors.any((d) => d.localId == id && d.personId == personId))
          id,
    };
  }

  @override
  Future<void> ungroupFaces(
    Iterable<({String localId, FaceRect face})> faces,
  ) async {
    for (final f in faces) {
      final key = faceKey(f.localId, f.face);
      final m = _members[key];
      if (m == null) continue;
      _members[key] = (
        localId: m.localId,
        face: m.face,
        group: m.group,
        removed: true,
      );
    }
  }

  @override
  Future<void> dismissGroup(String id) async {
    final g = _groups[id];
    if (g != null) _groups[id] = (suggest: g.suggest, dismissed: true);
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
    _members.removeWhere((_, m) => ids.contains(m.localId));
  }

  @override
  Future<void> forgetAssets(Iterable<String> localIds) async {
    final ids = localIds.toSet();
    await forgetFacesOf(ids);
    _analyses.removeWhere((id, _) => ids.contains(id));
  }

  @override
  Future<void> movePerson(String from, String to) async {
    for (var i = 0; i < _descriptors.length; i++) {
      final d = _descriptors[i];
      if (d.personId != from) continue;
      _descriptors[i] = DescribedFace(
        localId: d.localId,
        face: d.face,
        descriptor: d.descriptor,
        personId: to,
      );
    }
    for (final byFace in _suggestions.values) {
      byFace.updateAll((_, id) => id == from ? to : id);
    }
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
  Future<void> movePersonOn(
    String from,
    String to,
    Iterable<String> localIds,
  ) async {
    final ids = localIds.toSet();
    for (var i = 0; i < _descriptors.length; i++) {
      final d = _descriptors[i];
      if (d.personId != from || !ids.contains(d.localId)) continue;
      _descriptors[i] = DescribedFace(
        localId: d.localId,
        face: d.face,
        personId: to,
        descriptor: d.descriptor,
      );
    }
  }

  @override
  Future<void> forgetPersonOn(
    String personId,
    Iterable<String> localIds,
  ) async {
    final ids = localIds.toSet();
    for (var i = 0; i < _descriptors.length; i++) {
      final d = _descriptors[i];
      if (d.personId != personId || !ids.contains(d.localId)) continue;
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
    _members.clear();
    _groups.clear();
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
