import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import '../photos/on_device_vision.dart';
import '../photos/photo_library_service.dart';
import '../photos/temp_renders.dart';
import '../photos/thumbnail_cache.dart';
import '../settings/backup_targets_store.dart';
import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import 'backup_coordinator.dart';
import 'pending_deletes.dart';
import 'sync_job.dart';
import 'sync_job_store.dart';
import 'sync_queue.dart';

/// A failure worth showing to the user, in their words.
class SyncJobProblem implements Exception {
  const SyncJobProblem(this.message);
  final String message;

  @override
  String toString() => message;
}

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

  /// `analyzePhoto` jobs belong to the screen's on-device analysis, handed
  /// a [visionSourceFor] source.
  final Future<void> Function(AssetRecord record, String source)? analyze;

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

  /// Owed a thumbnail but with nothing to make one from this session.
  final thumbnailUnavailable = <String>{};

  void forgetFailures() {
    triedAndFailed.clear();
    unresolvable.clear();
  }

  /// Everything still owed an upload. Hidden photos never: they are backed
  /// up from inside their open album ([backUpHidden]), so the queue and the
  /// Cloud page never have to know they exist.
  List<AssetRecord> get pendingAndFailed => records().where((r) {
    if (!r.isVisibleInLibrary) return false;
    if (unresolvable.contains(r.localId)) return false;
    // A Live Photo whose still went up but whose `.mov` didn't is still
    // owed to the bucket — what's up there is a silent still.
    return !r.isFullyBackedUp;
  }).toList();

  /// Backed-up photos whose thumbnail never went up — the small ones the
  /// upload used to skip. Hidden ones draw from the vault cache instead.
  List<AssetRecord> get thumbnailsOwed => records()
      .where(
        (r) =>
            r.isVisibleInLibrary &&
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
  ///
  /// Lists cut from [records] are already oldest first (`listAll`'s
  /// order): those are walked backwards, no sort. One pass to tell.
  static Iterable<AssetRecord> newestFirst(List<AssetRecord> records) {
    var ascending = true;
    var descending = true;
    for (var i = 1; i < records.length && (ascending || descending); i++) {
      final c = records[i - 1].createdAt.compareTo(records[i].createdAt);
      if (c > 0) ascending = false;
      if (c < 0) descending = false;
    }
    if (descending) return records;
    if (ascending) return records.reversed;
    return records.toList()..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

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
    if (!await hasBackupTarget()) return 0;
    final work = [
      for (final r in records)
        if (r.passcodeHash == null) r,
    ];
    var queued = 0;
    var enqueuedAny = false;

    /// Queues one photo's jobs; false when the queue is full or paused.
    Future<bool> queueRecord(AssetRecord record) async {
      final name = displayName(record);
      // The thumbnail goes in *first*, and not for the bucket's sake:
      // `uploadThumbnail` is also what puts the picture this app draws
      // once the original is gone onto disk. Queued first, the job a full
      // queue turns away is the *original*, which is still pending and
      // comes back on the next pass.
      final tookThumbnail = await syncQueue.enqueue(
        localId: record.localId,
        kind: SyncJobKind.uploadThumbnail,
        displayName: name,
        assetCreatedAt: record.createdAt,
      );
      if (!tookThumbnail) return false;
      enqueuedAny = true;
      final taken = await syncQueue.enqueue(
        localId: record.localId,
        kind: SyncJobKind.uploadOriginal,
        displayName: name,
        assetCreatedAt: record.createdAt,
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
        );
      }
      // An edit found earlier and not yet up. A new one is queued by the
      // original's job, which is what finds it.
      if (_owesEdit(record)) await _enqueueEdit(record);
      return true;
    }

    // The owed thumbnails first, then the library.
    final ordered = newestFirst(work);
    var full = false;
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
    if (!full) {
      // Full or paused stops the walk — on a real camera roll the rest is
      // tens of thousands of records, still pending for the next pass.
      for (final record in ordered) {
        if (!await queueRecord(record)) break;
      }
    }
    // Only when there's something to drain: starting an empty drain would
    // flip `draining` and bring the screen's listener straight back here.
    if (enqueuedAny) unawaited(syncQueue.start());
    return queued;
  }

  /// Queues a change check per already-backed-up asset whose modification
  /// date moved since it last matched its backup (or that has never been
  /// checked). A check re-hashes that asset's local file to spot an edit —
  /// real work against a real file, so it's a queued job like any upload
  /// rather than a silent pass, and shows up in the queue by name.
  ///
  /// Gated on the date, not walked newest-first every time: that re-hashed
  /// the same newest hundred on every sync and never reached an edit to an
  /// older photo (BG-6). An edit in Photos moves the date, which a scan or
  /// the change history stamps (`noteModified`); so do favourites and
  /// metadata, which only cost a hash.
  Future<int> enqueueChangeChecks() async {
    // Before the due set: a legacy backup a scan dates from before its
    // upload needs no check at all (PW3b).
    await recordStore.rebaselineChangeChecks();
    final due = await recordStore.changeChecksDue();
    final uploaded = records().where((r) {
      // Cloud-only assets have no local file left to compare against, and
      // neither has one whose file this pass already failed to find —
      // asking again every sync is how one deleted photo becomes a
      // permanent red row.
      if (r.localDeleted) return false;
      // Hidden ones are the album's to back up, never the queue's: a row
      // here, even nameless, says on an open page that they exist.
      if (!r.isVisibleInLibrary) return false;
      if (unresolvable.contains(r.localId)) return false;
      return r.stateOf(DerivativeKind.original).status == UploadStatus.uploaded;
    }).toList();
    due.addAll(await _heldFilesMoved(uploaded, due));
    var queued = false;
    for (final record in newestFirst([
      for (final r in uploaded)
        if (due.contains(r.localId)) r,
    ])) {
      // Full or paused: the rest wait for the next pass.
      if (!await syncQueue.enqueue(
        localId: record.localId,
        kind: SyncJobKind.checkChanges,
        displayName: displayName(record),
        assetCreatedAt: record.createdAt,
      )) {
        break;
      }
      queued = true;
    }
    if (queued) unawaited(syncQueue.start());
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
    // Queued by an older build. Hidden photos go up from their album now.
    if (record.passcodeHash != null) return;
    switch (job.kind) {
      case SyncJobKind.checkChanges:
        await _checkOneForLocalChanges(record);
      case SyncJobKind.uploadOriginal:
        // Before the file: an edit after this read moves the date past it,
        // and the next change check sees that.
        final modified = await modifiedOf(record);
        final source = await _originalSourceFor(record);
        final path = source?.path;
        if (source == null || path == null) {
          // Up already: this run was only for an edit, which has its own.
          if (record.stateOf(DerivativeKind.original).status !=
              UploadStatus.uploaded) {
            unresolvable.add(record.localId);
          }
          return;
        }
        TempRenders.hold(path);
        try {
          final owesEdit =
              source.edited ||
              record.stateOf(DerivativeKind.edited).destinationKey != null;
          // Owed before the original lands: never "fully backed up" with
          // the edit still only on this phone.
          if (source.resource && owesEdit != record.hasEdit) {
            await recordStore.setHasEdit(record.localId, owesEdit);
          }
          await coordinator.backUpDerivative(
            record: record,
            kind: DerivativeKind.original,
            filePath: path,
            fromResource: source.resource,
          );
          final after = await recordStore.getByLocalId(record.localId);
          // Failed, or nothing landed: not handed back by every refill.
          if (after?.stateOf(DerivativeKind.original).status !=
              UploadStatus.uploaded) {
            triedAndFailed.add(record.localId);
          } else if (modified != null) {
            await recordStore.markChecked(record.localId, modified);
          }
        } catch (_) {
          // Thrown or recorded, a failure is a failure: remembered either
          // way, so the refill stops handing this one back to the queue.
          // Rethrown so the queue still shows the row and its reason.
          triedAndFailed.add(record.localId);
          rethrow;
        } finally {
          // The put has completed or failed for good by now: nothing of
          // background_downloader's still reads this file.
          await TempRenders.release(path, delete: true);
        }
        final now = await recordStore.getByLocalId(record.localId);
        if (now != null && _owesEdit(now)) await _enqueueEdit(now);
      case SyncJobKind.uploadEdited:
        await _uploadEdit(record);
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
        final source = await visionSourceFor(record);
        if (source == null) {
          unresolvable.add(record.localId);
          return;
        }
        await analyze?.call(record, source);
    }
  }

  /// One hidden photo, from inside its open album: an encrypted copy built
  /// and sent to every bucket. The photo itself is not touched — same file,
  /// same row, same tile — only its backup status changes. Throws a
  /// [SyncJobProblem] saying why when it can't be done.
  Future<void> backUpHidden(AssetRecord record) async {
    if (!coordinator.canUpload(record)) {
      throw const SyncJobProblem('Album is locked');
    }
    if (!await hasBackupTarget()) {
      throw const SyncJobProblem('No bucket to back up to');
    }
    final path = await filePathFor(record);
    if (path == null) {
      throw const SyncJobProblem("This photo's file isn't on this iPhone");
    }
    await coordinator.backUpDerivative(
      record: record,
      kind: DerivativeKind.original,
      filePath: path,
      keepCarrierLocally: false,
    );
    if (record.isLivePhoto) {
      final video = await _resolveLiveVideo(record);
      if (video != null) {
        await coordinator.backUpDerivative(
          record: record,
          kind: DerivativeKind.livePhoto,
          filePath: video.path,
          keepCarrierLocally: false,
        );
      }
    }
    final after = await recordStore.getByLocalId(record.localId);
    if (after == null || after.isFullyBackedUp) return;
    // Pending: nothing was sent, so the encrypted copy was never made.
    // Failed: it was, and the bucket turned it down.
    throw SyncJobProblem(
      after.stateOf(DerivativeKind.original).status == UploadStatus.pending
          ? "Couldn't make its encrypted copy"
          : "The bucket didn't accept the upload",
    );
  }

  /// Re-hashes one asset's local file and, if it's been edited since its
  /// last successful backup, flips it back to pending and queues the
  /// re-upload straight away rather than waiting for the next sync.
  ///
  /// Read live first: a date still the one it was checked at needs no file
  /// at all — the scan's stamp was stale, or only the queue thought so.
  Future<void> _checkOneForLocalChanges(AssetRecord record) async {
    final modified = await modifiedOf(record);
    if (modified != null &&
        modified == await recordStore.checkedModified(record.localId)) {
      await recordStore.markChecked(record.localId, modified);
      return;
    }
    final original = record.stateOf(DerivativeKind.original);
    final resources = _readsResources(record);
    // A JPEG render's hash, from before PW3b: current if the photo was last
    // modified before it went up. Settled without reading anything.
    if (resources &&
        !original.fromResource &&
        modified != null &&
        await recordStore.backupPredates(record.localId, modified)) {
      await recordStore.markChecked(record.localId, modified);
      return;
    }
    // Like with like: a render against a render's hash, PhotoKit's bytes
    // against theirs. Never one against the other, which is every photo
    // looking edited.
    final path = resources && original.fromResource
        ? (await library.currentResourceFor(record))?.path
        : await filePathFor(record);
    TempRenders.hold(path);
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
    } finally {
      await TempRenders.release(path, delete: true);
    }
    final state = original;
    final edit = record.stateOf(DerivativeKind.edited);
    final held = record.sourcePath != null;
    final expected = {
      if (resources && original.fromResource)
        record.hasEdit ? edit.backedUpHash : state.backedUpHash
      else ...[
        state.backedUpHash,
        // A file here may be the edit, brought back from the bucket.
        if (held && record.hasEdit) edit.backedUpHash,
      ],
    };
    if (expected.contains(hash)) {
      await _checkMotionHalf(record);
      if (modified != null) {
        await recordStore.markChecked(record.localId, modified);
      }
      return;
    }
    if (record.hasEdit) {
      await recordStore.updateDerivative(
        record.localId,
        DerivativeKind.edited,
        edit.copyWith(status: UploadStatus.pending),
      );
    }
    // The original of an edited photo comes from PhotoKit's base resource
    // alone; a file here that changed is a new look, sent as the edit.
    if (!(held && record.hasEdit)) {
      await recordStore.updateDerivative(
        record.localId,
        DerivativeKind.original,
        state.copyWith(status: UploadStatus.pending),
      );
    }
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
    await backUpRecords([
      (await recordStore.getByLocalId(record.localId)) ?? record,
    ]);
  }

  /// A camera-roll still, read as PhotoKit's own bytes rather than a
  /// full-size JPEG render (BG-2). Video already reads its original;
  /// held, hidden and manual photos read their file.
  static bool _readsResources(AssetRecord r) =>
      r.sourceType == AssetSourceType.photoManager &&
      r.sourcePath == null &&
      r.passcodeHash == null &&
      !r.isVideo &&
      !r.localDeleted;

  /// What the original goes up as: PhotoKit's unedited original for a
  /// camera-roll still ([resource]), [filePathFor] for the rest. Null path
  /// when there's none to be had; never a render or a held file for an
  /// edited photo's original, whose bytes only PhotoKit has.
  Future<({String? path, bool resource, bool edited})?> _originalSourceFor(
    AssetRecord record,
  ) async {
    if (_readsResources(record)) {
      final found = await library.originalResourceFor(record);
      if (found == null) return null;
      return (path: found.path, resource: true, edited: found.edited);
    }
    if (record.hasEdit && record.passcodeHash == null) return null;
    return (path: await filePathFor(record), resource: false, edited: false);
  }

  static bool _owesEdit(AssetRecord r) =>
      r.hasEdit &&
      r.passcodeHash == null &&
      r.stateOf(DerivativeKind.edited).status != UploadStatus.uploaded;

  Future<void> _enqueueEdit(AssetRecord record) async {
    if (!await syncQueue.enqueue(
      localId: record.localId,
      kind: SyncJobKind.uploadEdited,
      displayName: displayName(record),
      assetCreatedAt: record.createdAt,
    )) {
      return;
    }
    unawaited(syncQueue.start());
  }

  /// The edit's own job: PhotoKit's current render of the photo, or the
  /// file here for one brought back from the bucket. A photo whose edit was
  /// reverted before any of it went up owes nothing; one already up keeps
  /// being sent its current look.
  Future<void> _uploadEdit(AssetRecord record) async {
    if (!_owesEdit(record)) return;
    String? path;
    if (_readsResources(record)) {
      final found = await library.currentResourceFor(record);
      if (found == null) return;
      if (!found.edited &&
          record.stateOf(DerivativeKind.edited).destinationKey == null) {
        await recordStore.setHasEdit(record.localId, false);
        return;
      }
      path = found.path;
    } else {
      path = await filePathFor(record);
    }
    if (path == null) return;
    TempRenders.hold(path);
    try {
      await coordinator.backUpDerivative(
        record: record,
        kind: DerivativeKind.edited,
        filePath: path,
      );
    } finally {
      await TempRenders.release(path, delete: true);
    }
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
    if (!record.localDeleted) {
      final made = await cacheThumbnail(record);
      if (made != null) return made;
    }
    final cached = record.thumbnailPath;
    return cached != null && await File(cached).exists() ? cached : null;
  }

  /// [record]'s cached thumbnail, made if it has none: PhotoKit's own for a
  /// camera-roll photo (BG-4), the file decoded only when there is no
  /// library picture to be had. Null when neither is.
  Future<String?> cacheThumbnail(AssetRecord record) async {
    String? render;
    try {
      return await thumbnailCache.ensureFor(
        record,
        null,
        () async => render = await _heldPathFor(record),
      );
    } finally {
      await TempRenders.release(render, delete: true);
    }
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

  /// [filePathFor], held so the tmp sweep leaves it alone. Every caller
  /// releases it (`TempRenders.release`) once done.
  Future<String?> _heldPathFor(AssetRecord record) async {
    final path = await filePathFor(record);
    TempRenders.hold(path);
    return path;
  }

  /// The modification date (seconds) of what [filePathFor] reads: the
  /// file's own for one held here, PhotoKit's for a camera-roll asset.
  /// Null when there's no answer, which always means "hash it".
  Future<int?> modifiedOf(AssetRecord record) async {
    if (record.localDeleted) return null;
    final path = record.sourcePath;
    if (path != null) {
      try {
        // Knowingly sync, as [filePathFor]: one stat per job, bounded by
        // the queue's concurrency.
        final stat = File(path).statSync();
        if (stat.type != FileSystemEntityType.notFound) {
          return stat.modified.millisecondsSinceEpoch ~/ 1000;
        }
      } catch (_) {
        return null;
      }
    }
    if (record.sourceType != AssetSourceType.photoManager) return null;
    return library.modifiedSecondsOf(record);
  }

  /// Backed-up held files whose date isn't the one they were checked at.
  /// No scan stamps those, so they're stat'ed here: in one isolate, since
  /// there can be thousands.
  Future<Set<String>> _heldFilesMoved(
    List<AssetRecord> uploaded,
    Set<String> due,
  ) async {
    final baselines = await recordStore.fileCheckBaselines();
    final paths = <String, String>{
      for (final r in uploaded)
        if (r.sourcePath case final path?
            when !due.contains(r.localId) && baselines.containsKey(r.localId))
          r.localId: path,
    };
    if (paths.isEmpty) return const {};
    final dates = await Isolate.run(
      () => {
        for (final MapEntry(key: id, value: path) in paths.entries)
          id: () {
            try {
              final stat = File(path).statSync();
              return stat.type == FileSystemEntityType.notFound
                  ? null
                  : stat.modified.millisecondsSinceEpoch ~/ 1000;
            } catch (_) {
              return null;
            }
          }(),
      },
    );
    return {
      for (final MapEntry(key: id, value: at) in dates.entries)
        // Gone is the camera roll's answer, not a moved date.
        if (at != null && at != baselines[id]) id,
    };
  }

  /// What Vision reads for [record]: the camera-roll asset itself, rendered
  /// natively at the size Vision uses (BG-10), or the file for anything
  /// with no PhotoKit asset (a held or hidden photo, a manual add).
  Future<String?> visionSourceFor(AssetRecord record) async {
    if (record.localDeleted) return null;
    final id = record.libraryId;
    if (record.sourcePath == null &&
        record.passcodeHash == null &&
        record.sourceType == AssetSourceType.photoManager &&
        id != null) {
      return OnDeviceVisionService.assetSource(id);
    }
    return filePathFor(record);
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
    // Knowingly sync: one stat per job, bounded by the queue's concurrency.
    if (path != null && File(path).existsSync()) return path;
    if (record.sourceType != AssetSourceType.photoManager) return null;
    final file = await library.fileFor(record);
    return file?.path;
  }
}
