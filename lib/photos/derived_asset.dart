import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import 'manual_add.dart';
import 'person_store.dart';
import 'photo_library_service.dart';

/// Files [bytes] as a new library item that inherits everything about
/// [source] except its pixels — same timestamp, description, tags, place,
/// people, and private-album membership, but its own hash-named
/// file. Every edit (crop, rotate, resize) lands this way, so the
/// photo that was edited — and whatever is already backed up under its
/// key — is never overwritten.
///
/// [keepMotion] is for a re-encode of the same frame (a resize): a Live
/// Photo's `.mov` goes along, so the copy still moves. The encoder keeps
/// the still's metadata, the tag pairing it to that `.mov` included. A
/// crop or rotate leaves it off — the video would no longer match. Throws
/// when the `.mov` can't be had.
Future<AssetRecord> createDerivedAsset({
  required AssetRecord source,
  required Uint8List bytes,
  required String extension,
  required AssetRecordStore store,
  PersonStore? personStore,
  bool keepMotion = false,
  Future<File?> Function(AssetRecord record)? liveVideo,
  Future<Directory> Function()? temporaryDirectory,

  /// Overridable for tests so they never touch the real app-support
  /// directory.
  ManualAddService? manualAdd,
}) async {
  // Asked before anything is made: a copy that should move but can't is
  // refused, so a "Replace Original" after it can't throw the motion away.
  File? motion;
  if (keepMotion && source.isLivePhoto) {
    motion = await (liveVideo ?? PhotoLibraryService.resolveLivePhotoVideo)(
      source,
    );
    if (motion == null || !await motion.exists()) {
      throw const FileSystemException("Live Photo's video isn't on this phone");
    }
  }
  final dir = await (temporaryDirectory ?? getTemporaryDirectory)();
  final staged = File(
    p.join(dir.path, 'edit-${DateTime.now().microsecondsSinceEpoch}$extension'),
  );
  await staged.writeAsBytes(bytes);

  final created = await (manualAdd ?? ManualAddService(store: store))
      .enqueueFile(staged.path, createdAt: source.createdAt);

  final id = created.localId;
  final ownedPath = created.sourcePath;
  if (motion != null && ownedPath != null) {
    await motion.copy(PhotoLibraryService.heldLiveVideoPath(ownedPath));
    await store.setLivePhoto(id, true);
  }
  if (source.description.isNotEmpty) {
    await store.setDescription(id, source.description);
  }
  if (source.tags.isNotEmpty) await store.setTags(id, source.tags);
  if (source.location != null) await store.setLocation(id, source.location);
  if (source.isFavorite) await store.setFavorite(id, true);
  if (source.isHidden) await store.setHidden(id, true);
  // An edit of a private-album photo belongs in that album, not loose in
  // the library.
  if (source.passcodeHash != null) {
    await store.setPasscodeHash(id, source.passcodeHash);
  }
  if (personStore != null) {
    for (final person in await personStore.peopleFor(source.localId)) {
      await personStore.addAssets(person.id, [id]);
    }
  }

  try {
    await staged.delete();
  } catch (_) {
    // The copy under app support is what matters; a leftover temp file is
    // the OS's to reclaim.
  }

  return (await store.getByLocalId(id)) ?? created;
}
