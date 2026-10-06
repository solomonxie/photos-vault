import 'dart:async';
import 'dart:io';

import '../photos/photo_library_service.dart';
import '../photos/thumbnail_cache.dart';
import '../settings/backup_targets_store.dart';
import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import 'backup_coordinator.dart';
import 'pending_deletes.dart';
import 'sync_job.dart';
import 'sync_job_store.dart';
import 'sync_queue.dart';

/// The sync machinery with no screen in it: what turns a pending record into
/// queued jobs and a job into an upload. The library screen drives it with
/// its own state and UI hooks; the background run (`background_sync.dart`)
/// drives the same code with none.
class SyncEngine {
  SyncEngine({
    required this.recordStore,
    required this.targetsStore,
    required this.coordinator,
    required this.thumbnailCache,
    required this.library,
    required this.syncJobStore,
    required this.pendingDeletes,
    required this.records,
    required this.displayName,
    required this.hashFile,
    this.finishHidden,
    this.analyze,
    this.kinds,
  });

  /// Which job kinds this engine drains; null is all of them.
  final Set<SyncJobKind>? kinds;

  final AssetRecordStore recordStore;
  final BackupTargetsStore targetsStore;
  final BackupCoordinator coordinator;
  final ThumbnailCache thumbnailCache;
  final PhotoLibraryService library;
  final SyncJobStore syncJobStore;
  final PendingDeletes pendingDeletes;

  /// The library as the caller currently holds it.
  final List<AssetRecord> Function() records;

  /// What a queue row says for a record.
  final String Function(AssetRecord record) displayName;
  final Future<String> Function(String path) hashFile;

  /// Hidden photos need an open album; absent where none can be open.
  final Future<void> Function(AssetRecord record)? finishHidden;

  /// `analyzePhoto` jobs belong to the screen's on-device analysis.
  final Future<void> Function(AssetRecord record, String path)? analyze;

  late final SyncQueue syncQueue = SyncQueue(
    store: syncJobStore,
    settings: targetsStore,
    process: processJob,
    kinds: kinds,
  );

  /// Uploads that failed since the app opened. Cleared by an explicit sync.
  final triedAndFailed = <String>{};

  /// Photos whose file couldn't be found this session. Kept so the refill
  /// stops offering them: a record still marked pending, whose file can't
  /// be resolved, is picked up by every refill, dropped by every worker,
  /// and picked up again — a loop that never uploads anything and never
  /// ends. Cleared whenever the camera roll is re-read.
  final unresolvable = <String>{};

  /// Hidden photos waiting for their album to be opened. Not a failure.
  final heldUntilUnlocked = <String>{};

  /// Owed a thumbnail but with nothing to make one from this session.
  final thumbnailUnavailable = <String>{};

  void forgetFailures() {
    triedAndFailed.clear();
    unresolvable.clear();
  }

  /// Everything still owed an upload — hidden photos included by default,
  /// because they need it most: the app took them out of Photos, so the
  /// bucket is the only other copy there is.
  List<AssetRecord> get pendingAndFailed => records().where((r) {
    if (r.isDeleted || unresolvable.contains(r.localId)) return false;
    // Hidden, with its album locked. Queueing it again would be a loop:
    // the job takes, does nothing, finishes, and the refill hands it
    // straight back.
    if (heldUntilUnlocked.contains(r.localId) && !coordinator.canUpload(r)) {
      return false;
    }
    // A Live Photo whose still went up but whose `.mov` didn't is still
    // owed to the bucket — what's up there is a silent still.
    return !r.isFullyBackedUp;
  }).toList();

  /// Backed-up photos whose thumbnail never went up — the small ones the
  /// upload used to skip. Hidden ones draw from the vault cache instead.
  List<AssetRecord> get thumbnailsOwed => records()
      .where(
        (r) =>
            !r.isDeleted &&
            r.passcodeHash == null &&
            r.isFullyBackedUp &&
            r.stateOf(DerivativeKind.thumbnail).status !=
                UploadStatus.uploaded &&
            !thumbnailUnavailable.contains(r.localId),
      )
      .toList();

  Future<bool> hasBackupTarget() async {
    try {
      return (await targetsStore.loadAll()).isNotEmpty;
    } catch (_) {
      // Secure storage unavailable — skip this round rather than queue
      // work that can't land; the next sync-due check tries again.
      return false;
    }
  }

  /// Newest photo first, wherever a list of records turns into queued work.
  ///
  /// The queue is capped and a library is years deep, so the order this
  /// list is walked in decides what gets backed up today and what waits for
  /// a later refill. Last week's photos are the ones with no second copy
  /// anywhere; 2014's have had a decade of chances.
  static List<AssetRecord> newestFirst(List<AssetRecord> records) =>
      records.toList()..sort((a, b) => b.createdAt.compareTo(a.createdAt));

  /// Queues [records] for backup rather than uploading them here: one job
  /// per derivative per asset, drained by [syncQueue] with real concurrency.
  /// Returns how many assets were queued — not how many landed, which isn't
  /// knowable until the queue gets to them, and not how many were *asked*
  /// for: the queue is capped ([SyncQueue.capacity]) and refuses while
  /// paused, so a big library goes up a queueful at a time.
  Future<int> backUpRecords(List<AssetRecord> records) async {
    // Nothing to upload *to* yet: queueing anyway would walk the whole
    // camera roll resolving each asset's file — on a real library that's
    // thousands of exports (and iCloud downloads) handed to a coordinator
    // with nowhere to put them. Adding a target runs a sync, which picks
    // every pending asset up then.
    //
    // Except hidden photos: the job is also what encrypts and files them,
    // and with no bucket that still has to happen — or they stay plain
    // files for good. Their carriers go up once a bucket exists.
    final hasTarget = await hasBackupTarget();
    final work = hasTarget
        ? records
        : [
            for (final r in records)
              if (r.passcodeHash != null && coordinator.canUpload(r)) r,
          ];
    var queued = 0;
    var enqueuedAny = false;

    /// Queues one photo's jobs; false when the queue is full or paused.
    Future<bool> queueRecord(AssetRecord record) async {
      final hidden = record.passcodeHash != null;
      // Hidden photos jump the queue: the app took them out of Photos, so
      // until a carrier is up this phone holds the only copy.
      final priority = hidden ? 1 : 0;
      final name = displayName(record);
      // The thumbnail goes in *first*, and not for the bucket's sake:
      // `uploadThumbnail` is also what puts the picture this app draws
      // once the original is gone onto disk. Queued first, the job a full
      // queue turns away is the *original*, which is still pending and
      // comes back on the next pass.
      //
      // A hidden photo gets no `thumbnails/` copy: the same picture at
      // 320px in the folder built for cheap browsing — the private album's
      // contents, legible to anyone who can read the bucket. A Live Photo's
      // `.mov` does go, as a carrier of its own.
      if (!hidden) {
        final tookThumbnail = await syncQueue.enqueue(
          localId: record.localId,
          kind: SyncJobKind.uploadThumbnail,
          displayName: name,
          assetCreatedAt: record.createdAt,
        );
        if (!tookThumbnail) return false;
        enqueuedAny = true;
      }
      final taken = await syncQueue.enqueue(
        localId: record.localId,
        kind: SyncJobKind.uploadOriginal,
        displayName: name,
        assetCreatedAt: record.createdAt,
        priority: priority,
      );
      if (!taken) return false;
      enqueuedAny = true;
      queued++;
      // The other half of a Live Photo. A job of its own rather than part
      // of the original's, so it shows in the queue by name and a failure
      // to fetch the `.mov` doesn't take the still down with it.
      if (record.isLivePhoto) {
        await syncQueue.enqueue(
          localId: record.localId,
          kind: SyncJobKind.uploadLivePhoto,
          displayName: name,
          assetCreatedAt: record.createdAt,
          priority: priority,
        );
      }
      return true;
    }

    // Hidden first, then the owed thumbnails, then the library — so a
    // full queue never turns a hidden photo away for library work.
    final ordered = newestFirst(work);
    var full = false;
    for (final record in ordered.where((r) => r.passcodeHash != null)) {
      if (!await queueRecord(record)) {
        full = true;
        break;
      }
    }
    if (hasTarget && !full) {
      for (final record in newestFirst(thumbnailsOwed)) {
        if (!await syncQueue.enqueue(
          localId: record.localId,
          kind: SyncJobKind.uploadThumbnail,
          displayName: displayName(record),
          assetCreatedAt: record.createdAt,
        )) {
          full = true;
          break;
        }
        enqueuedAny = true;
      }
    }
    if (!full) {
      // Full or paused stops the walk — on a real camera roll the rest is
      // tens of thousands of records, still pending for the next pass.
      for (final record in ordered.where((r) => r.passcodeHash == null)) {
        if (!await queueRecord(record)) break;
      }
    }
    // Only when there's something to drain: starting an empty drain would
    // flip `draining` and bring the screen's listener straight back here.
    if (enqueuedAny) unawaited(syncQueue.start());
    return queued;
  }

  /// Queues a change check per already-backed-up asset. Each one re-hashes
  /// that asset's local file to spot an edit since its last backup — real
  /// work against a real file, so it's a queued job like any upload rather
  /// than a silent pass, and shows up in the queue by name.
  Future<int> enqueueChangeChecks() async {
    final uploaded = records().where((r) {
      // Cloud-only assets have no local file left to compare against, and
      // neither has one whose file this pass already failed to find —
      // asking again every sync is how one deleted photo becomes a
      // permanent red row.
      if (r.isDeleted || r.localDeleted) return false;
      if (unresolvable.contains(r.localId)) return false;
      return r.stateOf(DerivativeKind.original).status == UploadStatus.uploaded;
    }).toList();
    for (final record in newestFirst(uploaded)) {
      await syncQueue.enqueue(
        localId: record.localId,
        kind: SyncJobKind.checkChanges,
        displayName: displayName(record),
        assetCreatedAt: record.createdAt,
      );
    }
    return uploaded.length;
  }

  /// The queue worker. One job is one asset and one kind of work, so a
  /// stalled file blocks only itself, and "what is it doing" is always
  /// answerable from the queue list.
  Future<void> processJob(SyncJob job) async {
    final record = await recordStore.getByLocalId(job.localId);
    // Deleted out from under the queue — nothing left to do, and not worth
    // reporting as a failure.
    if (record == null) return;
    switch (job.kind) {
      case SyncJobKind.checkChanges:
        await _checkOneForLocalChanges(record);
      case SyncJobKind.uploadOriginal:
        // A hidden photo whose album is closed: the key lives only in
        // memory, and there is no version of this worth doing without it.
        if (!coordinator.canUpload(record)) {
          heldUntilUnlocked.add(record.localId);
          return;
        }
        final path = await filePathFor(record);
        if (path == null) {
          unresolvable.add(record.localId);
          return;
        }
        try {
          await coordinator.backUpDerivative(
            record: record,
            kind: DerivativeKind.original,
            filePath: path,
          );
          final after = await recordStore.getByLocalId(record.localId);
          await _queueOrphanedKey(record, after);
          if (after?.stateOf(DerivativeKind.original).status ==
              UploadStatus.failed) {
            triedAndFailed.add(record.localId);
          } else if (after != null) {
            await finishHidden?.call(after);
            // Nothing landed and nothing was filed (no bucket and no
            // carrier yet): not handed back by every refill.
            if (after.stateOf(DerivativeKind.original).status ==
                    UploadStatus.pending &&
                await recordStore.getByLocalId(record.localId) != null) {
              triedAndFailed.add(record.localId);
            }
          }
        } catch (_) {
          // Thrown or recorded, a failure is a failure: remembered either
          // way, so the refill stops handing this one back to the queue.
          // Rethrown so the queue still shows the row and its reason.
          triedAndFailed.add(record.localId);
          rethrow;
        }
      case SyncJobKind.uploadLivePhoto:
        // Straight from the photo library, with the subtype that makes
        // PhotoKit hand back the `.mov` rather than the still frame.
        final file = await _resolveLiveVideo(record);
        if (file == null) {
          // Not a Live Photo any more, or its video half isn't downloaded
          // from iCloud. Nothing to upload and nothing to report.
          return;
        }
        await coordinator.backUpDerivative(
          record: record,
          kind: DerivativeKind.livePhoto,
          filePath: file.path,
        );
        // The still may already be held, in which case this was the half
        // the settle was waiting on.
        final settled = await recordStore.getByLocalId(record.localId);
        if (settled != null) await finishHidden?.call(settled);
      case SyncJobKind.uploadThumbnail:
        final path = await _uploadableThumbnailFor(record);
        if (path == null) {
          thumbnailUnavailable.add(record.localId);
          return;
        }
        await coordinator.backUpDerivative(
          record: record,
          kind: DerivativeKind.thumbnail,
          filePath: path,
        );
      case SyncJobKind.analyzePhoto:
        // Videos have no still to look at, and Vision only reads images.
        if (record.isVideo) return;
        final path = await filePathFor(record);
        if (path == null) {
          unresolvable.add(record.localId);
          return;
        }
        await analyze?.call(record, path);
    }
  }

  /// Re-hashes one asset's local file and, if it's been edited since its
  /// last successful backup, flips it back to pending and queues the
  /// re-upload straight away rather than waiting for the next sync.
  Future<void> _checkOneForLocalChanges(AssetRecord record) async {
    final path = await filePathFor(record);
    if (path == null) {
      unresolvable.add(record.localId);
      return;
    }
    final String hash;
    try {
      hash = await hashFile(path);
    } catch (_) {
      // The file went between the check and the read — deleted in Photos
      // mid-pass, most likely. "Is this photo different from the copy in
      // the bucket?" has no answer when there's no photo to compare, and
      // that is not a failure worth a red row in the queue: the backup
      // that's already up there is still good.
      unresolvable.add(record.localId);
      return;
    }
    final state = record.stateOf(DerivativeKind.original);
    if (hash == state.backedUpHash) {
      await _checkMotionHalf(record);
      return;
    }
    await recordStore.updateDerivative(
      record.localId,
      DerivativeKind.original,
      DerivativeState(
        status: UploadStatus.pending,
        destinationKey: state.destinationKey,
        backedUpHash: state.backedUpHash,
      ),
    );
    // The picture changed, so the thumbnail did: drop the cached one and
    // put the bucket's back in the queue (same key, overwritten in place).
    await thumbnailCache.remove(record);
    final thumb = record.stateOf(DerivativeKind.thumbnail);
    if (thumb.destinationKey != null) {
      await recordStore.updateDerivative(
        record.localId,
        DerivativeKind.thumbnail,
        thumb.copyWith(status: UploadStatus.pending),
      );
    }
    await _checkMotionHalf(record, enqueue: false);
    await backUpRecords([record]);
  }

  /// An edit that changed the file's extension uploads under a new name and
  /// leaves the old object behind; queue its removal. Only for a name the
  /// record held before and no longer does, in the buckets that held it.
  Future<void> _queueOrphanedKey(AssetRecord before, AssetRecord? after) async {
    final oldKey = before.stateOf(DerivativeKind.original).destinationKey;
    final newKey = after?.stateOf(DerivativeKind.original).destinationKey;
    if (oldKey == null || newKey == null || oldKey == newKey) return;
    if (before.passcodeHash != null) return;
    if (after!.stateOf(DerivativeKind.original).status !=
        UploadStatus.uploaded) {
      return;
    }
    final held = await recordStore.targetsHolding(
      before.localId,
      DerivativeKind.original,
    );
    await pendingDeletes.add([
      for (final e in held.entries)
        if (e.value == oldKey && e.value != newKey)
          PendingDelete(objectKey: e.value, targetId: e.key),
    ]);
  }

  /// A Live Photo can be edited in its motion alone, which the still's hash
  /// never shows. Compared only when a motion hash was recorded; one that
  /// wasn't is not guessed at.
  Future<void> _checkMotionHalf(
    AssetRecord record, {
    bool enqueue = true,
  }) async {
    if (!record.isLivePhoto) return;
    final state = record.stateOf(DerivativeKind.livePhoto);
    if (state.backedUpHash == null) return;
    final video = await _resolveLiveVideo(record);
    if (video == null) return;
    String hash;
    try {
      hash = await hashFile(video.path);
    } catch (_) {
      return;
    }
    if (hash == state.backedUpHash) return;
    await recordStore.updateDerivative(
      record.localId,
      DerivativeKind.livePhoto,
      state.copyWith(status: UploadStatus.pending),
    );
    if (!enqueue) return;
    await syncQueue.enqueue(
      localId: record.localId,
      kind: SyncJobKind.uploadLivePhoto,
      displayName: displayName(record),
      assetCreatedAt: record.createdAt,
    );
    unawaited(syncQueue.start());
  }

  /// The thumbnail file to upload for [record], or null when there is none
  /// to be had right now.
  ///
  /// Always uploaded, whatever the size: a cloud-only photo is drawn from
  /// the bucket's copy when the local cache is gone, so every photo needs
  /// one up there. A record whose original has already left the phone
  /// uploads its cached picture instead — what heals the ones that skipped
  /// it before.
  Future<String?> _uploadableThumbnailFor(AssetRecord record) async {
    if (record.isVideo) return thumbnailCache.ensureFor(record);
    final originalPath = await filePathFor(record);
    if (originalPath != null) {
      return thumbnailCache.ensureFor(record, originalPath);
    }
    final cached = record.thumbnailPath;
    return cached != null && await File(cached).exists() ? cached : null;
  }

  /// The `.mov` half of a Live Photo, or null when there isn't one to be
  /// had. Overridable through the same seam the viewer uses.
  Future<File?> _resolveLiveVideo(AssetRecord record) async {
    try {
      return await PhotoLibraryService.resolveLivePhotoVideo(record);
    } catch (_) {
      // No plugin, or gone from the library since.
      return null;
    }
  }

  /// [AssetRecord.sourcePath] direct for `manualFile`; for `photoManager`
  /// it's resolved on demand via `photo_manager` — may trigger an iCloud
  /// download on iOS, so can be slow the first time.
  Future<String?> filePathFor(AssetRecord record) async {
    // Cloud-only by definition — there's no local original to back up,
    // re-hash, or thumbnail, and `sourcePath` still points at the file
    // that was deleted.
    if (record.localDeleted) return null;
    final path = record.sourcePath;
    // Checked, not assumed: a job that hands the uploader a path to
    // nothing fails loudly and stays failed, which is how one moved file
    // turned into a permanent red row in the queue.
    if (path != null && File(path).existsSync()) return path;
    if (record.sourceType != AssetSourceType.photoManager) return null;
    final file = await library.fileFor(record);
    return file?.path;
  }
}
