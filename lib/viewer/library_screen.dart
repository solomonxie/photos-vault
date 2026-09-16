import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:path/path.dart' as p;

import '../l10n/app_localizations.dart';
import '../photos/library_metadata.dart';
import '../photos/ai_analysis_store.dart';
import '../photos/ai_touch_up_queue.dart';
import '../photos/demo_assets_service.dart';
import '../photos/file_hash.dart' as file_hash;
import '../photos/image_pipeline.dart';
import '../photos/manual_add.dart';
import '../photos/on_device_analysis.dart';
import '../photos/person.dart';
import '../photos/person_store.dart';
import '../photos/photo_library_change.dart';
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
import 'asset_grid_view.dart';
import 'asset_group_screen.dart';
import 'delete_confirmation.dart';
import 'demo_data_screen.dart';
import 'detail_screen.dart';
import 'favorites_screen.dart';
import 'people_screen.dart';
import 'person_avatar.dart';
import 'person_page_screen.dart';
import 'private_album_gate.dart';
import 'recently_deleted_screen.dart';
import 'search_picker_sheet.dart';
import 'smart_collection_screen.dart';
import 'zoom_page_route.dart';

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
    this.backupCoordinator,
    this.aiAnalysisStore,
    this.photoLibraryService,
    this.personStore,
    this.hashFile,
    this.thumbnailCache,
    this.syncJobStore,
    this.onDeviceAnalysis,
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

  /// Overridable for tests so they never reach the Vision platform channel.
  final OnDeviceAnalysisService? onDeviceAnalysis;

  @override
  State<LibraryScreen> createState() => LibraryScreenState();
}

class LibraryScreenState extends State<LibraryScreen>
    with WidgetsBindingObserver {
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
  late final OnDeviceAnalysisService _onDeviceAnalysis =
      widget.onDeviceAnalysis ??
      OnDeviceAnalysisService(analysisStore: _aiAnalysisStore);

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

  /// Non-null while "hold a photo to select" mode is on — the set of
  /// `localId`s the batch actions apply to.
  Set<String>? _selection;

  /// Reaches the grid's scroll anchor (see [_jumpHome]).
  final _gridKey = GlobalKey<AssetGridViewState>();

  /// Whether the search field is open. It filters the grid in place rather
  /// than pushing a results page: the results *are* the library, minus what
  /// doesn't match, and a second screen showing the same grid would be the
  /// same screen.
  bool _searching = false;
  final _searchController = TextEditingController();
  final _searchFocus = FocusNode();

  /// A camera-roll scan walks the whole library, so the resume hook must
  /// not start a second one on top of the one still running.
  bool _syncingLibrary = false;

  /// Photos is where a photo is *taken*, hearted and deleted — this app is
  /// a second window onto the same library, so every return to it has to
  /// re-read what changed while we were away. Scanning only at cold start
  /// meant un-hearting a photo over in Photos, coming back, and still
  /// finding it hearted here until the app was force-quit.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state != AppLifecycleState.resumed || !mounted) return;
    unawaited(_syncPhotoLibrary());
    unawaited(_runScheduledSyncIfDue());
  }

  /// Keeping up with Photos while the app is open costs a notification per
  /// change, not a scan: iOS says exactly which assets were added, altered
  /// or removed, and [PhotoLibraryService.applyChange] touches only those.
  /// A photo taken, hearted or deleted over there therefore lands here
  /// within a frame or two, whether the library holds two hundred photos or
  /// two hundred thousand — the full scan is only ever the backstop for
  /// what changed while nobody was listening.
  void _watchPhotoLibrary() {
    PhotoManager.addChangeCallback(_onPhotoLibraryChanged);
    // Fails without the plugin (tests, unsupported platform) — the resume
    // scan still covers everything, just not as promptly.
    unawaited(PhotoManager.startChangeNotify().catchError((_) => false));
  }

  void _onPhotoLibraryChanged(MethodCall call) {
    final change = PhotoLibraryChange.parse(call);
    if (change == null || change.isEmpty) return;
    unawaited(_applyPhotoLibraryChange(change));
  }

  Future<void> _applyPhotoLibraryChange(PhotoLibraryChange change) async {
    try {
      final result = await _photoLibraryService.applyChange(change);
      if (result.isEmpty || !mounted) return;
      if (result.added.isNotEmpty) await _backUpRecords(result.added);
      await reload();
    } catch (_) {
      // Whatever this notification carried, the next scan finds anyway.
    }
  }

  void _toggleSearch() => setState(() {
    _searching = !_searching;
    if (!_searching) {
      _searchController.clear();
      _query = '';
      _searchFocus.unfocus();
    }
  });

  /// An empty search bar that's lost focus is just something in the way, so
  /// it closes itself. A bar with something typed in it stays: it's the
  /// only thing on screen saying why the grid is missing most of the
  /// library, and the way back to all of it.
  void _onSearchFocusChanged() {
    if (_searchFocus.hasFocus || !_searching) return;
    if (_searchController.text.trim().isNotEmpty) return;
    setState(() => _searching = false);
  }

  @override
  void dispose() {
    _searchFocus.removeListener(_onSearchFocusChanged);
    _searchFocus.dispose();
    _searchController.dispose();
    PhotoManager.removeChangeCallback(_onPhotoLibraryChanged);
    WidgetsBinding.instance.removeObserver(this);
    syncQueue.draining.removeListener(_onDrainingChanged);
    AiTouchUpQueue.instance.removeListener(_onAiTouchUpChanged);
    syncQueue.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _searchFocus.addListener(_onSearchFocusChanged);
    _watchPhotoLibrary();
    syncQueue.draining.addListener(_onDrainingChanged);
    AiTouchUpQueue.instance.addListener(_onAiTouchUpChanged);
    _init();
  }

  /// A touch-up started from the detail screen finishes on its own time —
  /// pick its result up whenever it lands, even if the user has since come
  /// back here.
  void _onAiTouchUpChanged() {
    if (mounted) unawaited(reload());
  }

  /// One refresh when a drain finishes rather than one per job — a queue of
  /// hundreds shouldn't re-read the whole library hundreds of times.
  void _onDrainingChanged() {
    if (!syncQueue.draining.value) unawaited(_onQueueDrained());
  }

  /// The queue is capped, so a library bigger than it is backed up a
  /// queueful at a time: whenever one empties, refill it from whatever is
  /// still pending. Self-limiting — if the work is failing rather than
  /// landing, the failures hold their places in the queue, the refill is
  /// refused, and nothing loops.
  Future<void> _onQueueDrained() async {
    await reload();
    if (!mounted || syncQueue.paused.value) return;
    // Only ever *continues* a sync that was already running. A drain that
    // found nothing to do must not go looking for work — the sync-frequency
    // setting says when to start one, and "Manual" is a promise.
    if (syncQueue.processedInLastDrain == 0) return;
    final remaining = _pendingAndFailed;
    if (remaining.isEmpty) return;
    await _backUpRecords(remaining);
  }

  /// A fresh install opens on a genuinely empty library — the user's own
  /// photos arrive from the camera-roll scan below, and the bundled demo
  /// content only ever appears if they ask for it ("Try with Demo Photos"
  /// on the empty state, "Reset Demo Data" in Utilities). Seeding it
  /// unasked put fake photos in among real ones and made the first thing
  /// the app showed somebody else's pictures.
  Future<void> _init() async {
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
    if (_syncingLibrary) return;
    _syncingLibrary = true;
    try {
      final access = await _photoLibraryService.requestAccess();
      if (access == PhotoLibraryAccess.denied) return;
      // Pages arrive newest-first, and the first one is drawn straight
      // away: on a fresh install the most recent day is on screen while the
      // scan is still working back through the rest. Later pages are older
      // photos, which land *above* the viewport — [AssetGridView] holds its
      // place against them, so nothing under the reader's thumb moves.
      var lastDraw = DateTime.now();
      final result = await _photoLibraryService.syncAll(
        // Only with full access. Under "Selected Photos" the scan sees a
        // handful of assets and every other one would look deleted.
        reconcileDeletions: access == PhotoLibraryAccess.granted,
        onPage: (page) {
          if (page.isEmpty || !mounted) return;
          // Redrawing per page would be O(library) work per page; once a
          // second keeps the scan visibly moving without that.
          final now = DateTime.now();
          if (_all.isNotEmpty &&
              now.difference(lastDraw) < const Duration(seconds: 1)) {
            return;
          }
          lastDraw = now;
          unawaited(reload());
        },
      );
      if (result.isEmpty) return;
      if (result.added.isNotEmpty) await _backUpRecords(result.added);
      // Also redraws for a scan that only *changed* things — a heart taken
      // off a photo over in Photos adds nothing, and still has to show.
      await reload();
    } catch (_) {
      // No `photo_manager` platform channel (tests, unsupported platform)
      // or the permission flow failed — leave the camera roll unsynced
      // rather than crash; manual add/demo photos still work.
    } finally {
      _syncingLibrary = false;
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
        // Oldest first, newest at the bottom — Photos' order, and what
        // lets the page open on the latest photo (see [AssetGridView]).
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt));

  List<AssetRecord> get _filtered => _query.isEmpty
      ? _active
      : _active
            .where(
              (r) => (r.sourcePath ?? r.localId).toLowerCase().contains(
                _query.toLowerCase(),
              ),
            )
            .toList();

  /// Places and Events are both "group the library by one free-text field
  /// the user filled in" — biggest group first, so the row leads with what
  /// they actually photograph.
  Map<String, List<AssetRecord>> _groupedBy(String? Function(AssetRecord) of) {
    final groups = <String, List<AssetRecord>>{};
    for (final record in _active) {
      final key = of(record);
      if (key == null || key.isEmpty) continue;
      groups.putIfAbsent(key, () => []).add(record);
    }
    final sorted = groups.entries.toList()
      ..sort((a, b) => b.value.length.compareTo(a.value.length));
    return {for (final entry in sorted) entry.key: entry.value};
  }

  void _openGroup(String title, List<AssetRecord> records) => _push(
    AssetGroupScreen(
      title: title,
      records: records,
      assetRecordStore: assetRecordStore,
    ),
  );

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

  Future<bool> _hasBackupTarget() async {
    try {
      return (await _backupTargetsStore.loadAll()).isNotEmpty;
    } catch (_) {
      // Secure storage unavailable — skip this round rather than queue
      // work that can't land; the next sync-due check tries again.
      return false;
    }
  }

  /// Queues [records] for backup rather than uploading them here: one job
  /// per derivative per asset, drained by [syncQueue] with real concurrency.
  /// Returns how many assets were queued — not how many landed, which isn't
  /// knowable until the queue gets to them, and not how many were *asked*
  /// for: the queue is capped ([SyncQueue.capacity]) and refuses while
  /// paused, so a big library goes up a queueful at a time.
  Future<int> _backUpRecords(List<AssetRecord> records) async {
    // Nothing to upload *to* yet: queueing anyway would walk the whole
    // camera roll resolving each asset's file — on a real library that's
    // thousands of exports (and iCloud downloads) handed to a coordinator
    // with nowhere to put them. Adding a target runs `_syncEverything`,
    // which picks every pending asset up then.
    if (!await _hasBackupTarget()) return 0;
    var queued = 0;
    for (final record in records) {
      final name = _displayNameFor(record);
      final taken = await syncQueue.enqueue(
        localId: record.localId,
        kind: SyncJobKind.uploadOriginal,
        displayName: name,
      );
      // Full or paused. Stop walking the list — on a real camera roll the
      // rest is tens of thousands of records, and they're still pending on
      // their own records for the next pass to find.
      if (!taken) break;
      queued++;
      // Videos have no thumbnail pipeline yet (T2.3), so there'd be nothing
      // for the job to do.
      if (!record.isVideo) {
        await syncQueue.enqueue(
          localId: record.localId,
          kind: SyncJobKind.uploadThumbnail,
          displayName: name,
        );
      }
    }
    // Only when there's something to drain: starting an empty drain would
    // flip `draining` and bring `_onDrainingChanged` straight back here.
    if (queued > 0) unawaited(syncQueue.start());
    return queued;
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
        await _coordinator.backUpDerivative(
          record: record,
          kind: DerivativeKind.original,
          filePath: path,
        );
      case SyncJobKind.uploadThumbnail:
        final path = await _uploadableThumbnailFor(record);
        if (path == null) return;
        await _coordinator.backUpDerivative(
          record: record,
          kind: DerivativeKind.thumbnail,
          filePath: path,
        );
      case SyncJobKind.analyzePhoto:
        // Videos have no still to look at, and Vision only reads images.
        if (record.isVideo) return;
        final path = await _filePathFor(record);
        if (path == null) return;
        await _onDeviceAnalysis.analyze(record, path);
    }
  }

  /// Queues an on-device look at every photo that hasn't had one. Costs
  /// nothing but time and battery — no key, no upload, no per-photo bill —
  /// which is the only reason it can be offered over a whole library.
  Future<int> analyzeLibrary() async {
    final analyzed = await _aiAnalysisStore.listAll();
    final pending = _active
        .where((r) => !r.isVideo && !analyzed.containsKey(r.localId))
        .toList();
    var queued = 0;
    for (final record in pending) {
      if (!await syncQueue.enqueue(
        localId: record.localId,
        kind: SyncJobKind.analyzePhoto,
        displayName: _displayNameFor(record),
      )) {
        // Queue full or paused; the rest waits for the next pass.
        break;
      }
      queued++;
    }
    if (queued > 0) unawaited(syncQueue.start());
    return queued;
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
      if (!isSyncDue(
        frequency: frequency,
        lastSyncAt: lastSyncAt,
        now: DateTime.now(),
      )) {
        return;
      }
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
    // "Sync Now" means now. A paused queue takes nothing new (deliberately
    // — see [SyncQueue.enqueue]), so honouring the pause here would make
    // the button do nothing at all and say nothing about why.
    await syncQueue.setPaused(false);
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

  Future<int> _removeDemoPhotos() async {
    final removed = await _demoAssetsService.removeAll();
    await reload();
    return removed;
  }

  Future<void> _toggleFavorite(AssetRecord record) async {
    await setFavoriteEverywhere(assetRecordStore, record, !record.isFavorite);
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
    final choice = await chooseDelete(
      context,
      canRemoveFromDevice: _canRemoveFromDevice(record),
    );
    switch (choice) {
      case DeleteChoice.cancel:
        return false;
      case DeleteChoice.fromDevice:
        await _removeFromDevice(record);
        return false;
      case DeleteChoice.everywhere:
        // Deleting here deletes the photo, not just this app's note about
        // it: a camera-roll asset goes from the OS library too, into its
        // own 30-day Recently Deleted. iOS puts up its own confirmation,
        // and a decline lands here as false — which must leave the photo
        // alone in both places rather than binning it only here.
        if (record.sourceType == AssetSourceType.photoManager &&
            !record.localDeleted &&
            !await _deleteFromLibrary(record)) {
          return false;
        }
        await assetRecordStore.softDelete(record.localId);
        await reload();
        return true;
    }
  }

  /// The bucket copy is deliberately *not* touched here. This app's
  /// Recently Deleted has to be restorable to mean anything, and the
  /// backed-up copy is the one that survives a lost phone — it's purged
  /// only when the user empties that bin (see
  /// `recently_deleted_screen.dart`).
  Future<bool> _deleteFromLibrary(AssetRecord record) async {
    try {
      return await _photoLibraryService.deleteFromLibrary(record);
    } catch (_) {
      // No plugin, or the asset is already gone from the library — either
      // way there's nothing over there left to delete.
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

  /// Opens whatever the queue names, from the queue — the row says
  /// "IMG_4934.jpg is failing" and the obvious next question is which photo
  /// that is. Gone from the library since (deleted mid-sync) means there's
  /// nothing to show, so nothing happens.
  Future<void> _openById(String localId) async {
    final record = await assetRecordStore.getByLocalId(localId);
    if (record == null || !mounted) return;
    await _openRecord(record);
  }

  Future<void> _openRecord(AssetRecord record) async {
    final visible = _filtered;
    // Opened from the queue, the photo may not be in the current grid at
    // all — hidden, deleted, or filtered out by a search. Show it on its
    // own rather than dropping the tap or, worse, indexing at -1.
    final index = visible.indexOf(record);
    final records = index >= 0 ? visible : [record];
    await Navigator.of(context).push(
      ZoomPageRoute(
        builder: (_) => DetailScreen(
          records: records,
          initialIndex: index >= 0 ? index : 0,
          onDelete: _softDelete,
          onToggleFavorite: _toggleFavorite,
          assetRecordStore: assetRecordStore,
          personStore: _personStore,
        ),
      ),
    );
    // An edit in there files its result as a new library item.
    await reload();
  }

  void _startSelecting(AssetRecord record) =>
      setState(() => _selection = {record.localId});

  void _toggleSelected(AssetRecord record) => setState(() {
    final next = {..._selection!};
    next.contains(record.localId)
        ? next.remove(record.localId)
        : next.add(record.localId);
    _selection = next;
  });

  List<AssetRecord> get _selectedRecords {
    final ids = _selection ?? const <String>{};
    return _active.where((r) => ids.contains(r.localId)).toList();
  }

  /// Adds one tag to everything selected, leaving each photo's existing
  /// tags alone — batch editing is additive, never a replace.
  /// Deletes everything selected, the same way deleting one does: out of
  /// the OS photo library too, and into this app's Recently Deleted rather
  /// than straight out of existence. Confirmed once for the whole
  /// selection — a per-photo prompt for forty photos isn't a safeguard,
  /// it's a wall to click through.
  ///
  /// The count is in the confirmation because "delete 40 photos" is a
  /// different decision from "delete this photo", and the selection has
  /// probably scrolled out of sight by the time the sheet is up.
  Future<void> _batchDelete() async {
    final records = _selectedRecords;
    if (records.isEmpty) return;
    if (!await confirmDeleteSelection(context, count: records.length)) return;
    setState(() => _busy = true);
    try {
      for (final record in records) {
        if (record.sourceType == AssetSourceType.photoManager &&
            !record.localDeleted &&
            !await _deleteFromLibrary(record)) {
          // Declined at the OS prompt — leave this one alone and stop,
          // rather than asking about every remaining photo in turn.
          break;
        }
        await assetRecordStore.softDelete(record.localId);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;
    setState(() => _selection = null);
    await reload();
  }

  Future<void> _batchAddTag() async {
    final l10n = AppLocalizations.of(context)!;
    final options = await assetRecordStore.allTags();
    if (!mounted) return;
    final tag = await showSearchPickerSheet(
      context: context,
      title: l10n.selectionAddTag,
      options: options,
    );
    if (tag == null || tag.trim().isEmpty) return;
    for (final record in _selectedRecords) {
      if (record.tags.contains(tag)) continue;
      await assetRecordStore.setTags(record.localId, [...record.tags, tag]);
    }
    await reload();
  }

  Future<void> _batchSetPlace() async {
    final l10n = AppLocalizations.of(context)!;
    final options = await assetRecordStore.allLocations();
    if (!mounted) return;
    final value = await showSearchPickerSheet(
      context: context,
      title: l10n.selectionSetPlace,
      options: options,
      clearLabel: l10n.detailInfoNoLocation,
    );
    if (value == null) return;
    final place = value.trim().isEmpty ? null : value.trim();
    for (final record in _selectedRecords) {
      await assetRecordStore.setLocation(record.localId, place);
    }
    await reload();
  }

  Future<void> _batchSetEvent() async {
    final l10n = AppLocalizations.of(context)!;
    final options = await assetRecordStore.allEvents();
    if (!mounted) return;
    final value = await showSearchPickerSheet(
      context: context,
      title: l10n.selectionSetEvent,
      options: options,
      clearLabel: l10n.detailInfoNoEvent,
    );
    if (value == null) return;
    final event = value.trim().isEmpty ? null : value.trim();
    for (final record in _selectedRecords) {
      await assetRecordStore.setEvent(record.localId, event);
    }
    await reload();
  }

  /// Shifts the whole selection by however far the *earliest* photo moves,
  /// so a batch of shots keeps its internal spacing — the same thing
  /// Photos' "Adjust Date & Time" does to a multi-selection.
  Future<void> _batchAdjustDateTime() async {
    final l10n = AppLocalizations.of(context)!;
    final selected = _selectedRecords;
    if (selected.isEmpty) return;
    final anchor = selected
        .map((r) => r.createdAt)
        .reduce((a, b) => a.isBefore(b) ? a : b)
        .toLocal();
    var picked = anchor;
    final saved = await showCupertinoModalPopup<bool>(
      context: context,
      builder: (context) => CupertinoActionSheet(
        title: Text(l10n.detailEditDateTimeTitle),
        message: SizedBox(
          height: 200,
          child: CupertinoDatePicker(
            mode: CupertinoDatePickerMode.dateAndTime,
            initialDateTime: anchor,
            maximumDate: DateTime.now(),
            onDateTimeChanged: (value) => picked = value,
          ),
        ),
        actions: [
          CupertinoActionSheetAction(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.settingsSaveButton),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l10n.actionCancel),
        ),
      ),
    );
    if (saved != true) return;
    final shift = picked.difference(anchor);
    if (shift == Duration.zero) return;
    for (final record in selected) {
      await setCreatedAtEverywhere(
        assetRecordStore,
        record,
        record.createdAt.add(shift),
      );
    }
    await reload();
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
          openAsset: _openById,
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
    final selection = _selection;

    return Stack(
      children: [
        CupertinoPageScaffold(
          child: SafeArea(
            bottom: false,
            child: Stack(
              children: [
                AssetGridView(
                  key: _gridKey,
                  records: filtered,
                  onTap: selection == null ? _openRecord : _toggleSelected,
                  onLongPress: _startSelecting,
                  selectedIds: selection,
                  actionsFor: (r) => _actionsFor(l10n, r),
                  emptySliver: _all.isEmpty
                      ? SliverToBoxAdapter(
                          child: _EmptyState(
                            busy: _busy,
                            onAddDemo: _addDemoPhotos,
                            onAddFiles: addFiles,
                          ),
                        )
                      : null,
                  scrubberInsets: const EdgeInsets.only(top: 56, bottom: 16),
                  leadingSlivers: _leadingSlivers(l10n),
                  trailingSlivers: _trailingSlivers(l10n, selection),
                ),
                if (selection != null)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: _SelectionBar(
                      count: selection.length,
                      onAddTag: _batchAddTag,
                      onSetPlace: _batchSetPlace,
                      onSetEvent: _batchSetEvent,
                      onAdjustDateTime: _batchAdjustDateTime,
                      onDelete: _batchDelete,
                      onDone: () => setState(() => _selection = null),
                    ),
                  ),
              ],
            ),
          ),
        ),
        // The navigation bar sends you home wherever it's tapped, not just on
        // the title. Translucent rather than opaque, so a drag that starts on
        // the bar still reaches the scroll view and scrolls the page.
        //
        // The status bar strip above it is NOT covered here, because it can't
        // be: iOS never delivers a status-bar tap to the view. It arrives on
        // the `flutter/status_bar` channel instead and goes straight to
        // [handleStatusBarTap] — which is where this screen picks it up.
        Positioned(
          top: MediaQuery.paddingOf(context).top,
          left: 0,
          // Short of the bar's own trailing button. A translucent overlay
          // still wins the gesture arena against anything under it, so
          // covering the search button would leave it unpressable — the
          // tappable "header" is the title area, not the controls on it.
          right: _navigationBarActionWidth,
          height: _navigationBarHeight,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: _jumpHome,
          ),
        ),
        // Pinned under the navigation bar rather than scrolled with the
        // content, for the same reason it's a button: wherever you are in
        // the library, that's where you type.
        if (_searching)
          Positioned(
            top: MediaQuery.paddingOf(context).top + _navigationBarHeight,
            left: 0,
            right: 0,
            child: ColoredBox(
              color: const Color(0xFF1C1C1E),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: CupertinoSearchTextField(
                  controller: _searchController,
                  focusNode: _searchFocus,
                  autofocus: true,
                  onChanged: (v) => setState(() => _query = v),
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// `CupertinoSliverNavigationBar`'s collapsed height — the strip that
  /// stays pinned under the status bar however far the page is scrolled.
  static const _navigationBarHeight = 44.0;

  /// Kept clear at the trailing end of the bar for its own button.
  static const _navigationBarActionWidth = 72.0;

  /// The system's own status-bar tap. It never reaches the widget tree — iOS
  /// hands it to the engine, which forwards it to every
  /// [WidgetsBindingObserver] — so a `GestureDetector` laid over the status
  /// bar can't see it, however opaque. Overriding it here also takes it off
  /// [CupertinoPageScaffold], whose version scrolls the primary controller to
  /// its minimum: in a newest-first grid that's the *oldest* photo, the one
  /// place in a ten-year library nobody means to land.
  @override
  void handleStatusBarTap() => _jumpHome();

  /// Back to the newest photos — and, tapped again from there, on up to the
  /// very top. Bound to the status bar, the navigation bar and the large
  /// title: the whole header, which is what a thumb reaches for when it's
  /// lost.
  void _jumpHome() => _gridKey.currentState?.toggleAnchor();

  List<Widget> _leadingSlivers(AppLocalizations l10n) => [
    CupertinoSliverNavigationBar(
      largeTitle: GestureDetector(
        onTap: _jumpHome,
        child: Text(l10n.tabLibrary),
      ),
      // A button, not a field. A search box living at the top of the scroll
      // content is a box nobody can reach: the page opens at the *newest*
      // photo, so the field sat a decade of scrolling away. As a navigation
      // bar button it's in the same place whatever you're looking at.
      trailing: _all.isEmpty
          ? null
          : CupertinoButton(
              // A bar button is a thumb target, not a glyph: zero padding
              // around a 22pt icon is a quarter of the area a finger needs.
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: const Size(44, 44),
              onPressed: _toggleSearch,
              // "Cancel" while open, not a second ✕: the field has its own
              // clear button, and two identical crosses a centimetre apart
              // mean different things.
              child: _searching
                  ? Text(
                      l10n.actionCancel,
                      style: const TextStyle(fontSize: 15),
                    )
                  : const Icon(CupertinoIcons.search, size: 24),
            ),
    ),
    SliverToBoxAdapter(
      child: AnimatedBuilder(
        animation: AiTouchUpQueue.instance,
        builder: (context, _) => AiTouchUpQueue.instance.running.isEmpty
            ? const SizedBox.shrink()
            : Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Row(
                  children: [
                    const CupertinoActivityIndicator(radius: 8),
                    const SizedBox(width: 8),
                    Text(
                      l10n.aiTouchUpWorking,
                      style: const TextStyle(color: CupertinoColors.systemGrey),
                    ),
                  ],
                ),
              ),
      ),
    ),
  ];

  List<Widget> _trailingSlivers(
    AppLocalizations l10n,
    Set<String>? selection,
  ) => [
    if (_all.isNotEmpty) ...[
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
              separatorBuilder: (context, i) => const SizedBox(width: 12),
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
                  style: const TextStyle(color: CupertinoColors.systemGrey),
                ),
              )
            : SizedBox(
                height: 100,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: _people.length,
                  separatorBuilder: (context, i) => const SizedBox(width: 8),
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
        child: _GroupCardRow(
          groups: _groupedBy((r) => r.location),
          emptyNote: l10n.collectionsPlacesEmpty,
          icon: CupertinoIcons.map_pin_ellipse,
          onTap: _openGroup,
        ),
      ),
      SliverToBoxAdapter(
        child: _SubsectionHeader(
          title: l10n.collectionsEventsRow,
          moreLabel: l10n.collectionsAiSuggestions,
          onMore: () => _push(
            SmartCollectionScreen(
              kind: SmartCollectionKind.events,
              assetRecordStore: assetRecordStore,
              aiAnalysisStore: _aiAnalysisStore,
            ),
          ),
        ),
      ),
      SliverToBoxAdapter(
        child: _GroupCardRow(
          groups: _groupedBy((r) => r.event),
          emptyNote: l10n.collectionsEventsEmpty,
          icon: CupertinoIcons.calendar,
          onTap: _openGroup,
        ),
      ),
    ],
    SliverToBoxAdapter(child: _SectionHeader(title: l10n.collectionsUtilities)),
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
            onTap: () =>
                _push(FavoritesScreen(assetRecordStore: assetRecordStore)),
          ),
          _row(
            // Filled, like every other glyph in this list — the outline
            // silo drawn for this row read as a different icon set. An
            // archive box is what a bucket you own actually is: things put
            // away somewhere safe, rather than a cloud (which reads as
            // iCloud, the one thing this isn't).
            icon: CupertinoIcons.archivebox_fill,
            color: CupertinoColors.systemTeal,
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
            title: l10n.demoDataTitle,
            onTap: _busy
                ? null
                : () => _push(
                    DemoDataScreen(
                      onAdd: _addDemoPhotos,
                      onRemove: _removeDemoPhotos,
                    ),
                  ),
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
              RecentlyDeletedScreen(
                assetRecordStore: assetRecordStore,
                deleteBackup: _coordinator.deleteBackup,
              ),
            ),
          ),
        ],
      ),
    ),
    SliverToBoxAdapter(child: SizedBox(height: selection == null ? 24 : 140)),
  ];

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
          face: person.avatarFace,
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
  const _SubsectionHeader({required this.title, this.onMore, this.moreLabel});

  final String title;

  /// Shows a "More" chevron beside the title (People's entry point to the
  /// full `PeopleScreen`) instead of a separate trailing card in the row
  /// below.
  final VoidCallback? onMore;

  /// Overrides that chevron's "More" — Events' one opens AI-guessed
  /// groupings, which is a different thing from "more of the same".
  final String? moreLabel;

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
                    moreLabel ?? l10n.collectionsMoreButton,
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

/// The bar that replaces per-tile actions while photos are selected: the
/// count and a way out up top, the batch edits (tag, place, event, date)
/// below. Everything here is additive or a single-field set — nothing
/// destructive lives on a multi-selection.
class _SelectionBar extends StatelessWidget {
  const _SelectionBar({
    required this.count,
    required this.onAddTag,
    required this.onSetPlace,
    required this.onSetEvent,
    required this.onAdjustDateTime,
    required this.onDelete,
    required this.onDone,
  });

  final int count;
  final VoidCallback onAddTag;
  final VoidCallback onSetPlace;
  final VoidCallback onSetEvent;
  final VoidCallback onAdjustDateTime;
  final VoidCallback onDelete;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      decoration: BoxDecoration(
        color: CupertinoDynamicColor.resolve(
          CupertinoColors.systemBackground,
          context,
        ),
        border: Border(
          top: BorderSide(
            color: CupertinoDynamicColor.resolve(
              CupertinoColors.separator,
              context,
            ),
          ),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    count == 0
                        ? l10n.selectionHint
                        : l10n.selectionTitle(count),
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  CupertinoButton(
                    padding: EdgeInsets.zero,
                    onPressed: onDone,
                    child: Text(l10n.selectionDone),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _SelectionAction(
                    icon: CupertinoIcons.tag,
                    label: l10n.selectionAddTag,
                    onPressed: count == 0 ? null : onAddTag,
                  ),
                  _SelectionAction(
                    icon: CupertinoIcons.map_pin_ellipse,
                    label: l10n.selectionSetPlace,
                    onPressed: count == 0 ? null : onSetPlace,
                  ),
                  _SelectionAction(
                    icon: CupertinoIcons.calendar,
                    label: l10n.selectionSetEvent,
                    onPressed: count == 0 ? null : onSetEvent,
                  ),
                  _SelectionAction(
                    icon: CupertinoIcons.clock,
                    label: l10n.selectionAdjustDateTime,
                    onPressed: count == 0 ? null : onAdjustDateTime,
                  ),
                  _SelectionAction(
                    icon: CupertinoIcons.delete,
                    label: l10n.selectionDelete,
                    destructive: true,
                    onPressed: count == 0 ? null : onDelete,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SelectionAction extends StatelessWidget {
  const _SelectionAction({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.destructive = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool destructive;

  @override
  Widget build(BuildContext context) => CupertinoButton(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    onPressed: onPressed,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          icon,
          size: 22,
          color: destructive && onPressed != null
              ? CupertinoColors.systemRed
              : null,
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            color: destructive && onPressed != null
                ? CupertinoColors.systemRed
                : null,
          ),
        ),
      ],
    ),
  );
}

/// Places/Events: one card per distinct value the user has set, covered by
/// that group's newest photo. Same shape as an album card, since that's
/// what a place or an event is here — a live album keyed off one field.
class _GroupCardRow extends StatelessWidget {
  const _GroupCardRow({
    required this.groups,
    required this.emptyNote,
    required this.icon,
    required this.onTap,
  });

  final Map<String, List<AssetRecord>> groups;
  final String emptyNote;
  final IconData icon;
  final void Function(String title, List<AssetRecord> records) onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    if (groups.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Text(
          emptyNote,
          style: const TextStyle(color: CupertinoColors.systemGrey),
        ),
      );
    }

    final entries = groups.entries.toList();
    return SizedBox(
      height: 190,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: entries.length,
        separatorBuilder: (context, i) => const SizedBox(width: 12),
        itemBuilder: (context, i) {
          final entry = entries[i];
          final cover = entry.value.first;
          return SizedBox(
            width: 140,
            child: GestureDetector(
              onTap: () => onTap(entry.key, entry.value),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: cover.sourcePath != null && !cover.isVideo
                          ? Image.file(
                              File(cover.sourcePath!),
                              fit: BoxFit.cover,
                              width: double.infinity,
                              errorBuilder: (context, error, stackTrace) =>
                                  _GroupCardFallback(icon: icon),
                            )
                          : _GroupCardFallback(icon: icon),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(entry.key, maxLines: 1, overflow: TextOverflow.ellipsis),
                  Text(
                    l10n.collectionsGroupPhotoCount(entry.value.length),
                    style: const TextStyle(
                      color: CupertinoColors.systemGrey,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _GroupCardFallback extends StatelessWidget {
  const _GroupCardFallback({required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: CupertinoDynamicColor.resolve(CupertinoColors.systemGrey5, context),
    child: Icon(icon, color: CupertinoColors.systemGrey, size: 32),
  );
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
