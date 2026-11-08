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

/// Returns once our records hold the dates, so the screen shows them at
/// once. PhotoKit follows in the background, one asset at a time: each
/// write can wait on iOS's "Allow to modify this photo?" or on iCloud.
/// Refused or not, the dates are marked as set here, and the mark stays:
/// Photos' own date never comes back over the user's choice.
Future<void> setCreatedAtEverywhere(
  AssetRecordStore store,
  Map<AssetRecord, DateTime> dates,
) async {
  await store.setCreatedAtMany({
    for (final MapEntry(key: record, value: at) in dates.entries)
      record.localId: at,
  });
  final writes = [...dates.entries];
  _libraryWrites = _libraryWrites.then((_) async {
    for (final MapEntry(key: record, value: at) in writes) {
      try {
        await PhotoLibraryService.setCreatedAtInLibrary(record, at);
      } catch (_) {
        // Best-effort, as the favourite is; the next one still goes.
      }
    }
  });
}

/// One PhotoKit date write after another: prompts never stack.
Future<void> _libraryWrites = Future.value();
