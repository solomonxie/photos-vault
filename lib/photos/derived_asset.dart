import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import 'manual_add.dart';
import 'person_store.dart';

/// Files [bytes] as a new library item that inherits everything about
/// [source] except its pixels — same timestamp, description, tags, place,
/// event, people, and private-album membership, but its own hash-named
/// file. Every edit (crop, rotate, AI touch-up) lands this way, so the
/// photo that was edited — and whatever is already backed up under its
/// key — is never overwritten.
Future<AssetRecord> createDerivedAsset({
  required AssetRecord source,
  required Uint8List bytes,
  required String extension,
  required AssetRecordStore store,
  PersonStore? personStore,
  Future<Directory> Function()? temporaryDirectory,

  /// Overridable for tests so they never touch the real app-support
  /// directory.
  ManualAddService? manualAdd,
}) async {
  final dir = await (temporaryDirectory ?? getTemporaryDirectory)();
  final staged = File(
    p.join(dir.path, 'edit-${DateTime.now().microsecondsSinceEpoch}$extension'),
  );
  await staged.writeAsBytes(bytes);

  final created = await (manualAdd ?? ManualAddService(store: store))
      .enqueueFile(staged.path, createdAt: source.createdAt);

  final id = created.localId;
  if (source.description.isNotEmpty) {
    await store.setDescription(id, source.description);
  }
  if (source.tags.isNotEmpty) await store.setTags(id, source.tags);
  if (source.location != null) await store.setLocation(id, source.location);
  if (source.event != null) await store.setEvent(id, source.event);
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
