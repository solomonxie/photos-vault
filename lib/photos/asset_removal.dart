import 'dart:io';

import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import 'photo_library_service.dart';
import 'thumbnail_cache.dart';

/// The two ways a photo or video can go, and the work behind each.
///
/// One place rather than one per screen: which of the two a photo is
/// *eligible* for is a property of the photo — is it backed up, is there
/// a thumbnail to draw afterwards — and having each grid screen work that
/// out for itself is how Favorites ended up offering a plain delete for
/// something the library offered to keep in the cloud.
class AssetRemoval {
  AssetRemoval({
    required this.store,
    ThumbnailCache? thumbnails,
    PhotoLibraryService? library,
  }) : thumbnails = thumbnails ?? ThumbnailCache(store: store),
       library = library ?? PhotoLibraryService(store: store);

  final AssetRecordStore store;
  final ThumbnailCache thumbnails;
  final PhotoLibraryService library;

  /// Whether "keep the cloud copy, free the space" is on the table: there
  /// has to *be* a cloud copy, a local one to reclaim, and something left
  /// to draw in the grid afterwards.
  ///
  /// Both halves for a Live Photo — see [AssetRecord.isFullyBackedUp].
  /// Removing one whose `.mov` never went up would drop the motion and the
  /// sound with nothing holding them, which is exactly the loss this
  /// option claims not to be.
  bool canRemoveFromDevice(AssetRecord record) =>
      !record.localDeleted &&
      record.isFullyBackedUp &&
      ThumbnailCache.canThumbnail(record);

  /// Frees the device storage and keeps the asset in the library: cache a
  /// thumbnail first (that's what the grid draws from now on), then drop
  /// the full-resolution local copy — from the OS photo library for a
  /// camera-roll asset, since this app never held its own copy of one.
  ///
  /// False means nothing moved: no thumbnail could be made, or the OS
  /// prompt was declined.
  Future<bool> removeFromDevice(AssetRecord record) async {
    try {
      // A video's poster frame comes from the library itself, so there's
      // no need to export the whole movie just to make a picture of it.
      final path = record.isVideo ? null : await localPathOf(record);
      if (path == null && !record.isVideo) return false;
      if (await thumbnails.ensureFor(record, path) == null) return false;

      if (record.sourcePath != null) {
        await File(record.sourcePath!).delete();
      } else {
        // iOS puts up its own confirmation; a decline lands here as false
        // and must not leave the record claiming to be cloud-only.
        if (!await library.deleteFromLibrary(record)) return false;
      }
      await store.setLocalDeleted(record.localId, true);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// The ordinary delete: out of the OS photo library too, and into this
  /// app's own Recently Deleted rather than straight out of existence.
  ///
  /// The bucket copy is deliberately left alone — this app's Recently
  /// Deleted has to be restorable to mean anything, and the backed-up copy
  /// is the one that survives a lost phone. It's purged only when the bin
  /// is emptied.
  Future<bool> deleteEverywhere(AssetRecord record) async {
    if (record.sourceType == AssetSourceType.photoManager &&
        !record.localDeleted &&
        !await _deleteFromLibrary(record)) {
      return false;
    }
    if (record.hasNothingLeft) {
      // Never backed up, and the library copy has just gone — there is
      // nothing left to restore, so the bin doesn't pretend otherwise.
      await store.remove(record.localId);
      return true;
    }
    await store.softDelete(record.localId);
    return true;
  }

  /// Drops bin entries with nothing behind them and returns what's left to
  /// show. Kept here rather than in the bin screen because "is there
  /// anything left of this photo" is a question about the photo.
  ///
  /// The library is asked again per record: a record can only be called
  /// empty once the OS has let go of it too, and an unreadable answer
  /// (no plugin, a permission withdrawn) keeps the record.
  Future<List<AssetRecord>> purgeVanished(List<AssetRecord> records) async {
    final kept = <AssetRecord>[];
    for (final record in records) {
      if (record.hasNothingLeft && await _goneFromLibrary(record)) {
        await store.remove(record.localId);
      } else {
        kept.add(record);
      }
    }
    return kept;
  }

  Future<bool> _goneFromLibrary(AssetRecord record) async {
    if (record.libraryId == null) return true;
    try {
      return await library.entityFor(record) == null;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _deleteFromLibrary(AssetRecord record) async {
    try {
      return await library.deleteFromLibrary(record);
    } catch (_) {
      // No plugin, or it's already gone from the library — either way
      // there's nothing over there left to delete.
      return true;
    }
  }

  /// The local file, or null when there isn't one to be had. May trigger
  /// an iCloud download on iOS, so it can be slow the first time.
  Future<String?> localPathOf(AssetRecord record) async {
    if (record.localDeleted) return null;
    final path = record.sourcePath;
    if (path != null && File(path).existsSync()) return path;
    if (record.sourceType != AssetSourceType.photoManager) return null;
    try {
      return (await library.fileFor(record))?.path;
    } catch (_) {
      return null;
    }
  }
}
