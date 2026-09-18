import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart' show HitTestResult;
import 'package:flutter/rendering.dart' show RenderMetaData;
import 'package:flutter/services.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;

import '../l10n/app_localizations.dart';
import '../photos/library_metadata.dart';
import '../photos/ai_analysis_store.dart';
import '../photos/ai_vision_service.dart';
import '../photos/analyze_queue.dart';
import '../photos/ai_touch_up_queue.dart';
import '../photos/demo_assets_service.dart';
import '../photos/file_hash.dart' as file_hash;
import '../photos/image_pipeline.dart';
import '../photos/manual_add.dart';
import '../photos/on_device_analysis.dart';
import '../photos/person.dart';
import '../photos/person_store.dart';
import '../photos/photo_library_change.dart';
import '../backup/app_snapshot.dart';
import '../backup/bucket_backup.dart';
import '../backup/icloud_backup.dart';
import '../photos/library_custody.dart';
import '../photos/photo_library_service.dart';
import '../photos/photo_location.dart';
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
import 'analyze_queue_screen.dart';
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
    this.photoLocationService,
    this.libraryCustody,
    this.icloudBackup,
    this.bucketBackup,
    this.backgroundPassInterval,
    this.personStore,
    this.hashFile,
    this.thumbnailCache,
    this.syncJobStore,
    this.onDeviceAnalysis,
    this.aiVisionService,
    this.analyzeQueue,
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

  /// Overridable for tests so they never call the real OS geocoder.
  final PhotoLocationService? photoLocationService;

  /// Overridable for tests so hiding never deletes from a real photo
  /// library.
  final LibraryCustody? libraryCustody;

  /// Overridable for tests so a fresh library never reaches for a real
  /// iCloud container.
  final ICloudBackup? icloudBackup;

  /// Overridable for tests so a fresh library never reaches for a real
  /// bucket.
  final BucketBackup? bucketBackup;

  /// How often the background pass looks for work — backups still owed,
  /// then the camera roll, then the on-device face pass. Null switches it
  /// off, which is the default: a periodic timer is something a caller
  /// opts into, and a widget test that never asked for one would otherwise
  /// wait for it forever.
  final Duration? backgroundPassInterval;

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

  /// The paid half of the analyze pass. Overridable for tests so they
  /// never make a vendor call.
  final AiVisionService? aiVisionService;

  /// Overridable for tests, which would otherwise have a background pass
  /// walking a fake library while the test is trying to assert on it.
  final AnalyzeQueue? analyzeQueue;

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
  late final PhotoLocationService _photoLocationService =
      widget.photoLocationService ?? PhotoLocationService();
  late final LibraryCustody _custody =
      widget.libraryCustody ?? LibraryCustody(store: assetRecordStore);
  late final ICloudBackup _icloudBackup =
      widget.icloudBackup ??
      ICloudBackup(
        settings: assetRecordStore,
        snapshots: AppSnapshotIo(
          assetRecordStore: assetRecordStore,
          albumStore: _albumStore,
          personStore: _personStore,
        ),
      );
  late final BucketBackup _bucketBackup =
      widget.bucketBackup ??
      BucketBackup(
        settings: assetRecordStore,
        targetsStore: _backupTargetsStore,
        snapshots: AppSnapshotIo(
          assetRecordStore: assetRecordStore,
          albumStore: _albumStore,
          personStore: _personStore,
        ),
      );
  late final Future<String> Function(String path) _hashFile =
      widget.hashFile ?? file_hash.hashFile;
  late final ThumbnailCache _thumbnailCache =
      widget.thumbnailCache ?? ThumbnailCache(store: assetRecordStore);
  late final SyncJobStore _syncJobStore = widget.syncJobStore ?? SyncJobStore();
  late final OnDeviceAnalysisService _onDeviceAnalysis =
      widget.onDeviceAnalysis ??
      OnDeviceAnalysisService(analysisStore: _aiAnalysisStore);

  /// The one queue every unit of sync work goes through. Public so the
  /// Cloud Settings screen can show and control it.
  late final SyncQueue syncQueue = SyncQueue(
    store: _syncJobStore,
    settings: _backupTargetsStore,
    process: _processJob,
  );

  /// The other queue: reading the camera roll and looking at what's in it.
  /// Separate from [syncQueue] because it answers a different question —
  /// "what does the app know about my photos?" rather than "are they safe?"
  /// — and because it is allowed to take all week.
  late final AnalyzeQueue _analyzeQueue =
      widget.analyzeQueue ??
      AnalyzeQueue(
        assetRecordStore: assetRecordStore,
        analysisStore: _aiAnalysisStore,
        onDeviceAnalysis: _onDeviceAnalysis,
        aiVision: widget.aiVisionService ?? AiVisionService(),
        scanLibrary: _syncPhotoLibrary,
        resolvePath: _filePathFor,
        displayNameFor: _displayNameFor,
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
    // Going away is when the day's work is done and nothing is mid-edit —
    // the right moment to write the copy, and the one moment that costs the
    // user nothing. (Once a day: the file is named for the day, so a second
    // write replaces the first rather than piling up.)
    if (state == AppLifecycleState.paused) {
      unawaited(_icloudBackup.backUpIfEnabled());
      unawaited(_bucketBackup.backUpIfEnabled());
      return;
    }
    if (state != AppLifecycleState.resumed || !mounted) return;
    // The camera roll goes through the analyze queue like everything else
    // it reads — one scan job at the head of the pass, rather than a
    // second unpaced loop nobody can see or stop.
    unawaited(_analyzeQueue.startIfDue(rescan: true));
    unawaited(_runScheduledSyncIfDue());
    _startTrickle();
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
    _trickle?.cancel();
    _missingDebounce?.cancel();
    syncQueue.draining.removeListener(_onDrainingChanged);
    _analyzeQueue.remaining.removeListener(_onReviewCountChanged);
    AiTouchUpQueue.instance.removeListener(_onAiTouchUpChanged);
    syncQueue.dispose();
    if (widget.analyzeQueue == null) _analyzeQueue.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _searchFocus.addListener(_onSearchFocusChanged);
    _watchPhotoLibrary();
    syncQueue.draining.addListener(_onDrainingChanged);
    _analyzeQueue.remaining.addListener(_onReviewCountChanged);
    AiTouchUpQueue.instance.addListener(_onAiTouchUpChanged);
    _init();
  }

  /// The Utilities badge counts what's left to look at, and that number
  /// moves while the pass runs rather than when anyone asks.
  void _onReviewCountChanged() {
    if (mounted) setState(() {});
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
    final remaining = _refillable;
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
    // Before anything else writes, and before the camera-roll scan starts
    // inserting records the snapshot also has: a fresh install pulls its
    // own work back from iCloud, once, without asking. There's nothing to
    // overwrite and no context yet for a "restore from backup?" question.
    await _restoreAppData();
    await reload();
    // Picks up whatever a previous run left queued — including jobs left
    // `running` by a kill mid-sync — and starts draining.
    unawaited(syncQueue.resume());
    // Fire-and-forget: a full camera-roll scan (and any iCloud downloads it
    // triggers for backup) can be slow, and must never block showing the
    // manual/demo assets already on hand. Re-`reload()`s itself once done.
    unawaited(_analyzeQueue.startIfDue(rescan: true));
    // Independent of camera-roll access: retries whatever's already
    // pending/failed if the configured sync frequency says it's due — the
    // other natural "app came to the foreground" moment, alongside
    // returning to this screen from Cloud Backups (see `_openCloudBackups`).
    unawaited(_runScheduledSyncIfDue());
  }

  /// Whichever destination still has the snapshot. iCloud first because
  /// it needs no credentials to be readable; the bucket is asked only if
  /// that came back with nothing, and each guards itself against running
  /// over a library that isn't empty.
  Future<void> _restoreAppData() async {
    try {
      if (await _icloudBackup.restoreIfFreshInstall() > 0) return;
      await _bucketBackup.restoreIfFreshInstall();
    } catch (_) {
      // No container, no channel, no bucket, nothing in any of them — an
      // empty library is the same empty library it would have been.
    }
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
      // A re-read of the library is the one event that can put a missing
      // file back — an asset restored from Photos' own trash, a container
      // path healed. Everything given up on gets another chance.
      _unresolvable.clear();
      // Names the places the scan collected coordinates for. Runs after
      // the pages are in and on its own time (see
      // `PhotoLocationService.spacing`), so Places fills itself in from
      // photos nobody has opened yet — which is most of them.
      unawaited(_namePlaces());
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

  /// The background pass: whatever the library still owes, a little at a
  /// time, for as long as the app is open.
  ///
  /// Three kinds of work, in the order of what's lost if it never happens:
  /// photos not yet in the bucket, the camera roll not yet re-read, and
  /// faces not yet looked for. Each round tops the queue up to what's free
  /// rather than enqueuing a library's worth — the queue is capped, and a
  /// list nobody can review or cancel isn't a queue, it's a log.
  ///
  /// Deliberately slow. This runs while somebody is using the app, on a
  /// phone they're holding: a pause between rounds is the difference
  /// between a library that quietly catches up and one that's hot to the
  /// touch with a flat battery.
  Timer? _trickle;

  void _startTrickle() {
    final interval = widget.backgroundPassInterval;
    if (interval == null) return;
    _trickle?.cancel();
    _trickle = Timer.periodic(interval, (_) => unawaited(_trickleRound()));
  }

  Future<void> _trickleRound() async {
    if (!mounted || _busy || syncQueue.paused.value) return;
    if (syncQueue.draining.value) return;
    final pending = _pendingAndFailed;
    if (pending.isNotEmpty) {
      await _backUpRecords(pending);
      return;
    }
    // Nothing owed to the bucket: hand the idle time to the other queue,
    // which re-reads the camera roll and looks at what it finds. Neither
    // costs a penny — no key, no upload, no per-photo bill — which is what
    // makes them fair game for a background loop at all, and both are its
    // business rather than this one's.
    await _analyzeQueue.startIfDue();
  }

  /// Photos this app still has a record of and the library doesn't.
  ///
  /// Batched: a screenful of tiles all discovering the same thing at once
  /// would otherwise reconcile (and redraw the library) a dozen times in a
  /// frame.
  final _missingLibraryIds = <String>{};
  Timer? _missingDebounce;

  /// A tile found its photo gone from the library. That's news — the next
  /// full scan is the backstop, not the mechanism, and until it runs the
  /// grid is showing an empty square where a photo used to be.
  void _onAssetMissing(AssetRecord record) {
    final libraryId = PhotoLibraryService.libraryIdOf(record);
    if (libraryId == null || !_missingLibraryIds.add(libraryId)) return;
    _missingDebounce?.cancel();
    _missingDebounce = Timer(
      const Duration(milliseconds: 400),
      () => unawaited(_reconcileMissing()),
    );
  }

  Future<void> _reconcileMissing() async {
    final ids = {..._missingLibraryIds};
    _missingLibraryIds.clear();
    if (ids.isEmpty || !mounted) return;
    try {
      // The same path an iOS deletion notification takes: backed up becomes
      // cloud-only, not backed up goes to this app's Recently Deleted.
      // Never a row deleted — see `PhotoLibraryService._reconcileDeletions`.
      final result = await _photoLibraryService.applyChange(
        PhotoLibraryChange(deleted: ids),
      );
      if (result.isEmpty || !mounted) return;
      await reload();
    } catch (_) {
      // No plugin, no permission — the scan will get to it.
    }
  }

  Future<void> _namePlaces() async {
    try {
      final named = await _photoLocationService.fillMissing(assetRecordStore);
      if (named > 0 && mounted) await reload();
    } catch (_) {
      // No geocoder (tests, no network, throttled) — the photos keep their
      // coordinates and get their names on a later run.
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
  /// Grouped by one free-text field, biggest group first — the place you
  /// have five hundred photos of is the one you mean.
  ///
  /// [byRecency] ranks by the newest photo in each group instead, which is
  /// what an event wants: "Nina's Wedding" is interesting for a month and
  /// then it isn't, however many photos it holds.
  Map<String, List<AssetRecord>> _groupedBy(
    String? Function(AssetRecord) of, {
    bool byRecency = false,
  }) {
    final groups = <String, List<AssetRecord>>{};
    for (final record in _active) {
      final key = of(record);
      if (key == null || key.isEmpty) continue;
      groups.putIfAbsent(key, () => []).add(record);
    }
    final sorted = groups.entries.toList()
      ..sort(
        byRecency
            ? (a, b) => _newest(b.value).compareTo(_newest(a.value))
            : (a, b) => b.value.length.compareTo(a.value.length),
      );
    return {for (final entry in sorted) entry.key: entry.value};
  }

  static DateTime _newest(List<AssetRecord> records) =>
      records.map((r) => r.createdAt).reduce((a, b) => a.isAfter(b) ? a : b);

  void _openGroup(String title, List<AssetRecord> records) => _push(
    AssetGroupScreen(
      title: title,
      records: records,
      assetRecordStore: assetRecordStore,
    ),
  );

  int get _favoriteCount =>
      _all.where((r) => r.isFavorite && !r.isDeleted).length;

  /// What the analyze pass still has to get through — see the Analyze
  /// Queue row.
  int get _toAnalyzeCount => _analyzeQueue.remaining.value;

  int get _hiddenCount => _all.where((r) => r.isHidden && !r.isDeleted).length;
  int get _deletedCount => _all.where((r) => r.isDeleted).length;

  /// What the automatic refill is allowed to pick up: everything owed,
  /// minus what has already been tried and didn't work.
  ///
  /// Without the subtraction a photo that can't upload — a bucket refusing
  /// it, a file that isn't there — is queued, fails, is queued again by the
  /// drain that follows, and so on for as long as the app is open. The
  /// queue looks busy, nothing lands, and the battery goes. Retrying those
  /// is what Sync Now is for: a person deciding to try again, having seen
  /// the failure.
  List<AssetRecord> get _refillable => _pendingAndFailed
      .where((r) => !_triedAndFailed.contains(r.localId))
      .toList();

  /// Uploads that failed since the app opened. Cleared by an explicit sync,
  /// so "try again" still means try again.
  final _triedAndFailed = <String>{};

  /// Everything given up on gets another go — this is somebody deciding to
  /// retry, which is the whole point of the button.
  void _forgetFailures() {
    _triedAndFailed.clear();
    _unresolvable.clear();
  }

  /// Photos whose file couldn't be found this session. Kept so the refill
  /// stops offering them: a record still marked pending, whose file can't
  /// be resolved, is picked up by every refill, dropped by every worker,
  /// and picked up again — a loop that never uploads anything and never
  /// ends. Cleared whenever the camera roll is re-read, so a photo that
  /// comes back gets another go.
  final _unresolvable = <String>{};

  /// Everything still owed an upload — including hidden photos, which need
  /// it most: the app took them out of Photos, so the bucket is the only
  /// other copy there is.
  List<AssetRecord> get _pendingAndFailed => _all.where((r) {
    if (r.isDeleted || _unresolvable.contains(r.localId)) return false;
    final status = r.stateOf(DerivativeKind.original).status;
    return status == UploadStatus.pending || status == UploadStatus.failed;
  }).toList();

  /// Everything the queue shows per row — the filename where there is one.
  ///
  /// Except for a hidden photo, which shows no name at all. Hidden ones do
  /// still get backed up, and have to: this app holds the only copy of
  /// them, so leaving them out of the bucket would make the hidden album
  /// the least safe place in the library. But the queue is a list anyone
  /// can read over your shoulder without a passcode, and a filename there
  /// is the photo. So the work is visible and the subject isn't.
  String _displayNameFor(AssetRecord record) {
    final l10n = AppLocalizations.of(context)!;
    if (record.passcodeHash != null || record.isHidden) {
      return l10n.backupQueueHiddenItem;
    }
    final path = record.sourcePath;
    if (path != null) return p.basename(path);
    // A camera-roll photo has no filename this app can see, and the row
    // used to print the library's raw identifier —
    // "photo:E5599B0A-9341-43CB-…", which identifies nothing to a reader.
    // When it was taken does.
    return DateFormat.yMMMd().add_jm().format(record.createdAt);
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
        if (path == null) {
          _unresolvable.add(record.localId);
          return;
        }
        try {
          await _coordinator.backUpDerivative(
            record: record,
            kind: DerivativeKind.original,
            filePath: path,
          );
          final after = await assetRecordStore.getByLocalId(record.localId);
          if (after?.stateOf(DerivativeKind.original).status ==
              UploadStatus.failed) {
            _triedAndFailed.add(record.localId);
          }
        } catch (_) {
          // Thrown or recorded, a failure is a failure: remembered either
          // way, so the refill stops handing this one back to the queue.
          // Rethrown so the queue still shows the row and its reason.
          _triedAndFailed.add(record.localId);
          rethrow;
        }
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
        if (path == null) {
          _unresolvable.add(record.localId);
          return;
        }
        await _onDeviceAnalysis.analyze(record, path);
    }
  }

  /// Re-hashes one asset's local file and, if it's been edited since its
  /// last successful backup, flips it back to pending and queues the
  /// re-upload straight away rather than waiting for the next sync.
  Future<void> _checkOneForLocalChanges(AssetRecord record) async {
    final path = await _filePathFor(record);
    if (path == null) {
      _unresolvable.add(record.localId);
      return;
    }
    final String hash;
    try {
      hash = await _hashFile(path);
    } catch (_) {
      // The file went between the check and the read — deleted in Photos
      // mid-pass, most likely. "Is this photo different from the copy in
      // the bucket?" has no answer when there's no photo to compare, and
      // that is not a failure worth a red row in the queue: the backup
      // that's already up there is still good.
      _unresolvable.add(record.localId);
      return;
    }
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
      // Cloud-only assets have no local file left to compare against, and
      // neither has one whose file this pass already failed to find —
      // asking again every sync is how one deleted photo becomes a
      // permanent red row.
      if (r.isDeleted || r.localDeleted) return false;
      if (_unresolvable.contains(r.localId)) return false;
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
    _forgetFailures();
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
    // Checked, not assumed: a job that hands the uploader a path to
    // nothing fails loudly and stays failed, which is how one moved file
    // turned into a permanent red row in the queue.
    if (path != null && File(path).existsSync()) return path;
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

  /// Hiding takes the photo out of Photos as well — otherwise "hidden"
  /// would only mean hidden from this app, and the camera roll would still
  /// open on it. The copy into this app's own storage happens first, so
  /// there's never a moment where the only copy is the one being deleted.
  Future<void> _hide(AssetRecord record) async {
    setState(() => _busy = true);
    try {
      await hideIntoPrivateAlbum(
        context,
        assetRecordStore: assetRecordStore,
        records: [record],
        custody: _custody,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
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
      icon: CupertinoIcons.rectangle_stack_badge_plus,
      label: l10n.albumAddToAction,
      onPressed: () => _addToAlbum([record]),
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
    // A hidden photo's row says only that work is happening. Opening it
    // from there would walk straight past the passcode.
    if (record.passcodeHash != null || record.isHidden) return;
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
          albumStore: _albumStore,
        ),
      ),
    );
    // An edit in there files its result as a new library item.
    await reload();
  }

  void _startSelecting(AssetRecord record) {
    setState(() => _selection = {record.localId});
    // The finger is still down. Whatever it sweeps over next joins the
    // selection rather than being dropped on the floor — see
    // [_onSelectDragUpdate].
    _dragSelecting = true;
    _dragSelects = true;
    _dragSeen = {record.localId};
  }

  /// A hold-then-sweep, or a sideways drag once selecting, is one gesture:
  /// every tile it passes over gets the same treatment, and which treatment
  /// that is was decided by the first one — sweeping off a selected photo
  /// deselects, which is what makes a sweep undoable by sweeping back.
  bool _dragSelecting = false;
  bool _dragSelects = true;
  Set<String> _dragSeen = const {};

  void _onSelectDragUpdate(Offset globalPosition) {
    final selection = _selection;
    if (selection == null) return;
    final record = _recordUnder(globalPosition);
    if (record == null) return;
    if (!_dragSelecting) {
      // A sideways drag that started on a tile: its state decides whether
      // this sweep is selecting or deselecting.
      _dragSelecting = true;
      _dragSelects = !selection.contains(record.localId);
      _dragSeen = {};
    }
    if (!_dragSeen.add(record.localId)) return;
    final next = {...selection};
    if (_dragSelects) {
      next.add(record.localId);
    } else {
      next.remove(record.localId);
    }
    if (next.length == selection.length) return;
    setState(() => _selection = next);
  }

  void _onSelectDragEnd() {
    _dragSelecting = false;
    _dragSeen = const {};
  }

  /// Which tile is under [globalPosition], asked of the tiles themselves:
  /// each one carries its record in a `MetaData` (see `AssetTile`), so this
  /// is a hit test rather than arithmetic on the grid's geometry and the
  /// scroll offset — which would have to be kept in step with the layout
  /// and silently wouldn't be.
  AssetRecord? _recordUnder(Offset globalPosition) {
    final view = View.maybeOf(context);
    if (view == null) return null;
    final result = HitTestResult();
    WidgetsBinding.instance.hitTestInView(result, globalPosition, view.viewId);
    for (final entry in result.path) {
      final target = entry.target;
      if (target is RenderMetaData) {
        final data = target.metaData;
        if (data is AssetRecord) return data;
      }
    }
    return null;
  }

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

  /// Pick an album, or make one on the way — the same sheet the rest of
  /// the app picks anything by name with. Returns null if nothing was
  /// chosen.
  Future<Album?> _pickAlbum() async {
    final l10n = AppLocalizations.of(context)!;
    final albums = await _albumStore.listAll();
    if (!mounted) return null;
    return showSearchPickerSheetOf<Album>(
      context: context,
      title: l10n.albumAddToAction,
      options: albums,
      labelOf: (a) => a.name,
      emptyHint: l10n.albumsNewNamePlaceholder,
      createLabel: (query) =>
          query.isEmpty ? null : l10n.personPickerNewNamed(query),
      onCreate: (query) =>
          _albumStore.upsert(id: _albumStore.newId(), name: query),
    );
  }

  /// One photo or forty, the same way: pick the album, or type a name and
  /// get one. Nothing about "add this to an album" changes with the count,
  /// so neither does the flow.
  Future<void> _addToAlbum(List<AssetRecord> records) async {
    if (records.isEmpty) return;
    final album = await _pickAlbum();
    if (album == null) return;
    await _albumStore.addAssets(album.id, records.map((r) => r.localId));
    if (!mounted) return;
    setState(() => _selection = null);
    await reload();
    if (mounted) {
      _showResult(
        AppLocalizations.of(context)!.albumAddedToConfirm(album.name),
      );
    }
  }

  Future<void> _batchAddToAlbum() => _addToAlbum(_selectedRecords);

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
    await openPrivateAlbums(
      context,
      assetRecordStore: assetRecordStore,
      custody: _custody,
    );
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
          icloudBackup: _icloudBackup,
        ),
      ),
    );
    await _syncEverything();
  }

  /// Every video in the library, as an album. Not a row in the album table:
  /// there's nothing to add to it or remove from it, and a membership list
  /// would only be a second, staler answer to a question the library can
  /// already answer.
  List<AssetRecord> get _videos => _active.where((r) => r.isVideo).toList();

  List<AssetRecord> get _favorites =>
      _active.where((r) => r.isFavorite).toList();

  /// A card for a grouping the library makes itself. No row of its own in
  /// the database: there's nothing to add to it or remove from it, and a
  /// stored membership list would only be a second, staler answer to a
  /// question the library can already answer.
  Album _builtInAlbum(String id, String name) =>
      Album(id: id, name: name, createdAt: DateTime.now());

  static const _videosAlbumId = 'builtin:videos';
  static const _favoritesAlbumId = 'builtin:favorites';

  void _openVideos() {
    final l10n = AppLocalizations.of(context)!;
    _openGroup(l10n.albumsVideosName, _videos);
  }

  Future<void> _createAlbum() async {
    final l10n = AppLocalizations.of(context)!;
    final controller = TextEditingController();
    final name = await showCupertinoDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => CupertinoAlertDialog(
          title: Text(l10n.albumsNewTitle),
          content: Padding(
            padding: const EdgeInsets.only(top: 12),
            child: CupertinoTextField(
              controller: controller,
              autofocus: true,
              placeholder: l10n.albumsNewNamePlaceholder,
              onChanged: (_) => setState(() {}),
            ),
          ),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(l10n.actionCancel),
            ),
            CupertinoDialogAction(
              onPressed: controller.text.trim().isEmpty
                  ? null
                  : () => Navigator.of(context).pop(controller.text.trim()),
              child: Text(l10n.actionAdd),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    if (name == null || name.isEmpty) return;
    final album = await _albumStore.upsert(id: _albumStore.newId(), name: name);
    await reload();
    if (!mounted) return;
    // Straight into it: a new album's next question is what goes in it.
    _openAlbum(album);
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
                  onMissing: _onAssetMissing,
                  onSelectDragUpdate: _onSelectDragUpdate,
                  onSelectDragEnd: _onSelectDragEnd,
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
                      onAddToAlbum: _batchAddToAlbum,
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

  /// Kept clear at the trailing end of the bar for its own buttons — add
  /// and search. A translucent overlay still wins the gesture arena against
  /// what's under it, so anything covered here is a button that can't be
  /// pressed.
  static const _navigationBarActionWidth = 128.0;

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
      // Buttons, not fields. A search box living at the top of the scroll
      // content is a box nobody can reach: the page opens at the *newest*
      // photo, so the field sat a decade of scrolling away. On the
      // navigation bar they're in the same place whatever you're looking
      // at — which is the whole argument for importing living here too,
      // rather than at the end of a grid you have to reach the bottom of.
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          CupertinoButton(
            // A bar button is a thumb target, not a glyph: zero padding
            // around a 22pt icon is a quarter of the area a finger needs.
            padding: const EdgeInsets.symmetric(horizontal: 6),
            minimumSize: const Size(40, 44),
            onPressed: _busy ? null : addFiles,
            child: const Icon(CupertinoIcons.add, size: 24),
          ),
          if (_all.isNotEmpty)
            CupertinoButton(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              minimumSize: const Size(40, 44),
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
        ],
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
        child: _SubsectionHeader(
          title: l10n.collectionsAlbums,
          onAdd: _createAlbum,
        ),
      ),
      SliverToBoxAdapter(
        child: SizedBox(
          height: 190,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            // Favourites, then Videos, then the user's own. The first two
            // aren't albums anybody made — they're the two groupings the
            // library can always answer for itself, so they're always
            // there and there's nothing to delete.
            itemCount: _albums.length + 2,
            separatorBuilder: (context, i) => const SizedBox(width: 12),
            itemBuilder: (context, i) => SizedBox(
              width: 140,
              child: switch (i) {
                0 => _AlbumCard(
                  album: _builtInAlbum(
                    _favoritesAlbumId,
                    l10n.collectionsFavoritesRow,
                  ),
                  records: _favorites,
                  onTap: () => _push(
                    FavoritesScreen(assetRecordStore: assetRecordStore),
                  ),
                ),
                1 => _AlbumCard(
                  album: _builtInAlbum(_videosAlbumId, l10n.albumsVideosName),
                  records: _videos,
                  onTap: _openVideos,
                ),
                _ => _AlbumCard(
                  album: _albums[i - 2],
                  records: _albumAssets[_albums[i - 2].id] ?? const [],
                  onTap: () => _openAlbum(_albums[i - 2]),
                  onDelete: () => _confirmDeleteAlbum(_albums[i - 2]),
                ),
              },
            ),
          ),
        ),
      ),
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
                height: 150,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: _people.length,
                  separatorBuilder: (context, i) => const SizedBox(width: 12),
                  itemBuilder: (context, i) {
                    final person = _people[i];
                    return SizedBox(
                      width: 100,
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
        child: _GroupList(
          groups: _groupedBy((r) => r.location),
          emptyNote: l10n.collectionsPlacesEmpty,
          icon: CupertinoIcons.map_pin_ellipse,
          color: CupertinoColors.systemTeal,
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
        child: _GroupList(
          groups: _groupedBy((r) => r.event, byRecency: true),
          emptyNote: l10n.collectionsEventsEmpty,
          icon: CupertinoIcons.calendar,
          color: CupertinoColors.systemOrange,
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
            // Filled, like every other glyph in this list — the outline
            // silo drawn for this row read as a different icon set. An
            // archive box is what a bucket you own actually is: things put
            // away somewhere safe, rather than a cloud (which reads as
            // iCloud, the one thing this isn't).
            icon: CupertinoIcons.archivebox_fill,
            color: CupertinoColors.systemTeal,
            title: l10n.collectionsCloudSettingsRow,
            onTap: _openCloudBackups,
          ),
          // The sync queue isn't here any more: it lives on Cloud
          // Settings, beside the buckets it's filling, and having it in
          // two places made two answers to "is it working?".
          _row(
            icon: CupertinoIcons.wand_stars,
            color: CupertinoColors.systemIndigo,
            title: l10n.collectionsAnalyzeQueueRow,
            count: _toAnalyzeCount == 0 ? null : _toAnalyzeCount,
            onTap: () => _push(
              AnalyzeQueueScreen(queue: _analyzeQueue, onOpenAsset: _openById),
            ),
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
    this.onDelete,
  });

  final Album album;
  final List<AssetRecord> records;
  final VoidCallback onTap;

  /// Absent for the built-in Videos album — there's nothing there to
  /// delete, and a greyed-out Delete would only invite the attempt.
  final VoidCallback? onDelete;

  void _showActions(BuildContext context, AppLocalizations l10n) {
    final onDelete = this.onDelete;
    if (onDelete == null) return;
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

  /// The photo on the card: the one chosen for it, else the newest in the
  /// album. Always *something* while the album has anything in it — the
  /// card used to draw a grey icon unless the cover happened to be a
  /// manually-added file, so an album of camera-roll photos (which is most
  /// of them) looked empty.
  AssetRecord? get _cover {
    if (records.isEmpty) return null;
    final chosen = album.coverLocalId;
    if (chosen != null) {
      for (final record in records) {
        if (record.localId == chosen) return record;
      }
    }
    return records.last;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cover = _cover;

    return GestureDetector(
      onTap: onTap,
      onLongPress: () => _showActions(context, l10n),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: cover == null
                  ? const ColoredBox(
                      color: CupertinoColors.systemGrey5,
                      child: Icon(CupertinoIcons.photo_on_rectangle),
                    )
                  // Drawn the way a grid tile is, which is what makes a
                  // camera-roll photo — or a video's poster frame — show
                  // up here at all.
                  : SizedBox(
                      width: double.infinity,
                      child: assetImage(
                        cover,
                        placeholder: () => const ColoredBox(
                          color: CupertinoColors.systemGrey5,
                          child: Icon(CupertinoIcons.photo),
                        ),
                      ),
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
        PersonAvatar.forPerson(
          assetRecordStore: assetRecordStore,
          person: person,
          size: 92,
        ),
        const SizedBox(height: 6),
        Text(
          person.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 13),
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

/// Albums, People, Places, Events — each a section of the page, not a
/// subsection of one. They used to sit under a "Collections" heading that
/// named a category nobody was looking for: you look for people, or for a
/// place, and the extra level only pushed all four further down.
class _SubsectionHeader extends StatelessWidget {
  const _SubsectionHeader({
    required this.title,
    this.onMore,
    this.moreLabel,
    this.onAdd,
  });

  final String title;

  /// A "+" beside the title — the section's own create action (a new
  /// album). Sits opposite [onMore], which is where the section goes on to
  /// rather than what it makes.
  final VoidCallback? onAdd;

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
      padding: const EdgeInsets.fromLTRB(16, 28, 16, 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // Flexible, because a section title at this size plus a "More"
          // beside it is wider than a phone in some languages.
          Flexible(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 22),
            ),
          ),
          if (onAdd != null)
            CupertinoButton(
              padding: EdgeInsets.zero,
              minimumSize: Size.zero,
              onPressed: onAdd,
              child: const Icon(
                CupertinoIcons.add_circled,
                size: 22,
                color: CupertinoColors.activeBlue,
              ),
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
    required this.onAddToAlbum,
    required this.onSetPlace,
    required this.onSetEvent,
    required this.onAdjustDateTime,
    required this.onDelete,
    required this.onDone,
  });

  final int count;
  final VoidCallback onAddTag;
  final VoidCallback onAddToAlbum;
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
              padding: const EdgeInsets.fromLTRB(8, 2, 8, 6),
              // Four, not six. Six actions across a phone left each one a
              // 9-point glyph over a word too small to read, and the two
              // anybody presses — album and delete — were the same size as
              // the ones nobody does. What's left is the batch *metadata*
              // edits, which belong together in a menu because that's what
              // they are: a list of fields to set.
              child: Row(
                children: [
                  Expanded(
                    child: _SelectionAction(
                      icon: CupertinoIcons.rectangle_stack_badge_plus,
                      label: l10n.selectionAddToAlbum,
                      onPressed: count == 0 ? null : onAddToAlbum,
                    ),
                  ),
                  Expanded(
                    child: _SelectionAction(
                      icon: CupertinoIcons.tag,
                      label: l10n.selectionAddTag,
                      onPressed: count == 0 ? null : onAddTag,
                    ),
                  ),
                  Expanded(
                    child: _SelectionAction(
                      icon: CupertinoIcons.ellipsis_circle,
                      label: l10n.selectionMore,
                      onPressed: count == 0
                          ? null
                          : () => _showMore(context, l10n),
                    ),
                  ),
                  Expanded(
                    child: _SelectionAction(
                      icon: CupertinoIcons.delete,
                      label: l10n.selectionDelete,
                      destructive: true,
                      onPressed: count == 0 ? null : onDelete,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The rest of the batch edits — the ones that set a field on everything
  /// selected. A sheet rather than four more buttons: they're rarer, they
  /// read as a list, and each one opens a picker of its own anyway.
  void _showMore(BuildContext context, AppLocalizations l10n) {
    showCupertinoModalPopup<void>(
      context: context,
      builder: (sheetContext) => CupertinoActionSheet(
        title: Text(l10n.selectionTitle(count)),
        actions: [
          CupertinoActionSheetAction(
            onPressed: () {
              Navigator.of(sheetContext).pop();
              onSetPlace();
            },
            child: Text(l10n.selectionSetPlace),
          ),
          CupertinoActionSheetAction(
            onPressed: () {
              Navigator.of(sheetContext).pop();
              onSetEvent();
            },
            child: Text(l10n.selectionSetEvent),
          ),
          CupertinoActionSheetAction(
            onPressed: () {
              Navigator.of(sheetContext).pop();
              onAdjustDateTime();
            },
            child: Text(l10n.selectionAdjustDateTime),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(sheetContext).pop(),
          child: Text(l10n.actionCancel),
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
  Widget build(BuildContext context) {
    final color = destructive && onPressed != null
        ? CupertinoColors.systemRed
        : null;
    return CupertinoButton(
      // A thumb-sized target with a face, not a glyph with a caption: at
      // 44 points tall with a filled back it reads as a button from across
      // the room, which is what a bar you press in a hurry needs.
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
      minimumSize: const Size(0, 56),
      borderRadius: BorderRadius.circular(12),
      onPressed: onPressed,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 26, color: color),
          const SizedBox(height: 4),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: color),
          ),
        ],
      ),
    );
  }
}

/// Places/Events: one text row per distinct value the user has set.
///
/// These were cover cards, the same 140x190 as an album. A place is a word,
/// though, and most places had no photo worth that much room — the section
/// read as a row of grey pins with a name under each. A name and a count is
/// the whole content, so it gets a line, and the section gets its screen
/// back. Long lists fold after [_unfoldedRows], with the rest one tap
/// away.
class _GroupList extends StatefulWidget {
  const _GroupList({
    required this.groups,
    required this.emptyNote,
    required this.icon,
    required this.color,
    required this.onTap,
  });

  final Map<String, List<AssetRecord>> groups;
  final String emptyNote;
  final IconData icon;
  final Color color;
  final void Function(String title, List<AssetRecord> records) onTap;

  /// Enough to see what's there without the page becoming a list of
  /// places; the rest are one tap away.
  static const _unfoldedRows = 5;

  @override
  State<_GroupList> createState() => _GroupListState();
}

class _GroupListState extends State<_GroupList> {
  bool _showAll = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final entries = widget.groups.entries.toList();
    if (entries.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: Text(
          widget.emptyNote,
          style: const TextStyle(color: CupertinoColors.systemGrey),
        ),
      );
    }

    final visible = _showAll
        ? entries
        : entries.take(_GroupList._unfoldedRows).toList();
    return CupertinoListSection.insetGrouped(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      backgroundColor: const Color(0xFF1C1C1E),
      decoration: const BoxDecoration(
        color: Color(0xFF2C2C2E),
        borderRadius: BorderRadius.all(Radius.circular(10)),
      ),
      children: [
        for (final entry in visible)
          CupertinoListTile(
            key: ValueKey(entry.key),
            leading: Container(
              width: 29,
              height: 29,
              decoration: BoxDecoration(
                color: widget.color,
                borderRadius: BorderRadius.circular(7),
              ),
              child: Icon(widget.icon, color: CupertinoColors.white, size: 17),
            ),
            title: Text(
              entry.key,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '${entry.value.length}',
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
            onTap: () => widget.onTap(entry.key, entry.value),
          ),
        if (entries.length > visible.length || _showAll)
          CupertinoListTile(
            title: Text(
              _showAll
                  ? l10n.collectionsShowLess
                  : l10n.collectionsShowAll(entries.length),
              style: const TextStyle(color: CupertinoColors.activeBlue),
            ),
            onTap: () => setState(() => _showAll = !_showAll),
          ),
      ],
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
