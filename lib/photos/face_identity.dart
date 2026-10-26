import '../storage/asset_record.dart';
import 'ai_analysis_store.dart';
import 'conversation_store.dart';
import 'person.dart';
import 'words_store.dart';

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
  await forgetConversations(personId);
  await forgetWords(personId);
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

/// Which face is whose: the links naming makes. Nothing here guesses —
/// recognition comes from the Mac import (`docs/design/face-recognition/MAC-PIPELINE.md`).
class FaceIdentityService {
  FaceIdentityService({required this.analysisStore});

  final AiAnalysisStore analysisStore;

  /// Records that [face] in [record] is [personId]. Silent on failure: the
  /// person link the user just made stands either way. False when nothing
  /// could be saved.
  Future<bool> remember({
    required AssetRecord record,
    required FaceRect face,
    required String personId,
  }) => rememberMany([(record: record, face: face)], personId);

  /// [remember] for many faces at once, in one write.
  Future<bool> rememberMany(
    List<({AssetRecord record, FaceRect face})> faces,
    String personId,
  ) async {
    if (faces.isEmpty) return false;
    try {
      await analysisStore.nameFaces([
        for (final f in faces) (localId: f.record.localId, face: f.face),
      ], personId);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Takes back one confirmation.
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

  /// Takes back every face confirmed as [personId] on these photos.
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

  /// Forgets everything remembered about a person.
  Future<void> forget(String personId) =>
      forgetPersonFaces(personId, analysisStore: analysisStore);
}
