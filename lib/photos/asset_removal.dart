import 'dart:async';
import 'dart:io';

import '../settings/backup_targets_store.dart';
import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import '../upload/backup_verifier.dart';
import 'photo_library_service.dart';
import 'thumbnail_cache.dart';

/// What [AssetRemoval.removeFromDevice] did, and when it didn't, why.
///
/// Four outcomes rather than a bool because the three failures need three
/// different sentences: one is "make a thumbnail first", one is "your
/// bucket hasn't got this photo", and one is "ask again when you're
/// online". Collapsing them into false is how a photo gets dropped on the
/// strength of a backup nobody checked.
enum RemovalOutcome {
  /// The local copy is gone, the bucket's copy is confirmed, the record is
  /// cloud-only.
  freed,

  /// Nothing moved: no thumbnail could be made, or the OS prompt was
  /// declined.
  failed,

  /// The bucket answered, and it has not got this photo — whatever this
  /// app's own row said. Nothing was deleted, and the derivative has been
  /// put back in the upload queue.
  backupMissing,

  /// No bucket could be reached, so the copy could not be confirmed.
  /// Freeing space is never urgent enough to do it unverified.
  backupUnverifiable;

  bool get freedSpace => this == RemovalOutcome.freed;
}

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
    BackupVerifier? verifier,
  }) : thumbnails = thumbnails ?? ThumbnailCache(store: store),
       library = library ?? PhotoLibraryService(store: store),
       verifier =
           verifier ??
           BackupVerifier(
             targetsStore: BackupTargetsStore(),
             recordStore: store,
           );

  final AssetRecordStore store;
  final ThumbnailCache thumbnails;
  final PhotoLibraryService library;

  /// Asked before the last local copy of anything goes. [canRemoveFromDevice]
  /// reads this app's own row, which is a claim; this asks the bucket, which
  /// is an answer.
  final BackupVerifier verifier;

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
  /// The bucket is asked first, every time. One HEAD request against the
  /// object this app says it uploaded, before the only copy on the phone is
  /// deleted on the strength of that claim — a wrong prefix, a lifecycle
  /// rule or one upload that reported a success it didn't have all look
  /// identical from inside the database, and all three cost the photo.
  Future<RemovalOutcome> removeFromDevice(AssetRecord record) async {
    if (record.isLocked) return RemovalOutcome.failed;
    switch (await verifier.proveOriginal(record)) {
      case CopyProof.present:
        break;
      case CopyProof.missing:
      // A record claiming to be uploaded with no key to check is in the
      // same position as one the bucket hasn't got: there is nothing
      // anywhere that can be shown to hold it. (An un-uploaded derivative
      // never reaches here — `canRemoveFromDevice` turns it down first.)
      case CopyProof.notRecorded:
        // The row was wrong. Put it back in the queue so the next sync
        // makes it true, rather than leaving it claiming to be backed up.
        await store.updateDerivative(
          record.localId,
          DerivativeKind.original,
          record
              .stateOf(DerivativeKind.original)
              .copyWith(status: UploadStatus.pending),
        );
        return RemovalOutcome.backupMissing;
      case CopyProof.unreachable:
        return RemovalOutcome.backupUnverifiable;
    }
    try {
      // A video's poster frame comes from the library itself, so there's
      // no need to export the whole movie just to make a picture of it.
      final path = record.isVideo ? null : await localPathOf(record);
      if (path == null && !record.isVideo) return RemovalOutcome.failed;
      if (await thumbnails.ensureFor(record, path) == null) {
        return RemovalOutcome.failed;
      }

      if (record.sourcePath != null) {
        await File(record.sourcePath!).delete();
      } else {
        // iOS puts up its own confirmation; a decline lands here and must
        // not leave the record claiming to be cloud-only.
        if (!await library.deleteFromLibrary(record)) {
          return RemovalOutcome.failed;
        }
      }
      await store.setLocalDeleted(record.localId, true);
      return RemovalOutcome.freed;
    } catch (_) {
      return RemovalOutcome.failed;
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
    // The lock's promise holds on every screen, not just the library's.
    if (record.isLocked) return false;
    // Only when the library still has it. A photo taken out of Photos
    // (hidden, or restored with no library entry) has no library id, and
    // the library answers "nothing deleted" for it — which used to fail the
    // whole delete, so nothing happened at all.
    if (record.sourceType == AssetSourceType.photoManager &&
        !record.localDeleted &&
        PhotoLibraryService.libraryIdOf(record) != null &&
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

  /// The last of a photo on this phone: its own files and its row. For a
  /// permanent delete, once the bucket has already let go of it.
  ///
  /// The row first: a file left behind by a crash is an orphan on disk, a
  /// row left pointing at deleted files is a broken tile.
  Future<void> purge(AssetRecord record) async {
    await store.remove(record.localId);
    for (final path in [record.sourcePath, record.thumbnailPath]) {
      if (path != null) unawaited(_deleteQuietly(path));
    }
  }

  static Future<void> _deleteQuietly(String path) async {
    try {
      await File(path).delete();
    } catch (_) {
      // Already gone.
    }
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
