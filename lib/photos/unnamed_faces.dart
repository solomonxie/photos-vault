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
  final Map<String, List<FaceRect>> faces;
  var suggestions = const <String, Map<String, String>>{};
  try {
    faces = await analysisStore.facesByAsset();
    suggestions = await analysisStore.suggestionsByAsset();
  } catch (_) {
    // No analysis database yet (a fresh install, a widget test) — the
    // caller just shows the named people.
    return (faces: const <UnnamedFace>[], found: 0);
  }
  if (faces.isEmpty) return (faces: const <UnnamedFace>[], found: 0);
  final candidates =
      records
          .where(
            (r) =>
                !r.isDeleted &&
                !r.isHidden &&
                r.passcodeHash == null &&
                !taggedLocalIds.contains(r.localId) &&
                faces.containsKey(r.localId),
          )
          .toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  // Flattened newest-first, so the face that represents a group is the
  // most recent one — the one most likely to be recognised.
  final flat = <UnnamedFace>[];
  for (final record in candidates) {
    final guesses = suggestions[record.localId] ?? const {};
    for (final face in faces[record.localId]!) {
      final personId = guesses[face.encode()];
      flat.add(
        UnnamedFace(
          localId: record.localId,
          face: face,
          suggestedPersonId: personId,
          suggestedName: personId == null ? null : peopleById[personId],
        ),
      );
    }
  }

  Map<String, FaceDescriptor> described;
  try {
    described = {
      for (final f in await analysisStore.allDescribedFaces())
        if (f.personId == null) '${f.localId}:${f.face.encode()}': f.descriptor,
    };
  } catch (_) {
    described = const {};
  }

  // Greedy: take the newest face nobody has folded away, pull in
  // everything that looks like it, show one circle for the lot.
  //
  // Every seed is worked through rather than stopping at [limit], because
  // the list is ordered by how big each pile is and the biggest one is
  // not usually among the newest twenty faces. [scanLimit] is what keeps
  // that from being a pass over a camera roll's worth of faces every time
  // the page draws — beyond it, the oldest faces simply aren't folded in.
  final taken = <String>{};
  final groups = <UnnamedFace>[];
  for (final seed in flat.take(scanLimit)) {
    final seedKey = '${seed.localId}:${seed.face.encode()}';
    if (taken.contains(seedKey)) continue;
    taken.add(seedKey);
    // Photos, not faces — because photos are what opening the circle
    // shows. Two faces of the same person in one group shot counted two
    // and displayed one.
    final photos = <String>{seed.localId};
    final descriptor = described[seedKey];
    if (descriptor != null && !descriptor.isEmpty) {
      // The strict one: a face folded in wrongly here vanishes behind
      // somebody else's circle with nothing to untick.
      final ceiling = FaceGrouping.foldingCeilingForPipeline(
        descriptor.pipeline,
      );
      for (final other in flat) {
        final key = '${other.localId}:${other.face.encode()}';
        if (taken.contains(key)) continue;
        final candidate = described[key];
        if (candidate == null) continue;
        final distance = descriptor.distanceTo(candidate);
        if (distance == null || distance > ceiling) continue;
        taken.add(key);
        photos.add(other.localId);
      }
    }
    groups.add(
      UnnamedFace(
        localId: seed.localId,
        face: seed.face,
        suggestedPersonId: seed.suggestedPersonId,
        suggestedName: seed.suggestedName,
        alike: photos.length,
      ),
    );
  }
  // Biggest pile first: naming the face that appears in forty photos is
  // forty photos sorted, and naming the one that appears once is one.
  groups.sort((a, b) => b.alike.compareTo(a.alike));
  return (faces: groups.take(limit).toList(), found: flat.length);
}
