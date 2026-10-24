import '../storage/asset_record.dart';
import 'ai_analysis_store.dart';
import 'people_zip.dart' show undatedImport;
import 'face_crops.dart';
import 'face_matcher.dart';
import 'on_device_vision.dart';
import 'person.dart';

/// Forgets everything remembered about a person, from anywhere.
///
/// Deleting a person happens on two screens reached from five places, and
/// threading a service through all of them to delete a few rows is more
/// plumbing than the job is worth. Deletion is rare and this is a single
/// statement, so it opens its own handle — the same trade the detail
/// screen already makes for its analysis store.
Future<void> forgetPersonFaces(
  String personId, {
  AiAnalysisStore? analysisStore,
}) async {
  try {
    await (analysisStore ?? AiAnalysisStore()).forgetPerson(personId);
  } catch (_) {
    // No analysis database — nothing was remembered to forget.
  }
}

/// Forgets the faces of photos being hidden, so no face search, count or
/// avatar can reach them. Own handle, for the same reason as
/// [forgetPersonFaces].
Future<void> forgetHiddenFaces(
  Iterable<String> localIds, {
  AiAnalysisStore? analysisStore,
}) async {
  try {
    await (analysisStore ?? AiAnalysisStore()).forgetFacesOf(localIds);
  } catch (_) {
    // No analysis database — nothing was kept about them.
  }
}

/// Which part of [localId] is [personId] — their confirmed face if there
/// is one, otherwise the photo's only face, otherwise nothing.
///
/// Opens its own store for the same reason [forgetPersonFaces] does:
/// choosing a profile photo happens once in a while, from screens reached
/// five different ways, and threading a service to all of them to read one
/// rectangle is more plumbing than the job is worth.
Future<FaceRect?> faceOfPersonIn(
  String localId,
  String personId, {
  AiAnalysisStore? analysisStore,
}) async {
  try {
    final store = analysisStore ?? AiAnalysisStore();
    final confirmed = await store.faceOfPersonIn(localId, personId);
    if (confirmed != null) return confirmed;
    // Nobody said which face is theirs, but if there's only one in the
    // photo there's nothing to get wrong.
    final faces = await store.facesFor(localId);
    return faces.length == 1 ? faces.single : null;
  } catch (_) {
    // No analysis database — the whole photo is the fallback, as before.
    return null;
  }
}

/// Puts names to faces across photos: remembers what a confirmed face looks
/// like, and guesses who a new one is.
///
/// Guesses only. iOS gives boxes, never identity, so this stands a general
/// image descriptor in for a face model — good enough to offer a name,
/// never good enough to assert one. See
/// `docs/design/face-recognition/DESIGN.md`.
class FaceIdentityService {
  FaceIdentityService({
    required this.analysisStore,
    required this.resolvePath,
    OnDeviceVisionService? vision,
    this.matcher = const FaceMatcher(),
    this.onSeen,
  }) : vision = vision ?? OnDeviceVisionService();

  /// A face confirmed as someone, and the newest date among those photos:
  /// their Last seen moves up to it ([PersonStore.markSeen]).
  final Future<void> Function(String personId, DateTime at)? onSeen;

  final AiAnalysisStore analysisStore;

  /// What Vision reads for a photo — a file, or a camera-roll asset
  /// (`OnDeviceVisionService.assetSource`). `null` for one that can't be
  /// produced right now, which is a skip, not a failure.
  final Future<String?> Function(AssetRecord record) resolvePath;

  final OnDeviceVisionService vision;
  final FaceMatcher matcher;

  /// Spaces worth keeping. Narrowed to the model's once it is known to be
  /// loaded; see [FaceDescriptor.livePipelinesWithoutModel].
  Set<int> livePipelines = FaceDescriptor.livePipelines;

  bool _usable(FaceDescriptor? d) =>
      d != null && !d.isEmpty && !d.isStaleIn(livePipelines);

  /// Records that [face] in [record] is [personId], so the next photo of
  /// them can be guessed. Silent on anything that doesn't work out — a
  /// missed descriptor costs a suggestion, never the link the user just
  /// made. False when nothing could be saved.
  Future<bool> remember({
    required AssetRecord record,
    required FaceRect face,
    required String personId,
  }) => rememberMany([(record: record, face: face)], personId);

  /// [remember] for many faces at once: one read, one write, one
  /// transaction for the ones already described (05#16).
  Future<bool> rememberMany(
    List<({AssetRecord record, FaceRect face})> faces,
    String personId,
  ) async {
    if (faces.isEmpty) return false;
    DateTime? newest;
    for (final f in faces) {
      final r = f.record;
      // A hidden photo says nothing in the open; an undated import's date
      // is the day it came in.
      if (!r.isVisibleInLibrary || undatedImport(r)) continue;
      if (newest == null || r.createdAt.isAfter(newest)) newest = r.createdAt;
    }
    if (newest != null) {
      try {
        await onSeen?.call(personId, newest);
      } catch (_) {}
    }
    try {
      // Before the write: their *first* face is what turns "no opinion"
      // into a guess everywhere, so every unmatched photo earns another
      // look. Their tenth changes almost nothing and shouldn't re-run the
      // library.
      final isFirst = !await analysisStore.hasDescriptorsFor(personId);
      final stored = await analysisStore.descriptorsOf(
        faces.map((f) => f.record.localId),
      );
      final described = <({String localId, FaceRect face})>[];
      final missing = <String, List<({AssetRecord record, FaceRect face})>>{};
      for (final f in faces) {
        final key = AiAnalysisStore.faceKey(f.record.localId, f.face);
        if (_usable(stored[key])) {
          described.add((localId: f.record.localId, face: f.face));
        } else {
          missing.putIfAbsent(f.record.localId, () => []).add(f);
        }
      }
      final saved = {for (final f in described) f.localId};
      if (described.isNotEmpty) {
        await analysisStore.attachDescriptors(described, personId);
      }
      // Rare: the analyze pass describes every face it finds.
      for (final group in missing.values) {
        final path = await resolvePath(group.first.record);
        if (path == null) continue;
        final prints = await vision.featurePrints(path, [
          for (final f in group) FaceCrops.descriptorRect(f.face),
        ]);
        for (var i = 0; i < group.length; i++) {
          if (prints[i].isEmpty) continue;
          await analysisStore.saveDescriptor(
            localId: group[i].record.localId,
            face: group[i].face,
            personId: personId,
            descriptor: prints[i],
          );
          saved.add(group[i].record.localId);
        }
      }
      if (saved.isEmpty) return false;
      // These photos' own guesses are about a question that's now answered.
      await analysisStore.clearSuggestionsOf(saved);
      if (isFirst) await analysisStore.clearAllSuggestions();
      return true;
    } catch (_) {
      // No Vision, no file, no database. The person link stands either way.
      return false;
    }
  }

  /// Takes back one confirmation — the other half of a one-tap accept.
  Future<void> unremember({
    required String localId,
    required FaceRect face,
  }) async {
    try {
      await analysisStore.forgetDescriptor(localId, face);
    } catch (_) {
      // No analysis database — nothing was remembered to take back.
    }
  }

  /// Takes back every face confirmed as [personId] on one photo.
  Future<void> unrememberPhotos(
    String personId,
    Iterable<String> localIds,
  ) async {
    try {
      await analysisStore.forgetPersonOn(personId, localIds);
    } catch (_) {
      // No analysis database — nothing was remembered to take back.
    }
  }

  /// Forgets everything remembered about a person — what deleting them has
  /// to mean, or their faces go on winning matches under a name that no
  /// longer exists.
  Future<void> forget(String personId) =>
      forgetPersonFaces(personId, analysisStore: analysisStore);

  /// Describes each of [faces], guesses who it is against [confirmed], and
  /// records the answer — including "no opinion", which has to be stored
  /// or the pass asks the same unanswerable question of the same photo
  /// forever. False when nothing was recorded (no file for a face that
  /// still needs describing), so the caller can call it a skip.
  Future<bool> suggestFor({
    required AssetRecord record,
    required List<FaceRect> faces,
    required List<ConfirmedFace> confirmed,
  }) async {
    if (faces.isEmpty) return false;
    final stored = await analysisStore.descriptorsOf([record.localId]);
    final descriptors = {
      for (final f in faces)
        f: stored[AiAnalysisStore.faceKey(record.localId, f)],
    };
    // Described whether or not there is anyone to compare against: the
    // description is what "who else looks like this?" searches. The file
    // only when a face needs it (05#13) — after the first naming every
    // photo is matched again, and almost all are described already.
    final missing = [
      for (final f in faces)
        if (!_usable(descriptors[f])) f,
    ];
    if (missing.isNotEmpty) {
      final path = await resolvePath(record);
      if (path == null) return false;
      final prints = await vision.featurePrints(path, [
        for (final f in missing) FaceCrops.descriptorRect(f),
      ]);
      for (var i = 0; i < missing.length; i++) {
        descriptors[missing[i]] = prints[i];
        // Keeps the name on a face that had one (05#4).
        await analysisStore.saveDescriptor(
          localId: record.localId,
          face: missing[i],
          descriptor: prints[i],
        );
      }
    }
    final byFace = <String, String?>{
      for (final f in faces)
        f.encode(): switch (descriptors[f]) {
          final d? when !d.isEmpty && confirmed.isNotEmpty =>
            matcher.match(d, confirmed)?.personId,
          _ => null,
        },
    };
    await analysisStore.saveSuggestions(record.localId, byFace);
    return true;
  }
}
