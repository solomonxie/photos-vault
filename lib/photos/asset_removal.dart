import 'dart:async';
import 'dart:io';

import '../settings/backup_targets_store.dart';
import '../settings/s3_backup_target.dart';
import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import '../upload/backup_verifier.dart';
import '../upload/object_keys.dart';
import '../upload/pending_deletes.dart';
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
    BackupTargetsStore? targetsStore,
    PendingDeletes? pendingDeletes,
  }) : thumbnails = thumbnails ?? ThumbnailCache(store: store),
       library = library ?? PhotoLibraryService(store: store),
       _targets = targetsStore ?? BackupTargetsStore(),
       pendingDeletes = pendingDeletes ?? PendingDeletes(store: store),
       verifier =
           verifier ??
           BackupVerifier(
             targetsStore: targetsStore ?? BackupTargetsStore(),
             recordStore: store,
           );

  final AssetRecordStore store;
  final ThumbnailCache thumbnails;
  final PhotoLibraryService library;
  final BackupTargetsStore _targets;

  /// Where a permanent delete leaves what the buckets still owe it: queued,
  /// so a delete made offline, or against a dead bucket, still ends.
  final PendingDeletes pendingDeletes;

  /// How long a photo stays in Recently Deleted before it is purged.
  static const binRetention = Duration(days: 30);

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
  ///
  /// And the bucket has to hold a thumbnail too: with the original gone and
  /// no cached picture left (a reinstall, a wiped cache), it is the only
  /// thing a cloud-only tile can be drawn from. Hidden photos draw from the
  /// encrypted vault cache instead.
  bool canRemoveFromDevice(AssetRecord record) =>
      !record.localDeleted &&
      record.isFullyBackedUp &&
      _thumbnailBackedUp(record) &&
      ThumbnailCache.canThumbnail(record);

  static bool _thumbnailBackedUp(AssetRecord record) =>
      record.passcodeHash != null ||
      record.stateOf(DerivativeKind.thumbnail).status == UploadStatus.uploaded;

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
    if (record.passcodeHash == null) {
      switch (await verifier.proveThumbnail(record)) {
        case CopyProof.present:
          break;
        case CopyProof.missing || CopyProof.notRecorded:
          await store.updateDerivative(
            record.localId,
            DerivativeKind.thumbnail,
            record
                .stateOf(DerivativeKind.thumbnail)
                .copyWith(status: UploadStatus.pending),
          );
          return RemovalOutcome.backupMissing;
        case CopyProof.unreachable:
          return RemovalOutcome.backupUnverifiable;
      }
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
    await binOrPurge(record);
    return true;
  }

  /// Into the bin, or straight out of existence when nothing of the photo
  /// is anywhere else — the bin doesn't pretend otherwise. The one place
  /// that decides, so a batch delete can't bin what a single one purges.
  Future<void> binOrPurge(AssetRecord record) async {
    if (await isRecoverable(record)) {
      await store.softDelete(record.localId);
    } else {
      await _discard(record, await _loadTargets(), null);
    }
  }

  /// The permanent delete: the photo is gone from this phone at once and
  /// what it left in the buckets is queued for deletion, retried on every
  /// sync until each bucket has let go.
  ///
  /// Queued rather than attempted inline, because the old inline delete
  /// kept the photo on screen for as long as any one bucket was dead, and
  /// orphaned its objects when none was configured.
  ///
  /// Out of the OS photo library too, unless it is in the bin already —
  /// that delete was made then. False when the OS prompt was declined, or
  /// the photo is locked or hidden (hidden ones have their own,
  /// `HiddenRemoval`).
  Future<bool> deletePermanently(AssetRecord record) async {
    if (record.isLocked || record.passcodeHash != null) return false;
    if (record.deletedAt == null &&
        record.sourceType == AssetSourceType.photoManager &&
        !record.localDeleted &&
        PhotoLibraryService.libraryIdOf(record) != null &&
        !await _deleteFromLibrary(record)) {
      return false;
    }
    await _discard(record, await _loadTargets(), null);
    unawaited(_drain());
    return true;
  }

  /// Everything in the bin, for good. Returns how many went.
  Future<int> emptyBin() =>
      _purgeBinned((r) => r.isDeleted && r.passcodeHash == null && !r.isLocked);

  /// Purges what has sat in the bin for [binRetention]. Run on every sync.
  Future<int> expireBin() {
    final cutoff = DateTime.now().subtract(binRetention);
    return _purgeBinned(
      (r) =>
          r.deletedAt != null &&
          r.deletedAt!.isBefore(cutoff) &&
          r.passcodeHash == null &&
          !r.isLocked,
    );
  }

  Future<int> _purgeBinned(bool Function(AssetRecord) test) async {
    final victims = [
      for (final r in await store.listAll())
        if (test(r)) r,
    ];
    if (victims.isEmpty) return 0;
    final targets = await _loadTargets();
    final held = groupUploads(await store.uploadRows());
    for (final record in victims) {
      await _discard(record, targets, held[record.localId] ?? const {});
    }
    unawaited(_drain());
    return victims.length;
  }

  /// Queues the bucket deletions, then drops the row — in that order,
  /// because the row removal takes the per-bucket upload rows with it.
  Future<void> _discard(
    AssetRecord record,
    List<S3BackupTarget> targets,
    HeldKeys? held,
  ) async {
    final tasks = deletionTasksFor(
      record,
      targets,
      held ?? await heldKeysOf(store, record.localId),
    );
    if (tasks.isNotEmpty) await pendingDeletes.add(tasks);
    await purge(record);
  }

  Future<void> _drain() async {
    try {
      await pendingDeletes.drain(await _targets.loadAll());
    } catch (_) {
      // Queued; the next sync retries.
    }
  }

  Future<List<S3BackupTarget>> _loadTargets() async {
    try {
      return await _targets.loadAll();
    } catch (_) {
      return const [];
    }
  }

  /// Brings a binned photo back. One that was backed up and has since left
  /// the OS library comes back cloud-only straight away, rather than as a
  /// blank tile until a scan notices; this app has no way to put a photo
  /// back into Photos, so Download is how it returns.
  Future<void> recover(AssetRecord record) async {
    await store.restore(record.localId);
    if (record.sourceType == AssetSourceType.photoManager &&
        !record.localDeleted &&
        record.isFullyBackedUp &&
        record.sourcePath == null &&
        await _goneFromLibrary(record)) {
      await store.setLocalDeleted(record.localId, true);
    }
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

  /// Drops bin entries that can't be given back and returns what's left to
  /// show. Kept here rather than in the bin screen because "is there
  /// anything left of this photo" is a question about the photo.
  Future<List<AssetRecord>> purgeVanished(List<AssetRecord> records) async {
    final kept = <AssetRecord>[];
    List<S3BackupTarget>? targets;
    for (final record in records) {
      if (await isRecoverable(record)) {
        kept.add(record);
      } else {
        await _discard(record, targets ??= await _loadTargets(), null);
      }
    }
    return kept;
  }

  /// Whether Recover would bring the photo back: the original in a bucket,
  /// its own file on this phone, or Photos still holding it. A thumbnail
  /// alone is a preview, not the photo.
  ///
  /// An unreadable answer from the library (no plugin, a permission
  /// withdrawn) counts as still there: dropping a photo on a guess is the
  /// worse mistake.
  Future<bool> isRecoverable(AssetRecord record) async {
    final original = record.stateOf(DerivativeKind.original);
    if (original.status == UploadStatus.uploaded ||
        original.destinationKey != null) {
      return true;
    }
    if (record.sourcePath != null && !record.localDeleted) return true;
    return !await _goneFromLibrary(record);
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
