import 'package:photos_vault/photos/ai_analysis.dart';
import 'package:photos_vault/photos/ai_analysis_store.dart';
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
      _descriptors.add(_Face(localId, next ?? d.face, d.personId));
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
  Future<List<FaceRect>> facesFor(String localId) async =>
      _faces[localId] ?? const [];

  final List<_Face> _descriptors = [];
  final Map<String, Map<String, String?>> _suggestions = {};

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
      if (at >= 0) _descriptors.removeAt(at);
      _descriptors.add(_Face(l.localId, l.face, l.personId));
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
        _descriptors.add(_Face(d.localId, d.face, null));
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
  Future<void> nameFaces(
    Iterable<({String localId, FaceRect face})> faces,
    String personId,
  ) async {
    for (final f in faces) {
      _descriptors.removeWhere(
        (d) => d.localId == f.localId && d.face == f.face,
      );
      _descriptors.add(_Face(f.localId, f.face, personId));
    }
  }

  @override
  Future<FaceRect?> faceOfPersonIn(String localId, String personId) async {
    for (final d in _descriptors) {
      if (d.localId == localId && d.personId == personId) return d.face;
    }
    return null;
  }

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
      _descriptors[i] = _Face(d.localId, d.face, to);
    }
    for (final byFace in _suggestions.values) {
      byFace.updateAll((_, id) => id == from ? to : id);
    }
  }

  @override
  Future<void> forgetPerson(String personId) async {
    for (var i = 0; i < _descriptors.length; i++) {
      if (_descriptors[i].personId != personId) continue;
      _descriptors[i] = _Face(_descriptors[i].localId, _descriptors[i].face);
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
      _descriptors[i] = _Face(d.localId, d.face, to);
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
      _descriptors[i] = _Face(d.localId, d.face);
    }
  }

  @override
  Future<void> forgetDescriptor(String localId, FaceRect face) async {
    for (var i = 0; i < _descriptors.length; i++) {
      if (_descriptors[i].localId != localId) continue;
      _descriptors[i] = _Face(_descriptors[i].localId, _descriptors[i].face);
    }
  }

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
  Future<bool> copyTo(String dest, Set<String> hiddenIds) async => false;
}

class _Face {
  _Face(this.localId, this.face, [this.personId]);

  final String localId;
  final FaceRect face;
  final String? personId;
}
