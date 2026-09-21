import '../storage/asset_record.dart';
import 'ai_analysis_store.dart';
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
  }) : vision = vision ?? OnDeviceVisionService();

  final AiAnalysisStore analysisStore;

  /// A photo's file on disk — `null` for one that can't be produced right
  /// now, which is a skip, not a failure.
  final Future<String?> Function(AssetRecord record) resolvePath;

  final OnDeviceVisionService vision;
  final FaceMatcher matcher;

  /// Records that [face] in [record] is [personId], so the next photo of
  /// them can be guessed. Silent on anything that doesn't work out — a
  /// missed descriptor costs a suggestion, never the link the user just
  /// made.
  Future<void> remember({
    required AssetRecord record,
    required FaceRect face,
    required String personId,
  }) async {
    try {
      // Already described, most of the time — the analyze pass describes
      // every face it finds. Naming one is then a column update, not
      // another look at the photo.
      var descriptor = await analysisStore.descriptorFor(record.localId, face);
      if (descriptor == null || descriptor.isEmpty || descriptor.isStale) {
        final path = await resolvePath(record);
        if (path == null) return;
        descriptor = await vision.featurePrint(
          path,
          face: FaceCrops.descriptorRect(face),
        );
        if (descriptor.isEmpty) return;
      }
      // Before the write: their *first* face is what turns "no opinion"
      // into a guess everywhere, so every unmatched photo earns another
      // look. Their tenth changes almost nothing and shouldn't re-run the
      // library.
      final isFirst = !await analysisStore.hasDescriptorsFor(personId);
      await analysisStore.saveDescriptor(
        localId: record.localId,
        face: face,
        personId: personId,
        descriptor: descriptor,
      );
      // This photo's own guesses are about a question that's now answered.
      await analysisStore.clearSuggestions(record.localId);
      if (isFirst) await analysisStore.clearAllSuggestions();
    } catch (_) {
      // No Vision, no file, no database. The person link stands either way.
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

  /// Forgets everything remembered about a person — what deleting them has
  /// to mean, or their faces go on winning matches under a name that no
  /// longer exists.
  Future<void> forget(String personId) =>
      forgetPersonFaces(personId, analysisStore: analysisStore);

  /// Describes each of [faces], guesses who it is against [confirmed], and
  /// records the answer — including "no opinion", which has to be stored
  /// or the pass asks the same unanswerable question of the same photo
  /// forever.
  Future<void> suggestFor({
    required AssetRecord record,
    required List<FaceRect> faces,
    required List<ConfirmedFace> confirmed,
  }) async {
    if (faces.isEmpty) return;
    final byFace = <String, String?>{for (final f in faces) f.encode(): null};
    // Described whether or not there is anyone to compare against: the
    // description is what "who else looks like this?" searches, and it is
    // the same Vision pass either way.
    final path = await resolvePath(record);
    if (path == null) return;
    for (final face in faces) {
      var descriptor = await analysisStore.descriptorFor(record.localId, face);
      if (descriptor == null || descriptor.isEmpty || descriptor.isStale) {
        descriptor = await vision.featurePrint(
          path,
          face: FaceCrops.descriptorRect(face),
        );
        if (descriptor.isEmpty) continue;
        await analysisStore.saveDescriptor(
          localId: record.localId,
          face: face,
          descriptor: descriptor,
        );
      }
      if (confirmed.isEmpty) continue;
      byFace[face.encode()] = matcher.match(descriptor, confirmed)?.personId;
    }
    await analysisStore.saveSuggestions(record.localId, byFace);
  }
}
