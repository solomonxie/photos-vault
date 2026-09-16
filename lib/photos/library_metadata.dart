/// Edits that belong to the photo, not to this app — so they're written to
/// both places: our own record, and the entry the OS photo library keeps
/// for the same asset.
///
/// The point is that this app isn't a separate library. Hearting a photo
/// here and finding it un-hearted in Photos would mean keeping two mental
/// copies of the same collection, which is exactly what a backup app
/// shouldn't cost you.
///
/// What PhotoKit will actually accept is the limit here: **favourite** and
/// **creation date** are writable, and that's the whole list. A photo's
/// caption, its description and its tags have no public write API on iOS,
/// so those stay this app's own — see `docs/design/DESIGN.md`.
library;

import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import 'photo_library_service.dart';

/// Local record first, library second: the local write is the one the user
/// is waiting on, and [PhotoLibraryService.setFavoriteInLibrary] is
/// best-effort by design.
Future<void> setFavoriteEverywhere(
  AssetRecordStore store,
  AssetRecord record,
  bool isFavorite,
) async {
  await store.setFavorite(record.localId, isFavorite);
  await PhotoLibraryService.setFavoriteInLibrary(record, isFavorite);
}

Future<void> setCreatedAtEverywhere(
  AssetRecordStore store,
  AssetRecord record,
  DateTime createdAt,
) async {
  await store.setCreatedAt(record.localId, createdAt);
  await PhotoLibraryService.setCreatedAtInLibrary(record, createdAt);
}
