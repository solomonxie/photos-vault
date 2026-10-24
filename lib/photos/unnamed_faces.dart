import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart'
    show listEquals, mapEquals, setEquals, visibleForTesting;

import '../storage/asset_record.dart';
import 'ai_analysis_store.dart';
import 'face_grouping.dart';
import 'on_device_vision.dart' show FaceDescriptor;
import 'person.dart';

/// Faces the app has found in photos nobody is tagged in.
///
/// Per-photo rather than per-face identity — iOS won't say whose face it
/// is, so once one person is named in a photo the app has no way to tell
/// which of the remaining boxes are still strangers, and guessing wrong is
/// worse than stopping.
///
/// [taggedLocalIds] is the set of photos somebody is already named in.
/// Newest photo first, and capped at [limit]: this is an invitation to name
/// a few people, not a backlog to work through, and the whole camera roll's
/// worth of faces is a wall rather than a suggestion.
/// [peopleById] puts a name to whatever the matcher guessed; without it the
/// faces are still listed, just never as a suggestion.
/// One entry per *person*, not per face: faces that look like one already
/// listed are folded into it rather than asked about again. Three photos
/// of the same stranger is one question, not three.
///
/// Ordered by how many faces each circle stands for, largest first —
/// naming the face that turns up in forty photos sorts forty photos, and
/// naming the one that turns up once sorts one.
///
/// [found] is how many faces there are in total, which [faces] is only the
/// first [limit] groups of — the difference between "the scan has found
/// nothing yet" and "there are four hundred, here are twenty".
typedef UnnamedFaces = ({List<UnnamedFace> faces, int found});

Future<UnnamedFaces> findUnnamedFaces({
  required AiAnalysisStore analysisStore,
  required List<AssetRecord> records,
  required Set<String> taggedLocalIds,
  Map<String, String> peopleById = const {},
  int limit = 60,
  int scanLimit = 1200,
}) async {
  const none = (faces: <UnnamedFace>[], found: 0);
  final Map<String, int> counts;
  final int revision;
  try {
    revision = analysisStore.revision;
    counts = await analysisStore.faceCounts();
  } catch (_) {
    // No analysis database yet (a fresh install, a widget test) — the
    // caller just shows the named people.
    return none;
  }
  if (counts.isEmpty) return none;
  final (:window, :found) = _windowOf(
    analysisStore,
    records,
    taggedLocalIds,
    counts,
    revision,
    scanLimit,
  );

  final key = _MemoKey(
    store: analysisStore,
    revision: revision,
    window: window,
    peopleById: peopleById,
    scanLimit: scanLimit,
  );
  final held = _memo[limit];
  if (held != null && held.key.matches(key)) {
    return (faces: held.faces, found: found);
  }

  final Map<String, List<FaceRect>> faces;
  var suggestions = const <String, Map<String, String>>{};
  try {
    faces = await analysisStore.facesOf(window);
    suggestions = await analysisStore.suggestionsOf(window);
  } catch (_) {
    return none;
  }
  // Flattened newest-first, so the face that represents a group is the
  // most recent one — the one most likely to be recognised.
  final flat = <UnnamedFace>[];
  final photoOf = <int>[];
  for (final (i, localId) in window.indexed) {
    final guesses = suggestions[localId] ?? const {};
    for (final face in faces[localId] ?? const <FaceRect>[]) {
      final personId = guesses[face.encode()];
      flat.add(
        UnnamedFace(
          localId: localId,
          face: face,
          suggestedPersonId: personId,
          suggestedName: personId == null ? null : peopleById[personId],
        ),
      );
      photoOf.add(i);
    }
  }
  if (flat.isEmpty) return (faces: const <UnnamedFace>[], found: found);

  final packed = await _pack(analysisStore, flat, photoOf);

  // Off the UI isolate once there is enough of it to matter: the fold
  // below is every seed against every other face. Only typed data crosses,
  // ~0.5 KB a face. Below the threshold an isolate costs more than it saves.
  final folded = flat.length > _isolateThreshold
      ? await _foldElsewhere(packed, scanLimit)
      : _fold(packed, scanLimit);

  final groups = [
    for (var g = 0; g < folded.length; g += 2)
      UnnamedFace(
        localId: flat[folded[g]].localId,
        face: flat[folded[g]].face,
        suggestedPersonId: flat[folded[g]].suggestedPersonId,
        suggestedName: flat[folded[g]].suggestedName,
        alike: folded[g + 1],
      ),
  ];
  // Biggest pile first: naming the face that appears in forty photos is
  // forty photos sorted, and naming the one that appears once is one.
  groups.sort((a, b) => b.alike.compareTo(a.alike));
  final shown = groups.take(limit).toList();
  _memo[limit] = (key: key, faces: shown);
  return (faces: shown, found: found);
}

/// The last answer per [findUnnamedFaces] `limit`. A delete, hide or
/// rename that leaves the folded faces and their guesses alone is a hit.
final _memo = <int, ({_MemoKey key, List<UnnamedFace> faces})>{};

@visibleForTesting
void forgetUnnamedFacesMemo() {
  _memo.clear();
  _window = null;
}

/// Untagged photos with faces, newest first: a filter and sort over the
/// whole library, so held while the list, tags and scan are unchanged —
/// a rename on People must not re-sort the camera roll.
({
  AiAnalysisStore store,
  List<AssetRecord> records,
  Set<String> tagged,
  int revision,
  int scanLimit,
  List<String> window,
  int found,
})?
_window;

({List<String> window, int found}) _windowOf(
  AiAnalysisStore store,
  List<AssetRecord> records,
  Set<String> tagged,
  Map<String, int> counts,
  int revision,
  int scanLimit,
) {
  final held = _window;
  if (held != null &&
      identical(held.store, store) &&
      identical(held.records, records) &&
      held.revision == revision &&
      held.scanLimit == scanLimit &&
      setEquals(held.tagged, tagged)) {
    return (window: held.window, found: held.found);
  }
  final candidates =
      records
          .where(
            (r) =>
                r.isVisibleInLibrary &&
                !tagged.contains(r.localId) &&
                counts.containsKey(r.localId),
          )
          .toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  // Only the newest [scanLimit] faces are folded, so only their photos are
  // read (DB-2); the rest are only counted.
  var found = 0;
  final window = <String>[];
  for (final record in candidates) {
    final n = counts[record.localId]!;
    if (found < scanLimit) window.add(record.localId);
    found += n;
  }
  _window = (
    store: store,
    records: records,
    tagged: {...tagged},
    revision: revision,
    scanLimit: scanLimit,
    window: window,
    found: found,
  );
  return (window: window, found: found);
}

class _MemoKey {
  const _MemoKey({
    required this.store,
    required this.revision,
    required this.window,
    required this.peopleById,
    required this.scanLimit,
  });

  final AiAnalysisStore store;
  final int revision;
  final List<String> window;
  final Map<String, String> peopleById;
  final int scanLimit;

  bool matches(_MemoKey other) =>
      identical(store, other.store) &&
      revision == other.revision &&
      scanLimit == other.scanLimit &&
      listEquals(window, other.window) &&
      mapEquals(peopleById, other.peopleById);
}

/// The descriptors of [flat], packed for the fold: one [Float32List] of
/// every vector end to end, and per face where its vector starts
/// ([_Packed.offsets], `n + 1` long; empty means none), its revision and
/// which photo it is in.
class _Packed {
  const _Packed(this.vectors, this.offsets, this.revisions, this.photos);

  final Float32List vectors;
  final Int32List offsets;
  final Int32List revisions;
  final Int32List photos;
}

Future<_Packed> _pack(
  AiAnalysisStore store,
  List<UnnamedFace> flat,
  List<int> photoOf,
) async {
  Map<String, FaceDescriptor> described;
  try {
    described = await store.unnamedDescriptorsOf({
      for (final f in flat) f.localId,
    });
  } catch (_) {
    described = const {};
  }
  final n = flat.length;
  final found = [
    for (final f in flat) described[AiAnalysisStore.faceKey(f.localId, f.face)],
  ];
  final offsets = Int32List(n + 1);
  final revisions = Int32List(n);
  for (var i = 0; i < n; i++) {
    offsets[i + 1] = offsets[i] + (found[i]?.vector.length ?? 0);
    revisions[i] = found[i]?.revision ?? 0;
  }
  final vectors = Float32List(offsets[n]);
  for (var i = 0; i < n; i++) {
    final d = found[i];
    if (d != null) vectors.setAll(offsets[i], d.vector);
  }
  return _Packed(vectors, offsets, revisions, Int32List.fromList(photoOf));
}

/// Top-level, so the closure carries only [packed] across.
Future<Int32List> _foldElsewhere(_Packed packed, int scanLimit) =>
    Isolate.run(() => _fold(packed, scanLimit));

/// The greedy grouping itself, pure and isolate-safe: take the newest face
/// nobody has folded away, pull in everything that looks like it, show one
/// circle for the lot. Returns `[seed, alike, seed, alike, …]`.
///
/// Every seed is worked through rather than stopping at the display limit,
/// because the list is ordered by how big each pile is and the biggest one
/// is not usually among the newest twenty faces. [scanLimit] is what keeps
/// that from being a pass over a camera roll's worth of faces every time
/// the page draws — beyond it, the oldest faces simply aren't folded in.
Int32List _fold(_Packed packed, int scanLimit) {
  final _Packed(:vectors, :offsets, :revisions, :photos) = packed;
  final n = revisions.length;
  final norms = Float64List(n);
  for (var i = 0; i < n; i++) {
    var sum = 0.0;
    for (var k = offsets[i]; k < offsets[i + 1]; k++) {
      sum += vectors[k] * vectors[k];
    }
    norms[i] = math.sqrt(sum);
  }
  final taken = Uint8List(n);
  final out = <int>[];
  for (var seed = 0; seed < math.min(n, scanLimit); seed++) {
    if (taken[seed] == 1) continue;
    taken[seed] = 1;
    // Photos, not faces — because photos are what opening the circle
    // shows. Two faces of the same person in one group shot counted two
    // and displayed one.
    final shown = <int>{photos[seed]};
    final from = offsets[seed];
    final length = offsets[seed + 1] - from;
    if (length > 0 && norms[seed] > 0) {
      // The strict one: a face folded in wrongly here vanishes behind
      // somebody else's circle with nothing to untick.
      final ceiling = FaceGrouping.foldingCeilingForPipeline(
        revisions[seed] ~/ 1000,
      );
      for (var other = 0; other < n; other++) {
        if (taken[other] == 1) continue;
        final start = offsets[other];
        if (offsets[other + 1] - start != length) continue;
        if (revisions[other] != revisions[seed] || norms[other] == 0) continue;
        var dot = 0.0;
        for (var k = 0; k < length; k++) {
          dot += vectors[from + k] * vectors[start + k];
        }
        if (1 - dot / (norms[seed] * norms[other]) > ceiling) continue;
        taken[other] = 1;
        shown.add(photos[other]);
      }
    }
    out
      ..add(seed)
      ..add(shown.length);
  }
  return Int32List.fromList(out);
}

/// How many faces are worth an isolate — a few hundred fold in a frame or
/// two, and the copy across is the same order as the work saved.
const _isolateThreshold = 150;
