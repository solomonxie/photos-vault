import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:path/path.dart' as p;

import '../l10n/app_localizations.dart';
import '../photos/ai_analysis_store.dart';
import '../photos/demo_assets_service.dart';
import '../photos/demo_seed_store.dart';
import '../photos/file_hash.dart' as file_hash;
import '../photos/image_pipeline.dart';
import '../photos/manual_add.dart';
import '../photos/person.dart';
import '../photos/person_store.dart';
import '../photos/photo_library_service.dart';
import '../photos/thumbnail_cache.dart';
import '../settings/ai_settings_screen.dart';
import '../settings/backup_targets_store.dart';
import '../settings/settings_screen.dart';
import '../storage/album.dart';
import '../storage/album_store.dart';
import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import '../upload/backup_coordinator.dart';
import '../upload/sync_job.dart';
import '../upload/sync_job_store.dart';
import '../upload/sync_queue.dart';
import 'album_screen.dart';
import 'asset_grid.dart';
import 'coming_soon_screen.dart';
import 'delete_confirmation.dart';
import 'detail_screen.dart';
import 'favorites_screen.dart';
import 'media_type_screen.dart';
import 'people_screen.dart';
import 'person_avatar.dart';
import 'person_page_screen.dart';
import 'private_album_gate.dart';
import 'recently_deleted_screen.dart';
import 'smart_collection_screen.dart';

/// The whole app, one page — matches real Photos: no separate "Library" vs
/// "Collections" tabs, just a day-grouped grid up top and Media
/// Types/Utilities sections below (Favorites/Hidden/Recently Deleted are
/// real; Cloud Backups/AI Settings are this app's own).
/// Lists manually-added/demo files, not a real camera-roll grid (T4.1 still
/// needs `photo_manager`, T2.1).
class LibraryScreen extends StatefulWidget {
  const LibraryScreen({
    super.key,
    this.assetRecordStore,
    this.backupTargetsStore,
    this.albumStore,
    this.manualAddService,
    this.demoAssetsService,
    this.demoSeedStore,
    this.backupCoordinator,
    this.aiAnalysisStore,
    this.photoLibraryService,
    this.personStore,
    this.hashFile,
    this.thumbnailCache,
    this.syncJobStore,
  });

  final AssetRecordStore? assetRecordStore;
  final BackupTargetsStore? backupTargetsStore;
  final AlbumStore? albumStore;

  /// Overridable for tests so People never opens the real `sqflite` factory.
  final PersonStore? personStore;

  /// Overridable for tests so the People/Events smart collections never open
  /// the real (platform-backed) `sqflite` factory.
  final AiAnalysisStore? aiAnalysisStore;

  /// Overridable for tests so they never touch the real `photo_manager`
  /// platform channel.
  final PhotoLibraryService? photoLibraryService;

  /// Overridable for tests so they never open the real file picker.
  final ManualAddService? manualAddService;

  /// Overridable for tests so they never touch the real asset bundle / disk.
  final DemoAssetsService? demoAssetsService;

  /// Overridable for tests so they never touch real secure storage.
  final DemoSeedStore? demoSeedStore;

  /// Overridable for tests so they never construct a real `S3Uploader`
  /// (which touches the `background_downloader` platform channel).
  final BackupCoordinator? backupCoordinator;

  /// Backs [LibraryScreenState._checkForLocalChanges]'s re-hash. Overridable
  /// for tests so they never touch the real filesystem.
  final Future<String> Function(String path)? hashFile;

  /// Overridable for tests so they never decode/write real image files.
  final ThumbnailCache? thumbnailCache;

  /// Overridable for tests so they never open the real queue database.
  final SyncJobStore? syncJobStore;

  @override
  State<LibraryScreen> createState() => LibraryScreenState();
}

class LibraryScreenState extends State<LibraryScreen> {
  late final AssetRecordStore assetRecordStore =
      widget.assetRecordStore ?? AssetRecordStore();
  late final BackupTargetsStore _backupTargetsStore =
      widget.backupTargetsStore ?? BackupTargetsStore();
  late final AlbumStore _albumStore = widget.albumStore ?? AlbumStore();
  late final ManualAddService _manualAddService =
      widget.manualAddService ?? ManualAddService(store: assetRecordStore);
  late final PersonStore _personStore = widget.personStore ?? PersonStore();
  late final DemoAssetsService _demoAssetsService =
      widget.demoAssetsService ??
      DemoAssetsService(
        manualAddService: _manualAddService,
        albumStore: _albumStore,
        personStore: _personStore,
      );
  late final DemoSeedStore _demoSeedStore =
      widget.demoSeedStore ?? DemoSeedStore();
  late final BackupCoordinator _coordinator =
      widget.backupCoordinator ??
      BackupCoordinator(
        targetsStore: _backupTargetsStore,
        recordStore: assetRecordStore,
      );
  late final AiAnalysisStore _aiAnalysisStore =
      widget.aiAnalysisStore ?? AiAnalysisStore();
  late final PhotoLibraryService _photoLibraryService =
      widget.photoLibraryService ??
      PhotoLibraryService(store: assetRecordStore);
  late final Future<String> Function(String path) _hashFile =
      widget.hashFile ?? file_hash.hashFile;
  late final ThumbnailCache _thumbnailCache =
      widget.thumbnailCache ?? ThumbnailCache(store: assetRecordStore);
  late final SyncJobStore _syncJobStore = widget.syncJobStore ?? SyncJobStore();

  /// The one queue every unit of sync work goes through. Public so the
  /// Private Cloud screen can show and control it.
  late final SyncQueue syncQueue = SyncQueue(
    store: _syncJobStore,
    settings: _backupTargetsStore,
    process: _processJob,
  );

  List<AssetRecord> _all = const [];
  List<Album> _albums = const [];
  Map<String, List<AssetRecord>> _albumAssets = const {};
  List<Person> _people = const [];
  Map<String, int> _personPhotoCounts = const {};
  String _query = '';
  bool _busy = false;

  @override
  void dispose() {
    syncQueue.draining.removeListener(_onDrainingChanged);
    syncQueue.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    syncQueue.draining.addListener(_onDrainingChanged);
    _init();
  }

  /// One refresh when a drain finishes rather than one per job — a queue of
  /// hundreds shouldn't re-read the whole library hundreds of times.
  void _onDrainingChanged() {
    if (!syncQueue.draining.value) unawaited(reload());
  }

  /// A fresh install seeds the bundled demo photos automatically — no
  /// "Try with Demo Photos" tap required — but only once ever: after that,
  /// deleting them stays deleted until the user explicitly resets via
  /// Utilities' "Reset Demo Data". Also backs them up right away (silently,
  /// no result dialog) to any already-configured S3 target, same as a
  /// manual add — otherwise they'd sit as "pending" forever despite the
  /// files already existing in a bucket configured before this launch.
  Future<void> _init() async {
    try {
      if (!await _demoSeedStore.hasSeeded()) {
        final added = await _demoAssetsService.addAll();
        await _demoSeedStore.markSeeded();
        await _backUpRecords(added);
      }
    } catch (_) {
      // Secure storage unavailable/unreadable — skip auto-seeding rather
      // than risk doing it on every launch; "Reset Demo Data" in Utilities
      // still works.
    }
    await reload();
    // Picks up whatever a previous run left queued — including jobs left
    // `running` by a kill mid-sync — and starts draining.
    unawaited(syncQueue.resume());
    // Fire-and-forget: a full camera-roll scan (and any iCloud downloads it
    // triggers for backup) can be slow, and must never block showing the
    // manual/demo assets already on hand. Re-`reload()`s itself once done.
    unawaited(_syncPhotoLibrary());
    // Independent of camera-roll access: retries whatever's already
    // pending/failed if the configured sync frequency says it's due — the
    // other natural "app came to the foreground" moment, alongside
    // returning to this screen from Cloud Backups (see `_openCloudBackups`).
    unawaited(_runScheduledSyncIfDue());
  }

  /// Pulls in the real camera roll (T2.1) — permission prompt on first run,
  /// silent on every launch after. Backs up anything newly seen the same
  /// way a manual add is, so granting access alone starts a backup.
  Future<void> _syncPhotoLibrary() async {
    try {
      final access = await _photoLibraryService.requestAccess();
      if (access == PhotoLibraryAccess.denied) return;
      final added = await _photoLibraryService.syncAll();
      if (added.isEmpty) return;
      await _backUpRecords(added);
      await reload();
    } catch (_) {
      // No `photo_manager` platform channel (tests, unsupported platform)
      // or the permission flow failed — leave the camera roll unsynced
      // rather than crash; manual add/demo photos still work.
    }
  }

  Future<void> reload() async {
    final all = await assetRecordStore.listAll();
    final albums = await _albumStore.listAll();
    final albumAssets = <String, List<AssetRecord>>{};
    for (final album in albums) {
      final memberIds = (await _albumStore.localIdsIn(album.id)).toSet();
      albumAssets[album.id] = all
          .where(
            (r) =>
                !r.isDeleted &&
                !r.isHidden &&
                r.passcodeHash == null &&
                memberIds.contains(r.localId),
          )
          .toList();
    }
    final people = await _personStore.listAll();
    final personPhotoCounts = <String, int>{};
    for (final person in people) {
      personPhotoCounts[person.id] = (await _personStore.localIdsIn(person.id))
          .length;
    }
    if (!mounted) return;
    setState(() {
      _all = all;
      _albums = albums;
      _albumAssets = albumAssets;
      _people = people;
      _personPhotoCounts = personPhotoCounts;
    });
  }

  List<AssetRecord> get _active =>
      _all
          .where((r) => !r.isDeleted && !r.isHidden && r.passcodeHash == null)
          .toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

  List<AssetRecord> get _filtered => _query.isEmpty
      ? _active
      : _active
            .where(
              (r) => (r.sourcePath ?? r.localId).toLowerCase().contains(
                _query.toLowerCase(),
              ),
            )
            .toList();

  int get _photoCount => _active.where((r) => !r.isVideo).length;
  int get _videoCount => _active.where((r) => r.isVideo).length;
  int get _favoriteCount =>
      _all.where((r) => r.isFavorite && !r.isDeleted).length;
  int get _hiddenCount => _all.where((r) => r.isHidden && !r.isDeleted).length;
  int get _deletedCount => _all.where((r) => r.isDeleted).length;

  List<AssetRecord> get _pendingAndFailed => _all.where((r) {
    if (r.isDeleted) return false;
    final status = r.stateOf(DerivativeKind.original).status;
    return status == UploadStatus.pending || status == UploadStatus.failed;
  }).toList();

  /// Everything the queue shows per row — the filename where there is one.
  String _displayNameFor(AssetRecord record) {
    final path = record.sourcePath;
    return path == null ? record.localId : p.basename(path);
  }

  /// Queues [records] for backup rather than uploading them here: one job
  /// per derivative per asset, drained by [syncQueue] with real concurrency.
  /// Returns how many assets were queued — not how many landed, which isn't
  /// knowable until the queue gets to them.
  Future<int> _backUpRecords(List<AssetRecord> records) async {
    for (final record in records) {
      final name = _displayNameFor(record);
      await syncQueue.enqueue(localId: record.localId, kind: SyncJobKind.uploadOriginal, displayName: name);
      // Videos have no thumbnail pipeline yet (T2.3), so there'd be nothing
      // for the job to do.
      if (!record.isVideo) {
        await syncQueue.enqueue(localId: record.localId, kind: SyncJobKind.uploadThumbnail, displayName: name);
      }
    }
    unawaited(syncQueue.start());
    return records.length;
  }

  /// The queue worker. One job is one asset and one kind of work, so a
  /// stalled file blocks only itself, and "what is it doing" is always
  /// answerable from the queue list.
  Future<void> _processJob(SyncJob job) async {
    final record = await assetRecordStore.getByLocalId(job.localId);
    // Deleted out from under the queue — nothing left to do, and not worth
    // reporting as a failure.
    if (record == null) return;
    switch (job.kind) {
      case SyncJobKind.checkChanges:
        await _checkOneForLocalChanges(record);
      case SyncJobKind.uploadOriginal:
        final path = await _filePathFor(record);
        if (path == null) return;
        await _coordinator.backUpDerivative(record: record, kind: DerivativeKind.original, filePath: path);
      case SyncJobKind.uploadThumbnail:
        final path = await _uploadableThumbnailFor(record);
        if (path == null) return;
        await _coordinator.backUpDerivative(record: record, kind: DerivativeKind.thumbnail, filePath: path);
    }
  }

  /// Re-hashes one asset's local file and, if it's been edited since its
  /// last successful backup, flips it back to pending and queues the
  /// re-upload straight away rather than waiting for the next sync.
  Future<void> _checkOneForLocalChanges(AssetRecord record) async {
    final path = await _filePathFor(record);
    if (path == null) return;
    final hash = await _hashFile(path);
    final state = record.stateOf(DerivativeKind.original);
    if (hash == state.backedUpHash) return;
    await assetRecordStore.updateDerivative(
      record.localId,
      DerivativeKind.original,
      DerivativeState(
        status: UploadStatus.pending,
        destinationKey: state.destinationKey,
        backedUpHash: state.backedUpHash,
      ),
    );
    await _backUpRecords([record]);
  }

  /// The thumbnail file to upload for [record], or null to skip it.
  ///
  /// Every photo still gets a local cache copy either way — that's what the
  /// grid draws once [AssetRecord.localDeleted] takes the original away.
  /// What's skipped is the *upload*: a photo already at or under
  /// [thumbnailSizeThresholdBytes] doesn't warrant a second, near-identical
  /// object in the bucket next to its `originals/` copy, so its `thumbnail`
  /// derivative just stays `pending` — nothing was uploaded, and that's
  /// exactly what it says. Videos have no thumbnail pipeline yet (T2.3).
  Future<String?> _uploadableThumbnailFor(AssetRecord record) async {
    if (record.isVideo) return null;
    final originalPath = await _filePathFor(record);
    if (originalPath == null) return null;
    final thumbnail = await _thumbnailCache.ensureFor(record, originalPath);
    if (thumbnail == null) return null;
    try {
      final size = await File(originalPath).length();
      return size > thumbnailSizeThresholdBytes ? thumbnail : null;
    } catch (_) {
      return null;
    }
  }

  /// Queues [records] and stamps [BackupTargetsStore.setLastSyncAt] so the
  /// sync-frequency due-check has an accurate baseline.
  Future<int> _retryRecords(List<AssetRecord> records) async {
    final count = await _backUpRecords(records);
    try {
      await _backupTargetsStore.setLastSyncAt(DateTime.now());
    } catch (_) {
      // Secure storage unavailable — the next due-check just runs again
      // sooner than strictly necessary.
    }
    await reload();
    return count;
  }

  /// Opportunistic, foreground-only: there's no real iOS background-task
  /// hookup (`BGTaskScheduler`) yet, so a configured frequency only
  /// actually fires the next time the app (or this screen) is in the
  /// foreground, not while backgrounded/closed.
  Future<void> _runScheduledSyncIfDue() async {
    try {
      final frequency = await _backupTargetsStore.getSyncFrequency();
      final lastSyncAt = await _backupTargetsStore.getLastSyncAt();
      if (!isSyncDue(frequency: frequency, lastSyncAt: lastSyncAt, now: DateTime.now())) return;
      await _syncEverything();
    } catch (_) {
      // Secure storage unavailable — skip this check, try again next
      // foreground moment.
    }
  }

  /// Queues a change check per already-backed-up asset. Each one re-hashes
  /// that asset's local file to spot an edit since its last backup — real
  /// work against a real file, so it's a queued job like any upload rather
  /// than a silent pass, and shows up in the queue by name.
  Future<int> _enqueueChangeChecks() async {
    final uploaded = _all.where((r) {
      // Cloud-only assets have no local file left to compare against.
      if (r.isDeleted || r.localDeleted) return false;
      return r.stateOf(DerivativeKind.original).status == UploadStatus.uploaded;
    }).toList();
    for (final record in uploaded) {
      await syncQueue.enqueue(
        localId: record.localId,
        kind: SyncJobKind.checkChanges,
        displayName: _displayNameFor(record),
      );
    }
    return uploaded.length;
  }

  /// The one entry point "Sync Now" and the scheduled due-check both go
  /// through. Queues the work and returns — nothing is uploaded on this
  /// call stack; [syncQueue] drains it. Returns how many jobs are now
  /// outstanding.
  Future<int> _syncEverything() async {
    await _enqueueChangeChecks();
    await _backUpRecords(_pendingAndFailed);
    try {
      await _backupTargetsStore.setLastSyncAt(DateTime.now());
    } catch (_) {
      // Secure storage unavailable — the next due-check just runs again
      // sooner than strictly necessary.
    }
    unawaited(syncQueue.start());
    return syncQueue.jobs.value.where((job) => !job.isFinished).length;
  }

  /// [AssetRecord.sourcePath] direct for `manualFile`; for `photoManager`
  /// it's resolved on demand via `photo_manager` — may trigger an iCloud
  /// download on iOS, so can be slow the first time.
  Future<String?> _filePathFor(AssetRecord record) async {
    // Cloud-only by definition — there's no local original to back up,
    // re-hash, or thumbnail, and `sourcePath` still points at the file
    // that was deleted.
    if (record.localDeleted) return null;
    final path = record.sourcePath;
    if (path != null) return path;
    if (record.sourceType != AssetSourceType.photoManager) return null;
    final file = await _photoLibraryService.fileFor(record);
    return file?.path;
  }

  /// Backs up [records] (whatever this action just added) plus anything
  /// else still pending/failed from before — e.g. "Try with Demo Photos"
  /// tapped again is a no-op add for content already present (deduped by
  /// hash), so on its own it would never retry those same demo photos if
  /// they were still sitting pending from before a bucket was configured.
  Future<void> _backUpAndReport(List<AssetRecord> records) async {
    final toBackUp = {for (final r in records) r.localId: r};
    for (final r in _pendingAndFailed) {
      toBackUp.putIfAbsent(r.localId, () => r);
    }
    final succeeded = await _backUpRecords(toBackUp.values.toList());
    await reload();
    if (!mounted) return;
    final l10n = AppLocalizations.of(context)!;
    _showResult(l10n.libraryAddFilesResult(records.length, succeeded));
  }

  void _showResult(String message) {
    showCupertinoDialog<void>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        content: Text(message),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(AppLocalizations.of(context)!.actionCancel),
          ),
        ],
      ),
    );
  }

  Future<void> _runBusy(Future<List<AssetRecord>> Function() pick) async {
    setState(() => _busy = true);
    try {
      final records = await pick();
      await _backUpAndReport(records);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> addFiles() => _runBusy(_manualAddService.pickAndEnqueue);

  /// Also doubles as Utilities' "Reset Demo Data": re-adds any bundled demo
  /// photos/videos missing from the Library (e.g. deleted there) and backs
  /// them up — a no-op add for ones already present, keyed by content hash.
  Future<void> _addDemoPhotos() => _runBusy(_demoAssetsService.addAll);

  Future<void> _toggleFavorite(AssetRecord record) async {
    await assetRecordStore.setFavorite(record.localId, !record.isFavorite);
    await reload();
  }

  Future<void> _hide(AssetRecord record) async {
    await hideIntoPrivateAlbum(
      context,
      assetRecordStore: assetRecordStore,
      record: record,
    );
    await reload();
  }

  /// Offered only for a photo that's actually backed up and still has its
  /// local original: otherwise "remove from device" would either lose the
  /// only copy, or have nothing left to remove. Videos are out until they
  /// have a thumbnail pipeline of their own (T2.3) — there'd be nothing to
  /// draw in the grid afterwards.
  bool _canRemoveFromDevice(AssetRecord record) =>
      !record.localDeleted &&
      !record.isVideo &&
      record.stateOf(DerivativeKind.original).status == UploadStatus.uploaded;

  /// Returns whether the asset left the library — false for a
  /// remove-from-device, which deliberately keeps it there (cloud-only), so
  /// the detail viewer stays open on it rather than popping.
  Future<bool> _softDelete(AssetRecord record) async {
    final choice = await chooseDelete(context, canRemoveFromDevice: _canRemoveFromDevice(record));
    switch (choice) {
      case DeleteChoice.cancel:
        return false;
      case DeleteChoice.fromDevice:
        await _removeFromDevice(record);
        return false;
      case DeleteChoice.everywhere:
        await assetRecordStore.softDelete(record.localId);
        await reload();
        return true;
    }
  }

  /// Frees the device storage but keeps the asset in the library: cache a
  /// thumbnail first (that's what the grid will draw from now on), then
  /// drop the full-resolution local copy — from the OS photo library for a
  /// camera-roll asset, since this app never held its own copy of one.
  Future<void> _removeFromDevice(AssetRecord record) async {
    final l10n = AppLocalizations.of(context)!;
    setState(() => _busy = true);
    try {
      final path = await _filePathFor(record);
      if (path == null) return;
      final thumbnail = await _thumbnailCache.ensureFor(record, path);
      if (thumbnail == null) {
        if (mounted) _showResult(l10n.libraryDeleteFromDeviceFailed);
        return;
      }
      if (record.sourceType == AssetSourceType.photoManager) {
        // iOS puts up its own confirmation; a decline lands here as false
        // and must not leave the record claiming to be cloud-only.
        if (!await _photoLibraryService.deleteFromLibrary(record)) return;
      } else {
        await File(path).delete();
      }
      await assetRecordStore.setLocalDeleted(record.localId, true);
      await reload();
    } catch (_) {
      if (mounted) _showResult(l10n.libraryDeleteFromDeviceFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  List<TileAction> _actionsFor(AppLocalizations l10n, AssetRecord record) => [
    TileAction(
      icon: record.isFavorite
          ? CupertinoIcons.heart_slash
          : CupertinoIcons.heart,
      label: record.isFavorite ? l10n.libraryUnfavorite : l10n.libraryFavorite,
      onPressed: () => _toggleFavorite(record),
    ),
    TileAction(
      icon: CupertinoIcons.eye_slash,
      label: l10n.libraryHide,
      onPressed: () => _hide(record),
    ),
    TileAction(
      icon: CupertinoIcons.delete,
      label: l10n.libraryDeleteTooltip,
      isDestructive: true,
      onPressed: () => _softDelete(record),
    ),
  ];

  void _openRecord(AssetRecord record) {
    final records = _filtered;
    Navigator.of(context).push(
      CupertinoPageRoute(
        builder: (_) => DetailScreen(
          records: records,
          initialIndex: records.indexOf(record),
          onDelete: _softDelete,
          onToggleFavorite: _toggleFavorite,
          assetRecordStore: assetRecordStore,
          personStore: _personStore,
        ),
      ),
    );
  }

  Future<void> _push(Widget screen) async {
    await Navigator.of(context)
        .push(CupertinoPageRoute(builder: (_) => screen));
    await reload();
  }

  Future<void> _openPrivateAlbums() async {
    await openPrivateAlbums(context, assetRecordStore: assetRecordStore);
    await reload();
  }

  /// Unlike a plain [_push], always syncs on return — regardless of the
  /// configured sync frequency — since coming back from Cloud Backups
  /// usually means a target/setting just changed and shouldn't need a
  /// separate manual sync to take effect.
  Future<void> _openCloudBackups() async {
    await Navigator.of(context).push(
      CupertinoPageRoute(
        builder: (_) => SettingsScreen(
          store: _backupTargetsStore,
          assetRecordStore: assetRecordStore,
          retryRecords: _retryRecords,
          syncEverything: _syncEverything,
          syncQueue: syncQueue,
        ),
      ),
    );
    await _syncEverything();
  }

  void _openAlbum(Album album) => _push(
    AlbumScreen(
      album: album,
      assetRecordStore: assetRecordStore,
      albumStore: _albumStore,
    ),
  );

  void _openPerson(Person person) => _push(
    PersonPageScreen(
      person: person,
      personStore: _personStore,
      assetRecordStore: assetRecordStore,
    ),
  );

  void _openPeopleScreen() => _push(
    PeopleScreen(
      personStore: _personStore,
      assetRecordStore: assetRecordStore,
      aiAnalysisStore: _aiAnalysisStore,
    ),
  );

  Future<void> _confirmDeleteAlbum(Album album) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showCupertinoDialog<bool>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: Text(l10n.albumDeleteConfirmTitle),
        content: Text(l10n.albumDeleteConfirmBody),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.actionCancel),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.albumDeleteAction),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _albumStore.remove(album.id);
    await reload();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final filtered = _filtered;

    return CupertinoPageScaffold(
      child: SafeArea(
        bottom: false,
        child: CustomScrollView(
          slivers: [
            CupertinoSliverNavigationBar(largeTitle: Text(l10n.tabLibrary)),
            if (_all.isNotEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: CupertinoSearchTextField(
                    onChanged: (v) => setState(() => _query = v),
                  ),
                ),
              ),
            if (_all.isEmpty)
              SliverToBoxAdapter(
                child: _EmptyState(
                  busy: _busy,
                  onAddDemo: _addDemoPhotos,
                  onAddFiles: addFiles,
                ),
              )
            else ...[
              ...assetGridSlivers(
                context: context,
                records: filtered,
                onTap: _openRecord,
                actionsFor: (r) => _actionsFor(l10n, r),
              ),
              SliverToBoxAdapter(
                child: _SectionHeader(title: l10n.collectionsCollections),
              ),
              if (_albums.isNotEmpty) ...[
                SliverToBoxAdapter(
                  child: _SubsectionHeader(title: l10n.collectionsAlbums),
                ),
                SliverToBoxAdapter(
                  child: SizedBox(
                    height: 190,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: _albums.length,
                      separatorBuilder: (context, i) =>
                          const SizedBox(width: 12),
                      itemBuilder: (context, i) => SizedBox(
                        width: 140,
                        child: _AlbumCard(
                          album: _albums[i],
                          records: _albumAssets[_albums[i].id] ?? const [],
                          onTap: () => _openAlbum(_albums[i]),
                          onDelete: () => _confirmDeleteAlbum(_albums[i]),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
              SliverToBoxAdapter(
                child: _SubsectionHeader(
                  title: l10n.collectionsPeopleRow,
                  onMore: _openPeopleScreen,
                ),
              ),
              SliverToBoxAdapter(
                child: _people.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Text(
                          l10n.peopleEmpty,
                          style: const TextStyle(
                            color: CupertinoColors.systemGrey,
                          ),
                        ),
                      )
                    : SizedBox(
                        height: 100,
                        child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          itemCount: _people.length,
                          separatorBuilder: (context, i) =>
                              const SizedBox(width: 8),
                          itemBuilder: (context, i) {
                            final person = _people[i];
                            return SizedBox(
                              width: 64,
                              child: _PersonCard(
                                person: person,
                                assetRecordStore: assetRecordStore,
                                photoCount: _personPhotoCounts[person.id] ?? 0,
                                onTap: () => _openPerson(person),
                              ),
                            );
                          },
                        ),
                      ),
              ),
              SliverToBoxAdapter(
                child: _SubsectionHeader(title: l10n.collectionsPlacesRow),
              ),
              SliverToBoxAdapter(
                child: _PlaceholderCollectionRow(
                  icon: CupertinoIcons.map_pin_ellipse,
                  color: CupertinoColors.systemTeal,
                  onTap: () => _push(
                    ComingSoonScreen(
                      title: l10n.collectionsPlacesRow,
                      body: l10n.collectionsPlacesComingSoonBody,
                      icon: CupertinoIcons.map_pin_ellipse,
                    ),
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: _SubsectionHeader(title: l10n.collectionsEventsRow),
              ),
              SliverToBoxAdapter(
                child: _PlaceholderCollectionRow(
                  icon: CupertinoIcons.calendar,
                  color: CupertinoColors.systemOrange,
                  label: l10n.smartCollectionsCardLabel,
                  onTap: () => _push(
                    SmartCollectionScreen(
                      kind: SmartCollectionKind.events,
                      assetRecordStore: assetRecordStore,
                      aiAnalysisStore: _aiAnalysisStore,
                    ),
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: _SectionHeader(title: l10n.collectionsMediaTypes),
              ),
              SliverToBoxAdapter(
                child: CupertinoListSection.insetGrouped(
                  margin: const EdgeInsets.symmetric(horizontal: 16),
                  // Un-overridden, this defaults to systemGroupedBackground
                  // (pure black in dark mode) — a harsher black than the
                  // page's own charcoal, visible as a seam around the card.
                  backgroundColor: const Color(0xFF1C1C1E),
                  decoration: const BoxDecoration(
                    color: Color(0xFF2C2C2E),
                    borderRadius: BorderRadius.all(Radius.circular(10)),
                  ),
                  children: [
                    _row(
                      icon: CupertinoIcons.photo,
                      color: CupertinoColors.systemGreen,
                      title: l10n.collectionsPhotosRow,
                      count: _photoCount,
                      onTap: () => _push(
                        MediaTypeScreen(
                          assetRecordStore: assetRecordStore,
                          isVideo: false,
                          title: l10n.collectionsPhotosRow,
                        ),
                      ),
                    ),
                    _row(
                      icon: CupertinoIcons.video_camera_solid,
                      color: CupertinoColors.systemPurple,
                      title: l10n.collectionsVideosRow,
                      count: _videoCount,
                      onTap: () => _push(
                        MediaTypeScreen(
                          assetRecordStore: assetRecordStore,
                          isVideo: true,
                          title: l10n.collectionsVideosRow,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            SliverToBoxAdapter(
              child: _SectionHeader(title: l10n.collectionsUtilities),
            ),
            SliverToBoxAdapter(
              child: CupertinoListSection.insetGrouped(
                margin: const EdgeInsets.symmetric(horizontal: 16),
                backgroundColor: const Color(0xFF1C1C1E),
                decoration: const BoxDecoration(
                  color: Color(0xFF2C2C2E),
                  borderRadius: BorderRadius.all(Radius.circular(10)),
                ),
                children: [
                  _row(
                    icon: CupertinoIcons.heart_fill,
                    color: CupertinoColors.systemRed,
                    title: l10n.collectionsFavoritesRow,
                    count: _favoriteCount,
                    onTap: () => _push(
                      FavoritesScreen(assetRecordStore: assetRecordStore),
                    ),
                  ),
                  _row(
                    icon: CupertinoIcons.gear_alt_fill,
                    color: CupertinoColors.systemGrey2,
                    title: l10n.collectionsPrivateCloudRow,
                    onTap: _openCloudBackups,
                  ),
                  _row(
                    icon: CupertinoIcons.sparkles,
                    color: CupertinoColors.systemIndigo,
                    title: l10n.collectionsAiSettingsRow,
                    onTap: () => _push(const AiSettingsScreen()),
                  ),
                  _row(
                    icon: CupertinoIcons.arrow_2_circlepath,
                    color: CupertinoColors.systemGreen,
                    title: l10n.settingsResetDemoButton,
                    onTap: _busy ? null : _addDemoPhotos,
                  ),
                  _row(
                    icon: CupertinoIcons.square_arrow_up,
                    color: CupertinoColors.systemIndigo,
                    title: l10n.collectionsImportPhotosRow,
                    onTap: _busy ? null : addFiles,
                  ),
                  _row(
                    icon: CupertinoIcons.eye_slash_fill,
                    color: CupertinoColors.systemGrey,
                    title: l10n.collectionsHiddenRow,
                    count: _hiddenCount,
                    onTap: _openPrivateAlbums,
                  ),
                  _row(
                    icon: CupertinoIcons.trash_fill,
                    color: CupertinoColors.systemRed,
                    title: l10n.collectionsRecentlyDeletedRow,
                    count: _deletedCount,
                    onTap: () => _push(
                      RecentlyDeletedScreen(assetRecordStore: assetRecordStore),
                    ),
                  ),
                ],
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 24)),
          ],
        ),
      ),
    );
  }

  CupertinoListTile _row({
    required IconData icon,
    required Color color,
    required String title,
    int? count,
    VoidCallback? onTap,
  }) {
    return CupertinoListTile(
      leading: Container(
        width: 29,
        height: 29,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(7),
        ),
        child: Icon(icon, color: CupertinoColors.white, size: 17),
      ),
      title: Text(title),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (count != null)
            Text(
              '$count',
              style: const TextStyle(color: CupertinoColors.systemGrey),
            ),
          const SizedBox(width: 4),
          const Icon(
            CupertinoIcons.chevron_forward,
            size: 18,
            color: CupertinoColors.systemGrey2,
          ),
        ],
      ),
      onTap: onTap,
    );
  }
}

class _AlbumCard extends StatelessWidget {
  const _AlbumCard({
    required this.album,
    required this.records,
    required this.onTap,
    required this.onDelete,
  });

  final Album album;
  final List<AssetRecord> records;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  void _showActions(BuildContext context, AppLocalizations l10n) {
    showCupertinoModalPopup<void>(
      context: context,
      builder: (context) => CupertinoActionSheet(
        title: Text(album.name),
        actions: [
          CupertinoActionSheetAction(
            isDestructiveAction: true,
            onPressed: () {
              Navigator.of(context).pop();
              onDelete();
            },
            child: Text(l10n.albumDeleteAction),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.actionCancel),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cover = records.isEmpty ? null : records.first.sourcePath;
    final coverIsVideo = records.isNotEmpty && records.first.isVideo;

    return GestureDetector(
      onTap: onTap,
      onLongPress: () => _showActions(context, l10n),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: coverIsVideo
                  ? const ColoredBox(
                      color: CupertinoColors.darkBackgroundGray,
                      child: Icon(
                        CupertinoIcons.play_circle_fill,
                        color: CupertinoColors.white,
                        size: 28,
                      ),
                    )
                  : cover != null
                  ? Image.file(
                      File(cover),
                      fit: BoxFit.cover,
                      width: double.infinity,
                      errorBuilder: (context, error, stackTrace) =>
                          const ColoredBox(
                            color: CupertinoColors.systemGrey5,
                            child: Icon(CupertinoIcons.photo),
                          ),
                    )
                  : const ColoredBox(
                      color: CupertinoColors.systemGrey5,
                      child: Icon(CupertinoIcons.photo_on_rectangle),
                    ),
            ),
          ),
          const SizedBox(height: 6),
          Text(album.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          Text(
            '${records.length}',
            style: const TextStyle(
              color: CupertinoColors.systemGrey,
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }
}

/// One Collections' "People" card — a round avatar (Photos-style, unlike
/// Albums' square covers) + name + tagged-photo count, opening that
/// person's page directly. Small and grid-packed (2 rows) rather than
/// one big card per person, since a name+count needs far less width than an
/// album cover.
class _PersonCard extends StatelessWidget {
  const _PersonCard({
    required this.person,
    required this.assetRecordStore,
    required this.photoCount,
    required this.onTap,
  });

  final Person person;
  final AssetRecordStore assetRecordStore;
  final int photoCount;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        PersonAvatar(
          assetRecordStore: assetRecordStore,
          localId: person.avatarLocalId,
          size: 56,
        ),
        const SizedBox(height: 4),
        Text(
          person.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 12),
        ),
        Text(
          '$photoCount',
          style: const TextStyle(
            color: CupertinoColors.systemGrey,
            fontSize: 11,
          ),
        ),
      ],
    ),
  );
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 32, 16, 8),
      child: Text(
        title,
        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 22),
      ),
    );
  }
}

class _SubsectionHeader extends StatelessWidget {
  const _SubsectionHeader({required this.title, this.onMore});

  final String title;

  /// Shows a "More" chevron beside the title (People's entry point to the
  /// full `PeopleScreen`) instead of a separate trailing card in the row
  /// below.
  final VoidCallback? onMore;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            title,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 17),
          ),
          if (onMore != null)
            CupertinoButton(
              padding: EdgeInsets.zero,
              onPressed: onMore,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    l10n.collectionsMoreButton,
                    style: const TextStyle(color: CupertinoColors.systemGrey),
                  ),
                  const Icon(
                    CupertinoIcons.chevron_forward,
                    size: 16,
                    color: CupertinoColors.systemGrey,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// A single-line, horizontally-scrolling row of album-card-shaped
/// placeholders — People/Places/Events have no real data to group by yet
/// (see IMPLEMENTATION_PLAN.md T4.4), but still look like a populated
/// Collections subsection rather than a bare row. Every card opens the same
/// "coming soon" screen.
class _PlaceholderCollectionRow extends StatelessWidget {
  const _PlaceholderCollectionRow({
    required this.icon,
    required this.color,
    required this.onTap,
    this.label,
  });

  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  /// Card caption — defaults to "Coming Soon"; People/Events pass their own
  /// since they open a real (opt-in AI analysis) screen, not a stub.
  final String? label;

  static const _cardCount = 4;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return SizedBox(
      height: 150,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: _cardCount,
        separatorBuilder: (context, i) => const SizedBox(width: 12),
        itemBuilder: (context, i) => GestureDetector(
          onTap: onTap,
          child: SizedBox(
            width: 110,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    // Flat neutral card, same as an album with no cover yet
                    // — a translucent tint over a dark page reads as a muddy
                    // smear rather than a clean pastel. `systemGrey5` must be
                    // resolved explicitly: as a bare Color (not routed
                    // through a Cupertino-aware widget) it otherwise paints
                    // its light-mode value even in dark mode.
                    child: ColoredBox(
                      color: CupertinoDynamicColor.resolve(
                        CupertinoColors.systemGrey5,
                        context,
                      ),
                      child: Icon(icon, color: color, size: 32),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  label ?? l10n.collectionsComingSoonTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: CupertinoColors.systemGrey,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.busy,
    required this.onAddDemo,
    required this.onAddFiles,
  });

  final bool busy;
  final VoidCallback onAddDemo;
  final VoidCallback onAddFiles;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              CupertinoIcons.photo_on_rectangle,
              size: 56,
              color: CupertinoColors.systemGrey,
            ),
            const SizedBox(height: 12),
            Text(
              l10n.libraryEmptyTitle,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(
              l10n.libraryEmptyNote,
              textAlign: TextAlign.center,
              style: const TextStyle(color: CupertinoColors.systemGrey),
            ),
            const SizedBox(height: 20),
            CupertinoButton.filled(
              onPressed: busy ? null : onAddDemo,
              child: Text(l10n.libraryAddDemoButton),
            ),
            CupertinoButton(
              onPressed: busy ? null : onAddFiles,
              child: Text(l10n.libraryAddFilesButton),
            ),
          ],
        ),
      ),
    );
  }
}
