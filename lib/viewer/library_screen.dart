import 'dart:async';
import 'dart:io';

import '../main.dart' show screenshotRequest;

import 'package:flutter/cupertino.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/foundation.dart' show mapEquals;

import 'package:flutter/gestures.dart' show HitTestResult;
import 'package:flutter/rendering.dart' show RenderMetaData;
import 'package:flutter/services.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;

import '../l10n/app_localizations.dart';
import '../demo/demo_flag.dart';
import '../demo/demo_mode.dart';
import '../photos/conversation_store.dart';
import '../photos/import_log_backfill.dart';
import '../photos/words_store.dart';
import '../photos/derived_asset.dart';
import '../photos/flag_scan.dart';
import '../photos/asset_removal.dart';
import '../photos/library_metadata.dart';
import '../photos/library_scanner.dart';
import '../photos/ai_analysis_store.dart';
import '../photos/face_analyzer.dart';
import '../photos/file_hash.dart' as file_hash;
import '../photos/manual_add.dart';
import '../photos/share_inbox.dart';
import '../photos/on_device_analysis.dart';
import '../photos/person.dart';
import '../photos/people_order.dart';
import '../photos/people_zip.dart' show PeopleZip;
import '../photos/person_store.dart';
import '../photos/face_identity.dart';
import '../photos/photo_library_change.dart';
import '../backup/app_snapshot.dart';
import '../backup/bucket_backup.dart';
import '../backup/icloud_backup.dart';
import '../backup/local_vault.dart';
import '../backup/pause_backup.dart';
import '../photos/library_custody.dart';
import '../photos/photo_library_service.dart';
import '../photos/record_fixer.dart';
import '../photos/photo_location.dart';
import '../photos/fix_queue.dart';
import '../photos/storage_advice.dart';
import '../photos/storage_optimizer.dart';
import '../photos/temp_renders.dart';
import '../photos/thumbnail_cache.dart';
import '../settings/app_data_removal.dart';
import '../settings/app_store_region.dart';
import '../settings/backup_targets_store.dart';
import '../upload/bucket_flagged.dart' show BucketFixer;
import '../upload/bucket_import.dart';
import '../upload/name_migration.dart';
import '../upload/original_restore.dart';
import '../settings/settings_screen.dart';
import '../storage/album.dart';
import '../storage/album_store.dart';
import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import '../storage/bucket_object.dart';
import '../storage/membership_sweep.dart';
import '../upload/backup_coordinator.dart';
import '../upload/background_sync.dart'
    show BackgroundHeartbeat, ForegroundHeartbeat;
import '../upload/sync_engine.dart';
import '../upload/backup_verifier.dart';
import '../upload/library_restore.dart';
import '../vault/hidden_repair.dart';
import '../vault/hidden_transition.dart';
import '../vault/hidden_backup.dart';
import '../vault/bucket.dart';
import '../vault/carrier_upload.dart';
import '../vault/decoy.dart';
import '../vault/keys.dart';
import '../vault/passcode_tags.dart';
import '../vault/plain_files.dart';
import '../vault/store.dart';
import '../upload/pending_deletes.dart';
import '../upload/sync_job_store.dart';
import '../upload/s3_uploader.dart';
import '../upload/sync_queue.dart';
import 'home_summary.dart';
import 'library_index.dart';
import 'album_screen.dart';
import 'asset_grid.dart';
import 'select_sweep.dart';
import '../upload/bucket_leftovers.dart';
import '../upload/cloud_thumbnails.dart';
import 'built_in_album.dart';
import 'asset_grid_view.dart';
import 'asset_group_screen.dart';
import 'delete_confirmation.dart';
import 'detail_screen.dart';
import 'developer_options_screen.dart';
import 'favorites_screen.dart';
import 'resize_photos.dart';
import 'select_all.dart';
import 'people_screen.dart';
import 'photo_grid_layout.dart';
import 'person_avatar.dart';
import 'person_page_screen.dart';
import 'private_album_gate.dart';
import 'private_album_screen.dart';
import 'recently_deleted_screen.dart';
import 'safety_screen.dart';
import 'search_picker_sheet.dart';
import 'suggestions_screen.dart';
import 'zoom_page_route.dart';

/// The whole app, one page — matches real Photos: no separate "Library" vs
/// "Collections" tabs, just a day-grouped grid up top and Media
/// Types/Utilities sections below (Favorites/Hidden/Recently Deleted are
/// real; Cloud Backups is this app's own).
/// Lists manually-added files, not a real camera-roll grid (T4.1 still
/// needs `photo_manager`, T2.1).
class LibraryScreen extends StatefulWidget {
  const LibraryScreen({
    super.key,
    this.assetRecordStore,
    this.backupTargetsStore,
    this.albumStore,
    this.manualAddService,
    this.backupCoordinator,
    this.aiAnalysisStore,
    this.photoLibraryService,
    this.photoLocationService,
    this.libraryCustody,
    this.icloudBackup,
    this.bucketBackup,
    this.vault,
    this.appDataRemoval,
    this.vaultStore,
    this.backgroundPassInterval,
    this.launchSettle,
    this.personStore,
    this.hashFile,
    this.thumbnailCache,
    this.syncJobStore,
    this.onDeviceAnalysis,
    this.restoreOriginal,
  });

  final AssetRecordStore? assetRecordStore;
  final BackupTargetsStore? backupTargetsStore;

  /// Pulls a photo's full-quality copy back out of a bucket. Only the lock
  /// uses it from here — the detail screen has its own. Overridable so
  /// tests never reach for a real bucket.
  final Future<String?> Function(AssetRecord record)? restoreOriginal;
  final AlbumStore? albumStore;

  /// Overridable for tests so People never opens the real `sqflite` factory.
  final PersonStore? personStore;

  /// Overridable for tests so the People smart collection never opens
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

  /// Overridable for tests so backgrounding never writes into the real
  /// app container.
  final LocalVault? vault;

  /// The durable local home for hidden photos. Optional so tests point it at
  /// a temp directory rather than the real container.
  final VaultStore? vaultStore;

  /// Remove All App Data, end to end — the button at the foot of this page.
  /// Optional so tests can hand in one that touches no container, keychain
  /// or queue database.
  final AppDataRemoval? appDataRemoval;

  /// How often the background pass looks for work — backups still owed,
  /// then the camera roll, then the on-device face pass. Null switches it
  /// off, which is the default: a periodic timer is something a caller
  /// opts into, and a widget test that never asked for one would otherwise
  /// wait for it forever.
  final Duration? backgroundPassInterval;

  /// How long the screen has to sit untouched before each stage of the
  /// launch work starts (queue resume, then the full scan, faces and the
  /// scheduled sync). Null starts them all at once, as tests expect.
  final Duration? launchSettle;

  /// Overridable for tests so they never open the real file picker.
  final ManualAddService? manualAddService;

  /// Overridable for tests so they never touch the real asset bundle / disk.

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
  late final VaultKeys _vaultKeys = VaultKeys();
  late final HiddenBackup _hiddenBackup = HiddenBackup(
    records: assetRecordStore,
    backUp: _engine.backUpHidden,
    albums: () => _vaultKeys.unlockedHashes,
    ready: _engine.hasBackupTarget,
  );
  late final CarrierBuilder _carriers = CarrierBuilder(
    posterFrame: (record) => _thumbnailCache.libraryThumbnail(record),
    videoDuration: _photoLibraryService.durationOf,
  );

  /// Where hidden photos actually live on this phone — the copy the bucket
  /// is a backup *of*, not the other way round. See `../vault/store.dart`.
  late final VaultStore _vaultStore = widget.vaultStore ?? VaultStore();
  late final VaultBucket _vaultBucket = VaultBucket(
    targetsStore: _backupTargetsStore,
    store: _vaultStore,
  );

  late final BackupCoordinator _coordinator =
      widget.backupCoordinator ??
      BackupCoordinator(
        targetsStore: _backupTargetsStore,
        recordStore: assetRecordStore,
        carriers: _carriers,
        vaultKeys: _vaultKeys,
        vaultStore: _vaultStore,
        decoyCandidates: _decoyCandidates,
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

  /// One reader of the three stores, shared by every tier below it.
  late final AppSnapshotIo _snapshots = AppSnapshotIo(
    assetRecordStore: assetRecordStore,
    albumStore: _albumStore,
    personStore: _personStore,
    aiAnalysisStore: _aiAnalysisStore,
    hasAsset: (id) => _photoLibraryService.hasAsset(id),
    conversationStore: ConversationStore(),
    wordsStore: WordsStore(),
  );

  late final PauseBackup _pauseBackup = PauseBackup(
    snapshots: _snapshots,
    vault: _vault,
    icloud: _icloudBackup,
    bucket: _bucketBackup,
  );

  /// Remove All App Data, from the button at the foot of this page.
  late final AppDataRemoval _appDataRemoval =
      widget.appDataRemoval ??
      AppDataRemoval(
        snapshots: _snapshots,
        settings: assetRecordStore,
        vault: _vault,
        icloudBackup: _icloudBackup,
        bucketBackup: _bucketBackup,
        targetsStore: _backupTargetsStore,
      );

  late final LocalVault _vault =
      widget.vault ??
      LocalVault(snapshots: _snapshots, settings: assetRecordStore);
  late final ICloudBackup _icloudBackup =
      widget.icloudBackup ??
      ICloudBackup(settings: assetRecordStore, snapshots: _snapshots);
  late final BucketBackup _bucketBackup =
      widget.bucketBackup ??
      BucketBackup(
        settings: assetRecordStore,
        targetsStore: _backupTargetsStore,
        snapshots: _snapshots,
      );
  late final Future<String> Function(String path) _hashFile =
      widget.hashFile ?? file_hash.hashFile;
  late final ThumbnailCache _thumbnailCache =
      widget.thumbnailCache ?? ThumbnailCache(store: assetRecordStore);
  late final StorageAdvisor _storageAdvisor = StorageAdvisor(
    store: assetRecordStore,
    library: _photoLibraryService,
  );
  late final LibraryRestore _libraryRestore = LibraryRestore(
    recordStore: assetRecordStore,
    originals: OriginalRestore(
      targetsStore: _backupTargetsStore,
      recordStore: assetRecordStore,
    ),
  );

  /// The one thing in the app that asks the bucket whether a backup is
  /// real, instead of asking this app's own database. Shared by every path
  /// that destroys a local original. See `../upload/backup_verifier.dart`.
  late final BackupVerifier _backupVerifier = BackupVerifier(
    targetsStore: _backupTargetsStore,
    recordStore: assetRecordStore,
  );
  late final StorageOptimizer _storageOptimizer = StorageOptimizer(
    store: assetRecordStore,
    thumbnails: _thumbnailCache,
    library: _photoLibraryService,
    backUp: _backUpRecords,
    verifier: _backupVerifier,
  );

  /// Lives here rather than on the Suggestions page, so leaving the page
  /// doesn't stop a run.
  late final BucketFixer _bucketFixer = BucketFixer(
    store: assetRecordStore,
    targetsStore: _backupTargetsStore,
    passphrases: _vaultKeys.entries,
    uploader: S3Uploader(),
    downloader: S3Downloader(),
  );

  late final FixQueue _fixQueue = FixQueue(
    store: assetRecordStore,
    advisor: _storageAdvisor,
    optimizer: _storageOptimizer,
    fixer: _bucketFixer,
    refreshBucket: () => BucketIndexer(
      targetsStore: _backupTargetsStore,
      recordStore: assetRecordStore,
    ).refresh(),
    records: RecordFixer(
      store: assetRecordStore,
      thumbnail: OriginalRestore(
        targetsStore: _backupTargetsStore,
        recordStore: assetRecordStore,
      ).restoreThumbnail,
      inPhotos: (record) async =>
          await _photoLibraryService.entityFor(record) != null,
      remove: (record) async {
        if (record.isLocked) return false;
        await _removal.purge(record);
        return true;
      },
      fileCopies: _storageOptimizer.fileFoundCopies,
      liveOriginal: _bucketFixer.liveOriginal,
      durationOf: _photoLibraryService.durationOf,
    ),
  );

  /// Beside the queue for the same reason: a scan outlives the page.
  late final FlagScan _flagScan = FlagScan(
    store: assetRecordStore,
    targetsStore: _backupTargetsStore,
    advisor: _storageAdvisor,
    queue: _fixQueue,
    uploading: syncQueue.draining,
  );

  /// Deleting is the same decision on every screen: keep the cloud copy
  /// and free the space, or bin it. See `../photos/asset_removal.dart`.
  late final AssetRemoval _removal = AssetRemoval(
    store: assetRecordStore,
    thumbnails: _thumbnailCache,
    library: _photoLibraryService,
    verifier: _backupVerifier,
  );
  late final SyncJobStore _syncJobStore = widget.syncJobStore ?? SyncJobStore();
  late final OnDeviceAnalysisService _onDeviceAnalysis =
      widget.onDeviceAnalysis ??
      OnDeviceAnalysisService(
        analysisStore: _aiAnalysisStore,
        onReoriented: _personStore.reorientAvatars,
      );

  late final ForegroundHeartbeat _heartbeat = ForegroundHeartbeat(
    assetRecordStore,
  );

  late final SyncEngine _engine = SyncEngine(
    recordStore: assetRecordStore,
    targetsStore: _backupTargetsStore,
    coordinator: _coordinator,
    thumbnailCache: _thumbnailCache,
    library: _photoLibraryService,
    syncJobStore: _syncJobStore,
    pendingDeletes: _pendingDeletes,
    records: () => _all,
    displayName: _displayNameFor,
    hashFile: _hashFile,
    analyze: _onDeviceAnalysis.analyze,
  );

  /// The one queue every unit of sync work goes through. Public so the
  /// Cloud Settings screen can show and control it.
  SyncQueue get syncQueue => _engine.syncQueue;

  /// Not a queue anybody can see: re-reading the camera roll is the app
  /// noticing what Photos did while it wasn't looking, not work the user
  /// chose. Nothing about it is pausable or paceable — a library that
  /// stopped noticing would quietly stop showing new photos.
  late final LibraryScanner _libraryScanner = LibraryScanner(
    scan: _syncPhotoLibrary,
    scanRecent: _syncRecentPhotos,
    scanChanges: _syncPhotoChanges,
    lastFullPass: _photoLibraryService.lastFullPassAt,
    before: () => _restoreFirst ?? Future<void>.value(),
  );

  /// A fresh install's restore, which the scan waits on (bounded by
  /// [_restoreHold]); null once there is nothing to wait for.
  Future<void>? _restoreFirst;
  static const _restoreHold = Duration(seconds: 30);

  static const _peopleOnlyKey = 'people_only_marked_v1';

  /// Photos a people zip loaded before they were kept for their people
  /// only: archived files of this app's, tagged to somebody. Once.
  Future<void> _markZipPhotosOnce() async {
    try {
      if (await assetRecordStore.getAppState(_peopleOnlyKey) != null) return;
      final tagged = {
        for (final ids in (await _personStore.allMemberships()).values) ...ids,
      };
      final ids = [
        for (final r in await assetRecordStore.listAll())
          if (r.isArchived &&
              !r.peopleOnly &&
              r.sourceType != AssetSourceType.photoManager &&
              tagged.contains(r.localId))
            r.localId,
      ];
      await assetRecordStore.setPeopleOnly(ids, true);
      await assetRecordStore.setAppState(_peopleOnlyKey, '1');
      if (ids.isNotEmpty && mounted) await reload();
    } catch (_) {
      // Tried again next launch.
    }
  }

  /// Faces of the photos opened or picked, one at a time, out of sight.
  late final FaceAnalyzer _faceAnalyzer = FaceAnalyzer(
    assetRecordStore: assetRecordStore,
    analysisStore: _aiAnalysisStore,
    onDeviceAnalysis: _onDeviceAnalysis,
    faceIdentity: _faceIdentity,
    taggedPeopleOf: (localId) async => [
      for (final p in await _personStore.peopleFor(localId)) p.id,
    ],
    resolvePath: _filePathFor,
    resolveSource: _visionSourceFor,
  );
  StreamSubscription<String>? _facesFound;
  Timer? _housekeeping;
  Timer? _facesReload;

  /// Who the faces belong to, across photos. One instance: it holds the
  /// reference set every screen's suggestions are measured against.
  late final FaceIdentityService _faceIdentity = FaceIdentityService(
    analysisStore: _aiAnalysisStore,
  );

  /// Newest chat per person: part of Last seen when People sorts by it.
  late final _conversations = ConversationStore();

  List<AssetRecord> _all = const [];
  LibraryIndex? _index;

  /// Whether [reload] has finished once. Distinguishes a library that is
  /// empty from one that hasn't been read yet — see the grid's
  /// `emptySliver`.
  bool _loaded = false;

  /// Everything derived from [_all], computed once per [reload] instead of
  /// per build. Each one is a pass over the whole library — several of
  /// them sort it — and `build` reads five: as getters, that was five passes
  /// over tens of thousands of records every time anything called
  /// `setState`, which is the jank CLAUDE.md's "no per-build work
  /// proportional to library size" rule exists to prevent.
  List<AssetRecord> _active = const [];

  /// The grid: [_active] less the archive.
  List<AssetRecord> _home = const [];
  List<AssetRecord> _archived = const [];
  List<AssetRecord> _videos = const [];
  List<AssetRecord> _favorites = const [];
  List<AssetRecord> _recentlyAdded = const [];
  Map<String, List<AssetRecord>> _places = const {};
  int _deletedCount = 0;
  List<Album> _albums = const [];
  Map<String, List<AssetRecord>> _albumAssets = const {};
  List<Person> _people = const [];
  Map<String, int> _personPhotoCounts = const {};

  /// Each person's first visible photo — their picture until one is chosen.
  Map<String, String> _personFirstPhotos = const {};

  bool _busy = false;
  bool _removingAppData = false;

  /// Non-null while "hold a photo to select" mode is on — the set of
  /// `localId`s the batch actions apply to. Entering or leaving the mode
  /// rebuilds the screen; a change of what is picked notifies [_picked]
  /// only (see [_select]).
  Set<String>? get _selection => _selecting ? _picked.value : null;
  set _selection(Set<String>? next) {
    _selecting = next != null;
    _picked.value = next ?? const {};
  }

  bool _selecting = false;
  final _picked = ValueNotifier<Set<String>>(const {});

  void _select(Set<String>? next) {
    if ((next != null) != _selecting) {
      setState(() => _selection = next);
    } else if (next != null) {
      _picked.value = next;
    }
  }

  /// Reaches the grid's scroll anchor (see [_jumpHome]).
  final _gridKey = GlobalKey<AssetGridViewState>();

  /// iOS is short of memory and asking for some back. Thumbnails are the
  /// obvious thing to hand over: every byte of them can be fetched from
  /// the library again, and the alternative to answering is being killed
  /// — which is what "the app froze and vanished" usually is.
  @override
  void didHaveMemoryPressure() {
    clearThumbnailCaches();
    faceCrops.clear();
    PaintingBinding.instance.imageCache.clear();
  }

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
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.resumed) {
      unawaited(_heartbeat.beat().then((_) {}, onError: (_) {}));
    }
    if (state == AppLifecycleState.paused) {
      // The copy in the app's own container first, and unconditionally —
      // it needs no switch, no network and no credentials, and it's the
      // one that gets used when an operation goes wrong an hour from now.
      // One snapshot for all three, zipped off the UI isolate, inside the
      // time iOS grants on the way out.
      unawaited(_pauseBackup.run());
      unawaited(_refreshBucketListing());
      return;
    }
    if (state != AppLifecycleState.resumed || !mounted) return;
    // Coming back from Photos: something may have changed over there while
    // we weren't looking. The newest photos first and on their own lane,
    // then Photos' change history; the full pass only when that can't
    // vouch for what moved, or once a day.
    unawaited(_refreshBucketListing());
    unawaited(_scanRecentThenAll());
    unawaited(_sweepLeftovers());
    unawaited(_runScheduledSyncIfDue());
    unawaited(_hiddenBackup.run().catchError((_) {}));
    unawaited(_offerShared());
    _startTrickle();
  }

  /// The changes start once the newest photos are in: started together,
  /// both queue on the one database connection and the recent lane, the
  /// one somebody is waiting on, finishes behind them.
  Future<void> _scanRecentThenAll() async {
    await _libraryScanner.runRecent();
    await _libraryScanner.runChanges();
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
      await _showThenBackUp(result.added);
    } catch (_) {
      // Whatever this notification carried, the next scan finds anyway.
    }
  }

  @override
  void dispose() {
    PhotoManager.removeChangeCallback(_onPhotoLibraryChanged);
    WidgetsBinding.instance.removeObserver(this);
    _trickle?.cancel();
    if (_settle case (final timer, final done)?) {
      timer.cancel();
      done.complete();
    }
    _missingDebounce?.cancel();
    syncQueue.draining.removeListener(_onDrainingChanged);
    _fixQueue.removeListener(_onFixQueueChanged);
    _fixLeft.dispose();
    _picked.dispose();
    syncQueue.dispose();
    _housekeeping?.cancel();
    _facesFound?.cancel();
    _facesReload?.cancel();
    if (FaceAnalyzer.shared == _faceAnalyzer) FaceAnalyzer.shared = null;
    _faceAnalyzer.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    CloudThumbnails.instance = CloudThumbnails(
      fetch: OriginalRestore(
        targetsStore: _backupTargetsStore,
        recordStore: assetRecordStore,
      ).restoreThumbnail,
    );
    PrivateAlbumScreen.hiddenBackup = _hiddenBackup;
    FaceAnalyzer.shared = _faceAnalyzer;
    // Housekeeping once the first screens are up. At launch no import is
    // running, so any unpacked zip left is litter.
    _housekeeping = Timer(const Duration(seconds: 5), () async {
      await _markZipPhotosOnce();
      if (!mounted) return;
      try {
        await backfillImportLog(
          people: _personStore,
          settings: assetRecordStore,
          chats: _conversations,
        );
      } catch (_) {
        // Tried again next launch.
      }
      if (!mounted) return;
      await PeopleZip.sweepLeftovers(await getTemporaryDirectory());
    });
    unawaited(_faceAnalyzer.load());
    // A face linked by the analyzer can move People counts: reloaded once
    // it goes quiet for a moment, not per photo.
    _facesFound = _faceAnalyzer.finished.listen((_) {
      _facesReload?.cancel();
      _facesReload = Timer(const Duration(seconds: 2), () {
        if (mounted) reload(faces: true);
      });
    });
    _watchPhotoLibrary();
    syncQueue.draining.addListener(_onDrainingChanged);
    _fixQueue.addListener(_onFixQueueChanged);
    _init();
    _screenshotHook();
  }

  /// Simulator screenshots: `/tmp/pv-screenshot` names the screen; it can't exist on a phone.
  Future<void> _screenshotHook() async {
    final screen = screenshotRequest()?.$1;
    if (screen == null) return;
    await Future<void>.delayed(const Duration(seconds: 5));
    if (!mounted) return;
    switch (screen) {
      case 'people':
        _openPeopleScreen();
      case 'cloud':
        await _openCloudBackups();
      case 'detail':
        if (_home.isNotEmpty) await _openRecord(_home.first);
      case 'favorites':
        _push(
          FavoritesScreen(
            assetRecordStore: assetRecordStore,
            notes: _albumStore.noteBook(BuiltInAlbum.favorites.id),
          ),
        );
      case 'album':
        if (_albums.isNotEmpty) _openAlbum(_albums.first);
      case 'suggestions' || 'suggestions-action':
        // A few odd bucket files beside the demo photos, so every section
        // has something in it.
        final demoTargets = await _backupTargetsStore.loadAll();
        final demoTarget = demoTargets.isEmpty ? 'demo' : demoTargets.first.id;
        const odd = [
          ('photos-vault/originals/IMG_0042.PNG', 14 << 20),
          ('photos-vault/originals/holiday clip.mov', 220 << 20),
          ('photos-vault/thumbnails/20240101120000_ab.jpg', 40 << 10),
        ];
        await assetRecordStore.replaceBucketObjects(demoTarget, [
          ...(await assetRecordStore.listBucketObjects()).where(
            (o) => o.targetId == demoTarget && !odd.any((e) => e.$1 == o.key),
          ),
          for (final (key, size) in odd)
            BucketObject(
              targetId: demoTarget,
              key: key,
              size: size,
              lastModified: DateTime(2025, 6, 1),
            ),
        ]);
        SuggestionsScreen.demoOpenAction = screen == 'suggestions-action';
        _push(
          SuggestionsScreen(
            store: assetRecordStore,
            targetsStore: _backupTargetsStore,
            advisor: _storageAdvisor,
            queue: _fixQueue,
            scan: _flagScan,
            onOpenAsset: _openById,
            albumStore: _albumStore,
            personStore: _personStore,
            aiAnalysisStore: _aiAnalysisStore,
          ),
        );
      case 'hidden' || 'hidden-backup' || 'hidden-detail':
        // The demo seed's code, past the passcode sheet.
        const code = '1234';
        final tag = await PasscodeTags(
          records: assetRecordStore,
          people: _personStore,
          vaultKeys: _vaultKeys,
        ).tagFor(code);
        final keys = await _vaultKeys.unlockAlbum(code, tag);
        if (!mounted) return;
        _push(
          PrivateAlbumScreen(
            passcodeHash: tag,
            assetRecordStore: assetRecordStore,
            custody: _custody,
            albumKeys: keys,
            vaultKeys: _vaultKeys,
          ),
        );
    }
  }

  /// The Suggestions row shows a run draining from anywhere in the app:
  /// items left, null while idle. Only that row listens.
  final _fixLeft = ValueNotifier<int?>(null);

  void _onFixQueueChanged() {
    _fixLeft.value = _fixQueue.running ? _fixQueue.left : null;
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
    await reload(statusOnly: true);
    // Whatever full-size renders this run left in tmp (BG-2).
    if (syncQueue.processedInLastDrain > 0) {
      unawaited(TempRenders.sweep(inTransfer: activeUploadPaths));
    }
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
  /// photos arrive from the camera-roll scan below, and nothing else ever
  /// puts anything in it. Sample content used to be seedable from here;
  /// it shipped 208 KB of someone else's pictures to every user to
  /// demonstrate a photo app that already had the user's photos.
  Future<void> _init() async {
    // The database first, because it is a local read and it is what the
    // grid draws. Restoring used to come first and it asks iCloud whether
    // this is a fresh install — a platform channel and, on a cold start,
    // a network round trip — so every launch spent that long showing "No
    // Photos Yet" over a library that was on disk the whole time.
    unawaited(_heartbeat.beat().then((_) {}, onError: (_) {}));
    await reload();
    // A hide or un-hide a kill cut short, finished before anything uploads.
    await _finishTransitions();
    unawaited(_secureHiddenAtRest());
    unawaited(_offerShared());
    unawaited(
      HiddenRepair(store: assetRecordStore)
          .runOnce()
          .then((_) {}, onError: (_) {}),
    );
    // A fresh install pulls its own work back from iCloud, once, without
    // asking: there's nothing to overwrite and no context yet for a
    // "restore from backup?" question. Safe behind the reload above — it
    // reads the database itself to decide whether the install is fresh,
    // and a read changed nothing.
    // On an empty library the restore goes *first*, capped: both restores
    // refuse a library that already has rows, so a scan that got in ahead
    // of the network would make a fresh install skip its own backup.
    // The scans wait on it for longer (see [_restoreHold]) and the import
    // merges with whatever got in ahead, so a slow download costs neither
    // metadata nor a second record.
    if (_all.isEmpty) {
      final restore = _restoreAppDataThenReload(scannedRows: true)
          .timeout(_restoreHold, onTimeout: () {});
      _restoreFirst = restore;
      unawaited(restore.whenComplete(() => _restoreFirst = null));
      await restore.timeout(const Duration(seconds: 10), onTimeout: () {});
    } else {
      unawaited(_restoreAppDataThenReload());
    }
    // The newest end of the camera roll now: it is what somebody opening
    // the app is looking at. The rest waits for the screen to settle —
    // all of it queues on the one database connection, and every row it
    // reads comes back through the isolate drawing the first frames.
    final recent = _libraryScanner.runRecent().catchError((_) {});
    unawaited(_forgetHiddenJobs());
    await _launchSettled();
    if (!mounted) return;
    // Picks up whatever a previous run left queued — including jobs left
    // `running` by a kill mid-sync. Whether it then *drains* is the sync
    // frequency's call: on "Manual" the jobs stay visible and nothing goes
    // up until asked.
    unawaited(_resumeQueue());
    unawaited(_fixQueue.resume().catchError((_) {}));
    // Albums unlocked before the last close pick their backup up again.
    unawaited(
      _vaultKeys
          .restoreRing()
          .then((_) => _hiddenBackup.run())
          .catchError((_) {}),
    );
    await _launchSettled();
    if (!mounted) return;
    // Fire-and-forget: the changes since the last pass, or a full scan when
    // they can't be had, must never block showing what's already on hand.
    // Re-`reload()`s itself once done. After the recent lane, as
    // [_scanRecentThenAll].
    unawaited(recent.then((_) => _libraryScanner.runChanges()));
    // Independent of camera-roll access: retries whatever's already
    // pending/failed if the configured sync frequency says it's due — the
    // other natural "app came to the foreground" moment, alongside
    // returning to this screen from Cloud Backups (see `_openCloudBackups`).
    unawaited(_runScheduledSyncIfDue());
  }

  /// Set by a touch or a scroll anywhere on the screen.
  bool _touched = false;

  /// The wait under way; cut short by [dispose].
  (Timer, Completer<void>)? _settle;

  /// Launch stages still start if the screen never goes quiet.
  static const _launchStageCap = Duration(seconds: 30);

  /// Until a whole [LibraryScreen.launchSettle] has passed untouched, at
  /// most [_launchStageCap]. At once without one.
  Future<void> _launchSettled() async {
    final quiet = widget.launchSettle;
    if (quiet == null) return;
    _touched = false;
    for (var waited = Duration.zero; waited < _launchStageCap;) {
      final done = Completer<void>();
      _settle = (Timer(quiet, done.complete), done);
      await done.future;
      _settle = null;
      if (!mounted || !_touched) return;
      _touched = false;
      waited += quiet;
    }
  }

  DateTime? _bucketListedAt;

  /// Once ever: takes back out the bucket imports that were old copies.
  /// See [LeftoverSweep].
  Future<void> _sweepLeftovers() async {
    try {
      final removed = await LeftoverSweep(
        store: assetRecordStore,
        albumMemberships: _albumStore.allMemberships,
        personMemberships: _personStore.allMemberships,
      ).runOnce();
      if (removed > 0 && mounted) await reload();
    } catch (_) {
      // Tried again next launch: the flag is only set once it finished.
    }
  }

  /// One listing of every bucket into `bucket_object`, at most twice a day
  /// and never over an empty library: a fresh install has not restored its
  /// records yet, and would see every object in the bucket as unknown.
  Future<void> _refreshBucketListing() async {
    if (_all.isEmpty) return;
    final last = _bucketListedAt;
    if (last != null &&
        DateTime.now().difference(last) < const Duration(hours: 12)) {
      return;
    }
    _bucketListedAt = DateTime.now();
    try {
      final listed = await BucketIndexer(
        targetsStore: _backupTargetsStore,
        recordStore: assetRecordStore,
      ).refresh();
      // A partial listing is not evidence that a key is gone.
      await NameMigration(
        store: assetRecordStore,
        targetsStore: _backupTargetsStore,
      ).run(listed: listed);
      // Only noted for the Cloud settings row — never imported unasked.
      await BucketImport(
        targetsStore: _backupTargetsStore,
        recordStore: assetRecordStore,
        passphrases: _vaultKeys.entries,
      ).scan();
    } catch (_) {
      // Offline or unreadable: the old listing stands.
    }
  }

  Future<void> _restoreAppDataThenReload({bool scannedRows = false}) async {
    await _restoreAppData(scannedRows: scannedRows);
    if (mounted) await reload();
  }

  /// Whichever destination still has the snapshot. iCloud first because
  /// it needs no credentials to be readable; the bucket is asked only if
  /// that came back with nothing, and each guards itself against running
  /// over a library that isn't empty.
  Future<void> _restoreAppData({bool scannedRows = false}) async {
    try {
      await restoreNewestOnFreshInstall(
        icloud: _icloudBackup,
        bucket: _bucketBackup,
        scannedRows: scannedRows,
      );
    } catch (_) {
      // No container, no channel, no bucket, nothing in any of them — an
      // empty library is the same empty library it would have been.
    }
  }

  /// The near end of the camera roll, on every open and every return to
  /// the app, ahead of and independent of the full pass.
  ///
  /// The full scan is a database lookup per asset and minutes long on a
  /// real library, and until it finishes it reconciles nothing — so a photo
  /// deleted over in Photos this morning could sit in this app's grid for
  /// the length of a whole re-read, and a photo just taken could sit
  /// outside it. Both of those happen at the newest end, which is a couple
  /// of pages: read them, apply them, and account for anything newer than
  /// the oldest one that the library no longer has.
  /// Single-flight through [_libraryScanner], as is [_syncPhotoLibrary].
  Future<void> _syncRecentPhotos() async {
    try {
      final access = await _photoLibraryService.requestAccess();
      if (access == PhotoLibraryAccess.denied) return;
      final result = await _photoLibraryService.syncRecent(
        // Same rule as the full pass: under "Selected Photos" the listing
        // is a handful of assets and everything else would look deleted.
        reconcileDeletions: access == PhotoLibraryAccess.granted,
      );
      // An asset restored from Photos' own trash gets another chance at
      // resolving, the same as after a full pass.
      if (result.added.isNotEmpty) _retryUnresolvable();
      if (result.isEmpty || !mounted) return;
      await _showThenBackUp(result.added);
    } catch (_) {
      // No platform channel, or the permission flow failed — the full pass
      // covers the same ground, just not as promptly.
    }
  }

  /// What changed in Photos since the last pass, from its change history.
  /// False when that can't be had: [LibraryScanner] runs the full pass.
  Future<bool> _syncPhotoChanges() async {
    final result = await _photoLibraryService.syncChanges();
    if (result == null) return false;
    if (result.added.isNotEmpty) {
      _retryUnresolvable();
      // Without a full pass today, nothing else names their places.
      unawaited(_namePlaces());
    }
    if (!result.isEmpty && mounted) await _showThenBackUp(result.added);
    return true;
  }

  /// Pulls in the real camera roll (T2.1) — permission prompt on first run,
  /// silent on every launch after. Backs up anything newly seen the same
  /// way a manual add is, so granting access alone starts a backup.
  Future<void> _syncPhotoLibrary() async {
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
          // Redrawing per page would be O(library) work per page. Once a
          // second until the screen is full, then every few: later pages
          // land above the viewport, and the end of the pass draws anyway.
          final now = DateTime.now();
          final every = _all.length < _firstPaintCount
              ? const Duration(seconds: 1)
              : const Duration(seconds: 4);
          if (_all.isNotEmpty && now.difference(lastDraw) < every) return;
          lastDraw = now;
          unawaited(reload());
        },
      );
      // A re-read of the library is the one event that can put a missing
      // file back — an asset restored from Photos' own trash, a container
      // path healed. Everything given up on gets another chance.
      _retryUnresolvable();
      // Names the places the scan collected coordinates for. Runs after
      // the pages are in and on its own time (see
      // `PhotoLocationService.spacing`), so Places fills itself in from
      // photos nobody has opened yet — which is most of them.
      unawaited(_namePlaces());
      if (result.isEmpty) return;
      // Also redraws for a scan that only *changed* things — a heart taken
      // off a photo over in Photos adds nothing, and still has to show.
      await _showThenBackUp(result.added);
    } catch (_) {
      // No `photo_manager` platform channel (tests, unsupported platform)
      // or the permission flow failed — leave the camera roll unsynced
      // rather than crash; manually added photos still work.
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
    await _libraryScanner.run();
    // Before the original can vanish — see [_cacheMissingThumbnails].
    await _cacheMissingThumbnails();
    // A handful of photos at a time, and only once nothing else wants the
    // phone — so the Optimize Storage page is usually already answered by
    // the time anybody opens it. On the page it runs flat out instead.
    try {
      await _storageAdvisor.sweep();
    } catch (_) {
      // No photo library to measure against — nothing owed here.
    }
  }

  /// Gives a cached thumbnail to photos that haven't got one — see
  /// [needingThumbnails] for which those are and why they matter.
  ///
  /// The cache used to be a side effect of the `uploadThumbnail` job and
  /// nothing else, so a photo whose job never ran — turned away by a full
  /// queue, or its file unreadable that once — simply never had a picture
  /// of itself on disk, and nothing ever asked again. A thumbnail has to
  /// be there before it is needed, which makes it the library's business
  /// rather than the upload queue's.
  ///
  /// One that keeps failing ([ThumbnailTries]) is left until the camera roll
  /// is re-read, and the library reloads only when one was made: a few
  /// that never resolve no longer cost a reload every round.
  Future<void> _cacheMissingThumbnails() async {
    final failing = _thumbnailTries.givenUp;
    final owed = needingThumbnails(
      _all,
      skip: failing.isEmpty ? _unresolvable : {..._unresolvable, ...failing},
    );
    if (owed.isEmpty) return;
    var made = false;
    for (final record in owed) {
      if (!mounted) return;
      if (await _cacheThumbnail(record)) {
        made = true;
        _thumbnailTries.succeeded(record.localId);
      } else {
        _thumbnailTries.failed(record.localId);
      }
    }
    if (made && mounted) await reload();
  }

  /// This session's; cleared with [_unresolvable].
  final _thumbnailTries = ThumbnailTries();

  void _retryUnresolvable() {
    _unresolvable.clear();
    _thumbnailTries.clear();
  }

  Future<bool> _cacheThumbnail(AssetRecord record) async {
    try {
      // A video's poster frame comes from the library itself — exporting
      // the whole movie to make a picture of it would be absurd.
      if (record.isVideo) {
        return await _thumbnailCache.ensureFor(record) != null;
      }
      // PhotoKit's own picture; the full-size file only without one.
      if (await _engine.cacheThumbnail(record) == null) {
        _unresolvable.add(record.localId);
        return false;
      }
      return true;
    } catch (_) {
      // Unreadable, or gone since: tried again, up to [ThumbnailTries].
      return false;
    }
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
      // The same path an iOS deletion notification takes, so the same
      // gate: full access and a second lookup, or nothing. Backed up becomes
      // cloud-only, the rest goes to the bin; never a row deleted.
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

  /// Same people, same names, same order — the only things this screen
  /// draws them by.
  static bool _samePeople(List<Person> a, List<Person> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id || a[i].name != b[i].name) return false;
    }
    return true;
  }

  /// Photos deleted for good leave their album and people rows behind —
  /// those live in other databases. Dropped here, one batch per store. An
  /// id that has a record again (restored from a snapshot) is spared.
  /// Whether [sweepOrphanMemberships] has run (or found nothing to do)
  /// this session — so reloads don't re-read its done-flag every time.
  var _orphansSwept = false;

  Future<void> _forgetRemovedMemberships(List<AssetRecord> all) async {
    final removed = await assetRecordStore.removedIds();
    if (removed.isEmpty) return;
    final present = {
      for (final record in all)
        if (removed.contains(record.localId)) record.localId,
    };
    final gone = removed.difference(present);
    try {
      // A copy record merged into the one that took its asset over: its
      // albums and people move there first.
      final merged = {
        for (final MapEntry(:key, :value)
            in (await assetRecordStore.mergedInto()).entries)
          if (gone.contains(key)) key: value,
      };
      if (merged.isNotEmpty) {
        Future<void> move(
          Map<String, List<String>> members,
          Future<void> Function(String id, List<String> into) add,
        ) async {
          for (final MapEntry(key: id, value: ids) in members.entries) {
            final into = [for (final from in ids) ?merged[from]];
            if (into.isNotEmpty) await add(id, into);
          }
        }

        await move(await _albumStore.allMemberships(), _albumStore.addAssets);
        await move(
          await _personStore.allMemberships(),
          (id, into) => _personStore.addAssets(id, into, fillAvatar: false),
        );
      }
      if (gone.isNotEmpty) {
        await _albumStore.forgetAssets(gone);
        await _personStore.forgetAssets(gone);
        try {
          await _aiAnalysisStore.forgetAssets(gone);
        } catch (_) {
          // No analysis database: nothing kept about them.
        }
      }
      await assetRecordStore.forgetRemoved(removed);
    } catch (_) {
      // Kept for the next reload; a stale membership draws nothing.
    }
  }

  /// Faces of photos hidden before hiding dropped them, or restored with
  /// them. Once per session: one pass, and a no-op once clean.
  var _hiddenFacesSwept = false;

  Future<void> _sweepHiddenFaces(List<AssetRecord> all) async {
    _hiddenFacesSwept = true;
    final hidden = [
      for (final r in all)
        if (r.isHidden || r.passcodeHash != null) r.localId,
    ];
    try {
      await _aiAnalysisStore.forgetFacesOf(hidden);
    } catch (_) {
      // No analysis database: nothing kept about them.
    }
  }

  Future<void>? _reloading;
  Future<void>? _reloadQueued;
  bool _queuedFaces = false;
  bool? _queuedStatusOnly;

  /// [faces] forces the strangers row to be worked out again — for a
  /// caller that knows the analysis database moved under it. [statusOnly]
  /// is a caller that wrote nothing but upload state (a drain ending):
  /// unless the library says otherwise, albums, people and faces are left
  /// as they are.
  ///
  /// One at a time, and at most one more behind it that every caller
  /// arriving meanwhile shares: two running together could finish out of
  /// order and put the older library back on screen. What it awaits has
  /// read the library after the call was made.
  Future<void> reload({bool faces = false, bool statusOnly = false}) {
    _queuedFaces = _queuedFaces || faces;
    _queuedStatusOnly = (_queuedStatusOnly ?? true) && statusOnly;
    final queued = _reloadQueued;
    if (queued != null) return queued;
    final running = _reloading;
    if (running == null) return _startReload();
    final next = running.catchError((Object _) {}).then((_) {
      _reloadQueued = null;
      return _startReload();
    });
    return _reloadQueued = next;
  }

  Future<void> _startReload() {
    final faces = _queuedFaces;
    final statusOnly = _queuedStatusOnly ?? false;
    _queuedFaces = false;
    _queuedStatusOnly = null;
    late final Future<void> run;
    run = _reloadOnce(faces: faces, statusOnly: statusOnly).whenComplete(() {
      if (identical(_reloading, run)) _reloading = null;
    });
    return _reloading = run;
  }

  Future<void> _reloadOnce({
    required bool faces,
    required bool statusOnly,
  }) async {
    final firstLoad = !_loaded;
    if (firstLoad) await _paintNewest();
    if (firstLoad) await _paintLastCollections();
    final all = await assetRecordStore.listAll();
    // The same list instance back means the library itself hasn't moved
    // (see [AssetRecordStore.listAll]) — so everything derived from it is
    // still good, down to the grid's own layout, which memoises on the
    // identity of the list it was given.
    final libraryChanged = !identical(all, _all);
    final delta = libraryDelta(firstLoad ? null : _all, all);
    // What moved since the last list, record by record, when the store
    // can say: the derived lists below are patched by it, not redone.
    final changes = firstLoad || !libraryChanged
        ? null
        : assetRecordStore.changesBetween(_all, all);
    final small = changes != null && changes.length <= LibraryIndex.patchLimit;
    final index = libraryChanged || firstLoad
        ? LibraryIndex.after(
            firstLoad ? null : _index,
            all,
            changes,
            DateTime.now(),
          )
        : null;
    final active = index?.active ?? _active;

    // The photos are in, and on the first load they are the whole reason
    // the app was opened. Everything below this reads three more
    // databases — every album's members, every person's, and a face pass
    // over every analysis — which is a second or two on a real library,
    // and the grid used to spend all of it blank. Put the grid up now and
    // let the rest land in the second paint.
    if (firstLoad) {
      if (!mounted) return;
      setState(() {
        _loaded = true;
        _applyLibrary(index!);
      });
    } else if (statusOnly && !delta.shape && !faces) {
      // Only upload state moved (a backup queued or landed): the tiles
      // need the new records, nothing else on the page does.
      if (!mounted) return;
      if (index != null) setState(() => _applyLibrary(index));
      return;
    }

    if (libraryChanged) await _forgetRemovedMemberships(all);
    if (!_hiddenFacesSwept) await _sweepHiddenFaces(all);
    if (!_orphansSwept) {
      _orphansSwept = true;
      try {
        final swept = await sweepOrphanMemberships(
          assetRecordStore: assetRecordStore,
          albumStore: _albumStore,
          personStore: _personStore,
        );
        // Not run (restore under way, nothing scanned yet): next launch.
        if (swept == null) _orphansSwept = false;
      } catch (_) {
        // A stale membership draws nothing; try again next reload.
        _orphansSwept = false;
      }
    }

    // Albums and memberships are re-read only when their database was
    // written since the last read (its stamp moved). The stamp is read
    // first: a write landing after it shows here as data newer than the
    // stamp, and the next reload reads again.
    final albumStamp = await _albumStore.changeStamp();
    final albumsMoved = albumStamp != _albumStamp;
    var albums = _albums;
    var albumsOf = _albumsOf;
    if (albumsMoved) {
      albums = await _albumStore.listAll();
      final albumMembers = await _albumStore.allMemberships();
      albumsOf = <String, List<String>>{};
      for (final album in albums) {
        for (final localId in albumMembers[album.id] ?? const <String>[]) {
          albumsOf.putIfAbsent(localId, () => []).add(album.id);
        }
      }
    }
    // Same memberships and library: the lists stand. Same memberships and
    // a few records changed: only albums holding one of them change.
    final albumAssets = !albumsMoved && index == null
        ? _albumAssets
        : (!albumsMoved && small
                  ? patchAlbumRecords(_albumAssets, albumsOf, changes)
                  : null) ??
              albumRecordsOf([for (final a in albums) a.id], albumsOf, active);
    final builtInCovers = await _loadBuiltInCovers();

    final personStamp = await _personStore.changeStamp();
    final personsMoved = personStamp != _personStamp;
    final read = personsMoved ? await _personStore.listAll() : _people;
    var people = read;
    if (personsMoved) _personMembers = await _personStore.allMemberships();
    final personMembers = _personMembers;
    // Counts and first photos move with the memberships, or with a tagged
    // photo shown, hidden, added or removed. A heart, an upload or a scan
    // page of new photos moves neither.
    final tagged = personsMoved
        ? {for (final p in people) ...?personMembers[p.id]}
        : _tagged;
    final countsStale =
        personsMoved ||
        faces ||
        (libraryChanged && (!small || movesAnyOf(tagged, changes)));
    var personPhotoCounts = _personPhotoCounts;
    var personFirstPhotos = _personFirstPhotos;
    if (countsStale) {
      final counts = <String, int>{};
      final firsts = <String, String>{};
      // Visible ones only: a hidden photo in a count gives it away.
      final visible = visibleIdsOf(all);
      for (final person in people) {
        final localIds = personMembers[person.id] ?? const <String>[];
        final shown = localIds.where(visible.contains);
        counts[person.id] = shown.length;
        if (shown.firstOrNull case final first?) firsts[person.id] = first;
      }
      personPhotoCounts = counts;
      personFirstPhotos = firsts;
    }
    // In the order People is in. Re-sorted only when what it sorts by can
    // have moved: one pass over memberships, not per frame.
    final sort = await loadPeopleSort(assetRecordStore);
    if (countsStale || sort != _peopleSort) {
      final dated = sort == PeopleSort.firstMet || sort == PeopleSort.lastSeen;
      final dates = dated
          ? knownDates(
              people,
              personMembers,
              visibleRecordsOf(all),
              await _personStore.openEventSpans(),
              chats: await latestChats(_conversations),
            )
          : null;
      final sorted = [...people];
      sortPeople(
        sorted,
        sort,
        counts: personPhotoCounts,
        messages: sort == PeopleSort.messages
            ? await messageCounts(_conversations)
            : const {},
        firstKnown: dates?.first ?? const {},
        lastKnown: dates?.last ?? const {},
      );
      if (!_samePeople(sorted, people) || !identical(people, _people)) {
        people = sorted;
      }
      _peopleSort = sort;
    }
    if (!mounted) return;
    _albumStamp = albumStamp;
    _albumsOf = albumsOf;
    _personStamp = personStamp;
    _tagged = tagged;
    final same =
        _loaded &&
        index == null &&
        identical(albums, _albums) &&
        identical(albumAssets, _albumAssets) &&
        mapEquals(builtInCovers, _builtInCovers) &&
        identical(people, _people) &&
        identical(personPhotoCounts, _personPhotoCounts);
    if (same) return;
    setState(() {
      _loaded = true;
      if (index != null && !firstLoad) _applyLibrary(index);
      _albums = albums;
      _albumAssets = albumAssets;
      _builtInCovers = builtInCovers;
      _people = people;
      _personPhotoCounts = personPhotoCounts;
      _personFirstPhotos = personFirstPhotos;
      _earlyAlbumCounts = null;
      _earlyPeople = false;
    });
    _rememberCollections();
  }

  /// Last launch's rows, until the first full reload replaces them.
  Map<String, int>? _earlyAlbumCounts;
  bool _earlyPeople = false;
  String? _summaryWritten;

  /// People and Albums as they were last time, straight after the newest
  /// photos: the full read they otherwise wait for is most of a second.
  Future<void> _paintLastCollections() async {
    try {
      final text = await assetRecordStore.getAppState(HomeSummary.appStateKey);
      final summary = HomeSummary.decode(text);
      if (summary == null) return;
      _summaryWritten = text;
      final albums = await _albumStore.listAll();
      final people = await _personStore.listAll();
      final covers = await assetRecordStore.getVisibleByLocalIds(
        summary.albumCovers.values,
      );
      final rank = {for (final (i, id) in summary.people.indexed) id: i};
      final known = [
        for (final p in people)
          if (rank.containsKey(p.id)) p,
      ]..sort((a, b) => rank[a.id]!.compareTo(rank[b.id]!));
      if (!mounted || _personStamp != null) return;
      setState(() {
        _albums = albums;
        _albumAssets = {
          for (final a in albums)
            if (covers[summary.albumCovers[a.id]] case final cover?)
              a.id: [cover],
        };
        _earlyAlbumCounts = summary.albumCounts;
        _people = known;
        _personPhotoCounts = summary.personCounts;
        _personFirstPhotos = summary.personFirsts;
        _earlyPeople = true;
      });
    } catch (_) {
      // The full reload draws them a moment later.
    }
  }

  void _rememberCollections() {
    String? coverOf(Album album, List<AssetRecord> records) {
      if (records.isEmpty) return null;
      final chosen = album.coverLocalId;
      if (chosen != null && records.any((r) => r.localId == chosen)) {
        return chosen;
      }
      return records.last.localId;
    }

    final text = HomeSummary(
      people: [for (final p in _people) p.id],
      personCounts: _personPhotoCounts,
      personFirsts: _personFirstPhotos,
      albumCounts: {
        for (final a in _albums) a.id: _albumAssets[a.id]?.length ?? 0,
      },
      albumCovers: {
        for (final a in _albums)
          a.id: ?coverOf(a, _albumAssets[a.id] ?? const []),
      },
    ).encode();
    if (text == _summaryWritten) return;
    _summaryWritten = text;
    unawaited(
      assetRecordStore
          .setAppState(HomeSummary.appStateKey, text)
          .catchError((_) {}),
    );
  }

  /// What the last [reload] read albums and people at (see
  /// `changeStamp`), and what it derived from them.
  Object? _albumStamp;
  Map<String, List<String>> _albumsOf = const {};
  Object? _personStamp;
  PeopleSort? _peopleSort;
  Map<String, List<String>> _personMembers = const {};
  Set<String> _tagged = const {};

  /// Enough for the first screenful or two, a few milliseconds to read.
  static const _firstPaintCount = 600;

  /// The newest photos, up before the first full read of a big library is
  /// in. Older ones land above the viewport, which [AssetGridView] holds
  /// its place against. A subset in [_all] for that moment: everything
  /// reading it then only does less (fewer uploads queued, fewer
  /// thumbnails owed), never more.
  Future<void> _paintNewest() async {
    try {
      final newest = await assetRecordStore.listNewest(_firstPaintCount);
      if (newest.isEmpty || !mounted || _loaded) return;
      setState(() {
        _loaded = true;
        _applyLibrary(LibraryIndex.of(newest, DateTime.now()));
      });
    } catch (_) {
      // The full read below says what is wrong.
    }
  }

  /// Everything the screen derives from the library itself — a pass over
  /// the whole of it each, which is why they are held rather than read in
  /// `build`. Call inside [setState].
  void _applyLibrary(LibraryIndex index) {
    _index = index;
    _all = index.all;
    _active = index.active;
    _home = index.home;
    _archived = index.archived;
    _videos = index.videos;
    _favorites = index.favorites;
    _recentlyAdded = index.recentlyAdded;
    _places = index.places;
    _deletedCount = index.deletedCount;
  }

  void _openGroup(String title, List<AssetRecord> records) => _push(
    AssetGroupScreen(
      title: title,
      records: records,
      assetRecordStore: assetRecordStore,
    ),
  );

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

  Set<String> get _triedAndFailed => _engine.triedAndFailed;
  Set<String> get _unresolvable => _engine.unresolvable;

  /// Everything given up on gets another go — this is somebody deciding to
  /// retry, which is the whole point of the button.
  void _forgetFailures() {
    _engine.forgetFailures();
    _thumbnailTries.clear();
  }

  /// Bucket objects a hide has to take back out. Drained on every sync,
  /// kept until they actually land.
  late final PendingDeletes _pendingDeletes = PendingDeletes(
    store: assetRecordStore,
  );

  /// Private albums their owner has kept off the network, by passcode
  /// hash. Re-read on every [reload], which is what coming back from
  /// `PrivateAlbumScreen` does, so flipping the switch there takes effect

  List<AssetRecord> get _pendingAndFailed => _engine.pendingAndFailed;

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

  Future<bool> _hasBackupTarget() => _engine.hasBackupTarget();

  /// What a carrier can pretend to be: ordinary photos this phone still
  /// holds, with their real file sizes.
  ///
  /// Sampled rather than exhaustive — on a real library, stat-ing every
  /// record to pick one decoy would be thousands of syscalls for a single
  /// upload. Sixty is plenty to find something within a few percent of any
  /// given size.
  ///
  /// Only originals already on the phone, and drawn once per half hour
  /// rather than per carrier: resolving sixty random camera-roll files
  /// downloads whichever of them iCloud has offloaded, and doing that for
  /// every hidden photo is what stalled the sync behind them.
  Future<List<DecoyCandidate>> _decoyCandidates() {
    final drawn = _decoyDrawnAt;
    if (drawn != null &&
        DateTime.now().difference(drawn) < const Duration(minutes: 30)) {
      return _decoyPool!;
    }
    _decoyDrawnAt = DateTime.now();
    return _decoyPool = _drawDecoyCandidates()
        .then((found) {
          // Nothing found isn't worth keeping for half an hour.
          if (found.isEmpty) _decoyDrawnAt = null;
          return found;
        })
        .catchError((Object _) {
          _decoyDrawnAt = null;
          return <DecoyCandidate>[];
        });
  }

  Future<List<DecoyCandidate>>? _decoyPool;
  DateTime? _decoyDrawnAt;

  Future<String?> _localPathFor(AssetRecord record) async {
    if (record.localDeleted) return null;
    if (record.sourceType != AssetSourceType.photoManager) {
      final path = record.sourcePath;
      return path != null && await File(path).exists() ? path : null;
    }
    return (await _photoLibraryService.localFileFor(record))?.path;
  }

  Future<List<DecoyCandidate>> _drawDecoyCandidates() async {
    final pool = [
      for (final r in _all)
        if (r.passcodeHash == null &&
            r.deletedAt == null &&
            !r.localDeleted &&
            r.width != null &&
            r.height != null)
          r,
    ]..shuffle();

    final candidates = <DecoyCandidate>[];
    for (final record in pool.take(120)) {
      if (candidates.length == 60) break;
      final path = await _localPathFor(record);
      if (path == null) continue;
      int size;
      try {
        size = await File(path).length();
      } catch (_) {
        continue;
      }
      candidates.add(
        DecoyCandidate(
          source: DecoySource(
            id: record.localId,
            sizeBytes: size,
            width: record.width!,
            height: record.height!,
            takenAt: record.createdAt,
            isVideo: record.countsAsVideo,
          ),
          duration: record.countsAsVideo
              ? await _photoLibraryService.durationOf(record)
              : null,
          // Made on demand for the one picked, if it has none cached yet.
          thumbnail: () async {
            try {
              final thumb =
                  record.thumbnailPath ??
                  await _thumbnailCache.ensureFor(record, path);
              return thumb == null ? null : await File(thumb).readAsBytes();
            } catch (_) {
              return null;
            }
          },
        ),
      );
    }
    return candidates;
  }

  /// Hidden photos filed with no bucket, and an index the buckets haven't
  /// got, sent with no album open. Best-effort: still marked if it fails.
  Future<void> _sendUnsentCarriers() async {
    try {
      if (!await _hasBackupTarget()) return;
      // Every install, hidden albums or not: first contact with a bucket
      // leaves an index carrying this phone's passphrase entries.
      await _vaultBucket.ensurePublished(await _vaultKeys.entries());
      if (await _vaultStore.isIndexUnpublished()) {
        final local = await _vaultStore.readIndex();
        if (local != null) await _vaultBucket.pushIndex(local);
      }
      await _vaultStore.sendUnsent(
        outboxKey: _vaultKeys.outboxKey,
        put: _vaultBucket.putEverywhere,
      );
    } catch (_) {
      // Retried on the next sync.
    }
  }

  late final ShareInbox _shareInbox = ShareInbox(store: assetRecordStore);
  bool _offeringShared = false;

  /// What was shared to the app from Safari or elsewhere — always for a
  /// hidden album. Batches whose code was typed in the share sheet are
  /// filed quietly; loose ones are offered: a hidden album, or later.
  Future<void> _offerShared() async {
    if (_offeringShared || !mounted) return;
    _offeringShared = true;
    try {
      final filed = await _shareInbox.fileBatches(
        tagFor: PasscodeTags(records: assetRecordStore).tagFor,
      );
      if (filed.isNotEmpty) {
        // Their encrypted copies only; never the plain upload path.
        unawaited(_hiddenBackup.run().catchError((_) {}));
        await reload();
      }
      if (!mounted) return;
      final waiting = (await _shareInbox.pending()).length;
      if (waiting == 0 || !mounted) return;
      final l10n = AppLocalizations.of(context)!;
      final hide = await showCupertinoModalPopup<bool>(
        context: context,
        builder: (context) => CupertinoActionSheet(
          title: Text(l10n.shareInboxTitle(waiting)),
          message: Text(l10n.shareInboxBody),
          actions: [
            CupertinoActionSheetAction(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(l10n.shareInboxToHidden),
            ),
          ],
          cancelButton: CupertinoActionSheetAction(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l10n.shareInboxLater),
          ),
        ),
      );
      if (hide == null || !mounted) return;
      final passcode = await askHideCode(context);
      if (passcode == null) return;
      final hash = await PasscodeTags(records: assetRecordStore)
          .tagFor(passcode);
      final hidden = await _shareInbox.file(passcodeHash: hash);
      // Their encrypted copies only; never the plain upload path.
      unawaited(_hiddenBackup.run().catchError((_) {}));
      await reload();
      if (mounted) _showResult(l10n.shareInboxHidden(hidden.length));
    } finally {
      _offeringShared = false;
    }
  }

  /// Old passcode tags upgraded, hidden plain files moved under
  /// `vault/plain/`, and (once) plaintext thumbnails of hidden photos gone.
  /// Each resumable; each bounded by the hidden rows, not the library.
  Future<void> _secureHiddenAtRest() async {
    try {
      await PasscodeTags(
        records: assetRecordStore,
        people: _personStore,
        vaultKeys: _vaultKeys,
      ).upgradeLegacy();
    } catch (_) {}
    try {
      await PlainFiles(store: assetRecordStore).settleAll();
    } catch (_) {}
    try {
      const swept = 'hidden_thumbnails_swept_v1';
      if (await assetRecordStore.getAppState(swept) == null) {
        await _thumbnailCache.sweepHidden(
          await assetRecordStore.hiddenRecords(),
        );
        await assetRecordStore.setAppState(swept, '1');
      }
    } catch (_) {}
  }

  Future<void> _finishTransitions() async {
    try {
      await HiddenTransition(
        store: assetRecordStore,
        loadTargets: _backupTargetsStore.loadAll,
        pendingDeletes: _pendingDeletes,
        analysisStore: _aiAnalysisStore,
        thumbnails: _thumbnailCache,
      ).resume();
    } catch (_) {
      // Still journaled; the next launch tries again.
    }
  }

  /// Best-effort and unawaited: a delete that cannot land today is still
  /// on the list tomorrow.
  Future<void> _drainPendingDeletes() async {
    try {
      final targets = await _backupTargetsStore.loadAll();
      // Un-hidden photos' carriers, now that their plain copy is up; hidden
      // ones' plain copies, now that their carrier is.
      await DeferredDeletes(
        store: assetRecordStore,
        pending: _pendingDeletes,
      ).release(targets);
      await DeferredDeletes.untilCarrier(
        store: assetRecordStore,
        pending: _pendingDeletes,
      ).release(targets);
      await _pendingDeletes.drain(targets);
      await _removal.expireBin();
    } catch (_) {
      // Nothing to report — the tasks stay queued.
    }
  }

  /// New photos on screen first; queueing their backup is a few writes
  /// each, and the grid used to wait for all of them. No second reload:
  /// the drain's own, when it ends, shows their backup status.
  Future<void> _showThenBackUp(List<AssetRecord> added) async {
    await reload();
    if (added.isEmpty || !mounted) return;
    // Read again: on screen, a photo can be hidden before it's queued.
    final fresh = await assetRecordStore.getByLocalIds(
      added.map((r) => r.localId),
    );
    await _backUpRecords(fresh.values.toList());
  }

  Future<int> _backUpRecords(List<AssetRecord> records) =>
      _engine.backUpRecords(records);

  /// Hidden photos never go through the queue. Older builds queued them,
  /// and their rows — even finished ones, even nameless — said on an open
  /// page that hidden photos exist; they're dropped before it loads.
  Future<void> _resumeQueue() async {
    await _forgetHiddenJobs();
    await syncQueue.resume(
      drain: true,
      runningSince: await BackgroundHeartbeat(assetRecordStore).runningSince(),
    );
  }

  /// Queued jobs for photos hidden since: dropped before anything can show
  /// the queue, even when its resume waits for the screen to settle.
  Future<void> _forgetHiddenJobs() async {
    try {
      await syncQueue.store.forget([
        for (final r in await assetRecordStore.listAll())
          if (r.passcodeHash != null || r.isHidden) r.localId,
      ]);
    } catch (_) {
      // The queue shows them until the next launch; nothing is lost.
    }
  }

  /// Opportunistic: fires whenever the app (or this screen) comes to the
  /// foreground. While backgrounded, iOS may also run a background pass —
  /// see `../upload/background_sync.dart` — at a time of its own choosing.
  Future<void> _runScheduledSyncIfDue() async {
    try {
      final lastSyncAt = await _backupTargetsStore.getLastSyncAt();
      if (!isSyncDue(
        frequency: autoSyncFrequency,
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

  Future<int> _enqueueChangeChecks() => _engine.enqueueChangeChecks();

  /// The one entry point "Sync Now" and the scheduled due-check both go
  /// through. Queues the work and returns — nothing is uploaded on this
  /// call stack; [syncQueue] drains it. Returns how many jobs are now
  /// outstanding.
  Future<void> _repairBackupsIfDue() async {
    try {
      if (await _backupVerifier.repairIfDue() == 0 || !mounted) return;
      await reload();
      await _backUpRecords(_pendingAndFailed);
    } catch (_) {
      // Tomorrow's sync asks again.
    }
  }

  Future<int> _syncEverything() async {
    // "Sync Now" means now. A paused queue takes nothing new (deliberately
    // — see [SyncQueue.enqueue]), so honouring the pause here would make
    // the button do nothing at all and say nothing about why.
    await syncQueue.setPaused(false);
    // Objects a hide left behind. These never expire and are retried on
    // every sync: hiding happens offline constantly, and a plain copy left
    // in a bucket does not stop being a plain copy.
    unawaited(_drainPendingDeletes());
    unawaited(_sendUnsentCarriers());
    unawaited(_backupVerifier.spotCheck().then((_) {}, onError: (_) {}));
    unawaited(RecordFixer.checkImports(assetRecordStore).catchError((_) {}));
    unawaited(_repairBackupsIfDue());
    _forgetFailures();
    // New photos first: they have no copy anywhere yet.
    await _backUpRecords(_pendingAndFailed);
    await _enqueueChangeChecks();
    try {
      await _backupTargetsStore.setLastSyncAt(DateTime.now());
    } catch (_) {
      // Secure storage unavailable — the next due-check just runs again
      // sooner than strictly necessary.
    }
    unawaited(syncQueue.start());
    return syncQueue.jobs.value.where((job) => !job.isFinished).length;
  }

  Future<String?> _filePathFor(AssetRecord record) =>
      _engine.filePathFor(record);

  /// No full-size render for Vision: see [SyncEngine.visionSourceFor].
  Future<String?> _visionSourceFor(AssetRecord record) =>
      _engine.visionSourceFor(record);

  /// Backs up [records] (whatever this action just added) plus anything
  /// else still pending/failed from before — an import of content already
  /// present is a no-op add (deduped by hash), so on its own it would
  /// never retry photos still sitting pending from before a bucket was
  /// configured.
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

  Future<void> _toggleFavorite(AssetRecord record) async {
    await setFavoriteEverywhere(assetRecordStore, record, !record.isFavorite);
    await reload();
  }

  Future<void> _toggleArchive(AssetRecord record) =>
      _setArchived([record], !record.isArchived);

  Future<void> _setArchived(List<AssetRecord> records, bool value) async {
    if (records.isEmpty) return;
    await assetRecordStore.setArchived(records.map((r) => r.localId), value);
    if (!mounted) return;
    if (_selecting) setState(() => _selection = null);
    await reload();
    if (!mounted) return;
    final l10n = AppLocalizations.of(context)!;
    _showResult(
      value
          ? l10n.archiveDone(records.length)
          : l10n.archiveUndone(records.length),
    );
  }

  Future<void> _batchArchive() => _setArchived(_selectedRecords, true);

  /// Hiding takes the photo out of Photos as well — otherwise "hidden"
  /// would only mean hidden from this app, and the camera roll would still
  /// open on it. The copy into this app's own storage happens first, so
  /// there's never a moment where the only copy is the one being deleted.
  Future<void> _hide(AssetRecord record) async {
    await _hideRecords([record]);
  }

  /// Stays on the library afterwards — see [hideIntoPrivateAlbum].
  Future<bool> _hideRecords(List<AssetRecord> records) async {
    if (records.isEmpty) return false;
    setState(() => _busy = true);
    var hidden = false;
    try {
      hidden = await hideIntoPrivateAlbum(
        context,
        assetRecordStore: assetRecordStore,
        records: records,
        custody: _custody,
        targetsStore: _backupTargetsStore,
        analysisStore: _aiAnalysisStore,
        onSettled: () {
          if (mounted) reload();
        },
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    await reload();
    return hidden;
  }

  Future<void> _batchHide() async {
    if (await _hideRecords(_selectedRecords) && mounted) {
      setState(() => _selection = null);
    }
  }

  /// Into the analyzer behind whatever it's doing; nothing to watch.
  void _batchAnalyzeFaces() {
    final ids = [
      for (final r in _selectedRecords)
        if (!r.isVideo && r.passcodeHash == null) r.localId,
    ];
    _faceAnalyzer.add(ids);
    setState(() => _selection = null);
    _showResult(AppLocalizations.of(context)!.analyzeFacesStarted(ids.length));
  }

  Future<void> _batchResize() async {
    final stills = [
      for (final r in _selectedRecords)
        if (!r.countsAsVideo && !r.localDeleted) r,
    ];
    final created = await resizePhotos(
      context,
      records: stills,
      readBytes: (r) async {
        final path = await _filePathFor(r);
        return path == null ? null : File(path).readAsBytes();
      },
      saveCopy: (source, bytes, extension) => createDerivedAsset(
        source: source,
        bytes: bytes,
        extension: extension,
        keepMotion: true,
        store: assetRecordStore,
        personStore: _personStore,
      ),
      replaceOriginals: (originals) =>
          _batchDelete(only: originals, ask: false),
    );
    if (created.isNotEmpty && mounted) {
      setState(() => _selection = null);
      await reload();
    }
  }

  /// Returns whether the asset left the library — false for a
  /// remove-from-device, which deliberately keeps it there (cloud-only), so
  /// the detail viewer stays open on it rather than popping.
  Future<bool> _softDelete(AssetRecord record) async {
    final l10n = AppLocalizations.of(context)!;
    // The lock's first promise. Checked here rather than only on the tile,
    // because this is also what the detail screen's Delete calls.
    if (record.isLocked) {
      _showResult(l10n.lockBlockedDelete);
      return false;
    }
    setState(() => _busy = true);
    final DeleteOutcome outcome;
    try {
      outcome = await deleteAsset(context, record: record, removal: _removal);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    await reload();
    if (mounted) {
      switch (outcome) {
        case DeleteOutcome.failed:
          _showResult(l10n.libraryDeleteFromDeviceFailed);
        case DeleteOutcome.backupMissing:
          _showResult(l10n.libraryDeleteBackupMissing);
        case DeleteOutcome.backupUnverifiable:
          _showResult(l10n.libraryDeleteBackupUnverifiable);
        case DeleteOutcome.keptByPhotos:
          _showResult(l10n.libraryDeleteKeptByPhotos(1));
        case DeleteOutcome.none:
        case DeleteOutcome.cloudOnly:
        case DeleteOutcome.binned:
        case DeleteOutcome.deleted:
          break;
      }
    }
    return outcome.leftTheList;
  }

  /// The batch form. The bucket copy is deliberately *not* touched: this
  /// app's Recently Deleted has to be restorable to mean anything, and the
  /// backed-up copy is the one that survives a lost phone — it's purged
  /// only when the user empties that bin (see
  /// `recently_deleted_screen.dart`).
  Future<Set<String>> _deleteManyFromLibrary(List<AssetRecord> records) async {
    try {
      return await _photoLibraryService.deleteManyFromLibrary(
        records,
        missingCountsAsDeleted: true,
      );
    } catch (_) {
      // No plugin, or they're already out of the library — either way
      // there's nothing over there left to delete.
      return {for (final record in records) record.localId};
    }
  }

  List<TileAction> _actionsFor(AssetRecord record) {
    final l10n = AppLocalizations.of(context)!;
    return [
      TileAction(
        icon: record.isFavorite
            ? CupertinoIcons.heart_slash
            : CupertinoIcons.heart,
        label: record.isFavorite
            ? l10n.libraryUnfavorite
            : l10n.libraryFavorite,
        onPressed: () => _toggleFavorite(record),
      ),
      TileAction(
        icon: CupertinoIcons.rectangle_stack_badge_plus,
        label: l10n.albumAddToAction,
        onPressed: () => _addToAlbum([record]),
      ),
      TileAction(
        icon: CupertinoIcons.archivebox,
        label: l10n.archiveAction,
        onPressed: () => _toggleArchive(record),
      ),
      TileAction(
        icon: CupertinoIcons.eye_slash,
        label: l10n.libraryHide,
        onPressed: () => _hide(record),
      ),
      TileAction(
        icon: record.isLocked ? CupertinoIcons.lock_open : CupertinoIcons.lock,
        label: record.isLocked ? l10n.libraryUnlock : l10n.libraryLock,
        onPressed: () => _toggleLock(record),
      ),
      // Offered even on a locked photo, and it says why rather than going
      // missing: a Delete that quietly isn't there reads as a bug, and the
      // lock is worth explaining at the moment it stops something.
      TileAction(
        icon: CupertinoIcons.delete,
        label: l10n.libraryDeleteTooltip,
        isDestructive: true,
        onPressed: () => _softDelete(record),
      ),
    ];
  }

  /// Locking is a promise that this photo is being kept as it is, so it
  /// cannot be made over a copy that has already been shrunk or thrown
  /// away — the original comes back from the bucket first, and if it
  /// can't, nothing is locked and the reason is shown. Unlocking is free.
  Future<void> _toggleLock(AssetRecord record) async {
    final l10n = AppLocalizations.of(context)!;
    if (record.isLocked) {
      await assetRecordStore.setLocked(record.localId, false);
      await reload();
      return;
    }
    if (record.localDeleted || record.localOptimized) {
      if (record.stateOf(DerivativeKind.original).destinationKey == null) {
        _showResult(l10n.lockNoOriginal);
        return;
      }
      setState(() => _busy = true);
      String? restored;
      try {
        restored =
            await (widget.restoreOriginal ??
                    (r) => OriginalRestore(
                      targetsStore: BackupTargetsStore(),
                      recordStore: assetRecordStore,
                    ).restore(r))
                .call(record);
      } finally {
        if (mounted) setState(() => _busy = false);
      }
      if (restored == null) {
        if (mounted) _showResult(l10n.lockRestoreFailed);
        return;
      }
    }
    await assetRecordStore.setLocked(record.localId, true);
    await reload();
  }

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
    final visible = _home;
    // Opened from the queue, the photo may not be in the current grid at
    // all — hidden or deleted. Show it on its
    // own rather than dropping the tap or, worse, indexing at -1.
    final sorted = indexInOrder(visible, record);
    final index = sorted >= 0
        ? sorted
        : visible.indexWhere((r) => r.localId == record.localId);
    final records = index >= 0 ? visible : [record];
    await Navigator.of(context).push(
      ZoomPageRoute(
        builder: (_) => DetailScreen(
          records: records,
          initialIndex: index >= 0 ? index : 0,
          onDelete: _softDelete,
          onReplaceOriginals: (originals) =>
              _batchDelete(only: originals, ask: false),
          onToggleFavorite: _toggleFavorite,
          onToggleArchive: (r) =>
              assetRecordStore.setArchived([r.localId], !r.isArchived),
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
    // The finger is still down: dragging on from here selects the range
    // between this photo and wherever the finger goes.
    _sweep.begin(record.localId);
    _sweepFrom = record;
  }

  final _sweep = SelectSweep<String>();

  /// The tile the sweep began on: found again in the grid by its date.
  AssetRecord? _sweepFrom;

  void _onSelectDragUpdate(Offset globalPosition) {
    final selection = _selection;
    if (selection == null) return;
    final record = _recordUnder(globalPosition);
    if (record == null) return;
    if (!_sweep.active) _sweepFrom = record;
    final from = _sweepFrom;
    final grid = _home;
    // The grid is in [recordOrder]: two binary searches, no 40k index.
    // A tile re-dated under the finger isn't where its date says: looked
    // for by id, once.
    int find(AssetRecord r) {
      final at = indexInOrder(grid, r);
      return at >= 0 ? at : grid.indexWhere((g) => g.localId == r.localId);
    }

    int indexOf(String id) => switch (id) {
      _ when id == record.localId => find(record),
      _ when from != null && id == from.localId => find(from),
      _ => -1,
    };
    final next = _sweep.overSorted(
      record.localId,
      selection,
      indexOf: indexOf,
      keyAt: (i) => grid[i].localId,
    );
    if (next != null) _select(next);
  }

  void _onSelectDragEnd() {
    _sweep.end();
    _sweepFrom = null;
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

  void _toggleSelected(AssetRecord record) {
    final next = {..._selection!};
    next.contains(record.localId)
        ? next.remove(record.localId)
        : next.add(record.localId);
    _select(next);
  }

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
  /// [only] with [ask] false is "delete the originals" after an export,
  /// which has already asked.
  Future<void> _batchDelete({List<AssetRecord>? only, bool ask = true}) async {
    var records = only ?? _selectedRecords;
    if (records.isEmpty) return;
    final l10n = AppLocalizations.of(context)!;
    // iOS lists every photo of a single delete call in one sheet, and past
    // a hundred thumbnails that sheet is not something anyone reads. The
    // overflow stays selected for a second round rather than going unseen
    // with the rest.
    const limit = PhotoLibraryService.deleteBatchLimit;
    final locked = records.where((r) => r.isLocked).length;
    records = records.where((r) => !r.isLocked).toList();
    if (records.isEmpty) {
      if (locked > 0) _showResult(l10n.lockBlockedDelete);
      return;
    }
    final capped = records.length > limit;
    final batch = capped ? records.take(limit).toList() : records;
    if (ask) {
      final removable = batch.where(_removal.canRemoveFromDevice).toList();
      final choice = await chooseBatchDelete(
        context,
        count: batch.length,
        removable: removable.length,
        cloudOnly: batch.where((r) => r.localDeleted).length,
      );
      if (choice == DeleteChoice.cancel) return;
      if (choice == DeleteChoice.fromDevice) {
        await _batchRemoveFromDevice(removable);
        return;
      }
    }
    setState(() => _busy = true);
    var kept = 0;
    try {
      final fromLibrary = batch
          .where(
            (r) =>
                r.sourceType == AssetSourceType.photoManager &&
                !r.localDeleted &&
                r.libraryId != null,
          )
          .toList();
      // One OS prompt for the whole batch. Asking forty times isn't a
      // safeguard, it's a wall to click through.
      final gone = fromLibrary.isEmpty
          ? const <String>{}
          : await _deleteManyFromLibrary(fromLibrary);
      final needsLibrary = {for (final r in fromLibrary) r.localId};
      for (final record in batch) {
        // Declined at the OS prompt — leave that one alone rather than
        // binning it here and claiming it went from Photos too.
        if (needsLibrary.contains(record.localId) &&
            !gone.contains(record.localId)) {
          kept++;
          continue;
        }
        await _removal.binOrPurge(record);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;
    final left = {for (final r in records.skip(batch.length)) r.localId};
    setState(() => _selection = left.isEmpty ? null : left);
    await reload();
    if (!mounted) return;
    if (kept > 0) {
      _showResult(l10n.libraryDeleteKeptByPhotos(kept));
    } else if (capped) {
      _showResult(l10n.libraryDeleteBatchCapped(limit));
    }
  }

  /// Frees the device copy of each of [records] and keeps it in the library
  /// and the bucket. The bucket is asked once for the lot, and Photos
  /// prompts once — see [StorageOptimizer.apply]. Only backed-up photos get
  /// here; the rest of a selection is left as it was.
  Future<void> _batchRemoveFromDevice(List<AssetRecord> records) async {
    final l10n = AppLocalizations.of(context)!;
    setState(() => _busy = true);
    StorageFixResult result;
    try {
      result = await _storageOptimizer.apply([
        for (final r in records)
          StorageItem(
            record: r,
            bytes: 0,
            name: '',
            appOwned: r.sourcePath != null,
            issues: const {},
            fixes: const [StorageFix.removeFromDevice],
          ),
      ]);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;
    setState(() => _selection = null);
    await reload();
    if (!mounted) return;
    final removed = records.length - result.skipped - result.unverified;
    _showResult(
      [
        l10n.selectionRemovedFromDevice(removed),
        if (result.skipped > 0) l10n.storageResultSkipped(result.skipped),
        if (result.unverified > 0)
          l10n.storageResultUnverified(result.unverified),
      ].join('\n'),
    );
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
          query.isEmpty ? null : '${l10n.albumsNewTitle} "$query"',
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
    final trimmed = tag?.trim() ?? '';
    if (trimmed.isEmpty) return;
    for (final record in _selectedRecords) {
      if (record.tags.contains(trimmed)) continue;
      await assetRecordStore.setTags(record.localId, [...record.tags, trimmed]);
    }
    if (!mounted) return;
    setState(() => _selection = null);
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
      vaultKeys: _vaultKeys,
      libraryCount: _all.length,
    );
    await reload();
  }

  /// Unlike a plain [_push], always syncs on return — regardless of the
  /// configured sync frequency — since coming back from Cloud Backups
  /// usually means a target/setting just changed and shouldn't need a
  /// separate manual sync to take effect.
  void _openSafety() => _push(
    SafetyScreen(
      recordStore: assetRecordStore,
      targetsStore: _backupTargetsStore,
      verifier: _backupVerifier,
      icloudBackup: _icloudBackup,
      bucketBackup: _bucketBackup,
      libraryRestore: _libraryRestore,
      onRestored: () => unawaited(reload()),
      onAddBucket: _openCloudBackups,
    ),
  );

  Future<void> _pickLanguage() {
    final l10n = AppLocalizations.of(context)!;
    final current = AppStoreRegion.language.value;
    return showCupertinoModalPopup<void>(
      context: context,
      builder: (sheetContext) => CupertinoActionSheet(
        title: Text(l10n.collectionsLanguageRow),
        actions: [
          // Each in its own language, so it can be found from the wrong one.
          for (final (code, name) in [
            (null, l10n.languageSystem),
            ('en', 'English'),
            ('zh', '中文'),
          ])
            CupertinoActionSheetAction(
              isDefaultAction: code == current,
              onPressed: () {
                Navigator.of(sheetContext).pop();
                AppStoreRegion.setLanguage(code);
              },
              child: Text(name),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(sheetContext).pop(),
          child: Text(l10n.actionCancel),
        ),
      ),
    );
  }

  /// A separate, pre-filled library — see `../demo/demo_mode.dart`. The
  /// whole screen is rebuilt on the other side, so nothing here is touched
  /// after the switch.
  Future<void> _toggleDemoMode() async {
    setState(() => _busy = true);
    try {
      await DemoMode.setActive(!DemoFlag.active);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirmDemoReset() async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showCupertinoDialog<bool>(
      context: context,
      builder: (dialogContext) => CupertinoAlertDialog(
        title: Text(l10n.settingsDemoResetTitle),
        content: Text(l10n.settingsDemoResetBody),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.actionCancel),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.settingsDemoResetConfirm),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await DemoMode.reset();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openCloudBackups() async {
    await Navigator.of(context).push(
      CupertinoPageRoute(
        builder: (_) => SettingsScreen(
          store: _backupTargetsStore,
          assetRecordStore: assetRecordStore,
          icloudBackup: _icloudBackup,
        ),
      ),
    );
    // Gone if demo mode flipped from that page: the library was rebuilt.
    if (!mounted) return;
    await _syncEverything();
  }

  /// Every video in the library, as an album ([_videos]). Not a row in the
  /// album table: there's nothing to add to it or remove from it, and a
  /// membership list would only be a second, staler answer to a question
  /// the library can already answer. GIFs count — they move, so the Videos
  /// album is where somebody goes looking for one. See
  /// [AssetRecord.countsAsVideo].

  /// A card for a grouping the library makes itself. No row of its own in
  /// the database: there's nothing to add to it or remove from it, and a
  /// stored membership list would only be a second, staler answer to a
  /// question the library can already answer.
  Album _builtInAlbum(BuiltInAlbum builtIn, String name) => Album(
    id: builtIn.id,
    name: name,
    createdAt: DateTime.now(),
    coverLocalId: _builtInCovers[builtIn],
  );

  /// A photo chosen for one of the two built-in cards, if the user has
  /// picked one. Read once per [reload] rather than per build — see
  /// CLAUDE.md on per-build work.
  Map<BuiltInAlbum, String?> _builtInCovers = const {};

  Future<Map<BuiltInAlbum, String?>> _loadBuiltInCovers() async {
    try {
      return {
        for (final album in BuiltInAlbum.values)
          album: await builtInAlbumCover(assetRecordStore, album),
      };
    } catch (_) {
      // No app-state table yet — the coloured default is the right answer
      // anyway.
      return const {};
    }
  }

  void _openRecentlyAdded() {
    final l10n = AppLocalizations.of(context)!;
    _push(
      AssetGroupScreen(
        title: l10n.albumsRecentlyAddedName,
        records: _recentlyAdded,
        assetRecordStore: assetRecordStore,
        coverFor: BuiltInAlbum.recentlyAdded,
        dateOf: PhotoGridLayout.addedAt,
        notes: _albumStore.noteBook(BuiltInAlbum.recentlyAdded.id),
      ),
    );
  }

  void _openArchive() {
    final l10n = AppLocalizations.of(context)!;
    _push(
      AssetGroupScreen(
        title: l10n.archiveAlbumName,
        records: _archived,
        assetRecordStore: assetRecordStore,
        coverFor: BuiltInAlbum.archive,
        notes: _albumStore.noteBook(BuiltInAlbum.archive.id),
        archive: true,
      ),
    );
  }

  void _openVideos() {
    final l10n = AppLocalizations.of(context)!;
    _push(
      AssetGroupScreen(
        title: l10n.albumsVideosName,
        records: _videos,
        assetRecordStore: assetRecordStore,
        coverFor: BuiltInAlbum.videos,
        notes: _albumStore.noteBook(BuiltInAlbum.videos.id),
      ),
    );
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
    // Not disposed: the closing dialog still builds the field; GC has it.
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
      photoLibraryService: _photoLibraryService,
    ),
  );

  void _openPerson(Person person) => _push(
    PersonPageScreen(
      person: person,
      personStore: _personStore,
      assetRecordStore: assetRecordStore,
      aiAnalysisStore: _aiAnalysisStore,
      faceIdentity: _faceIdentity,
    ),
  );

  void _openPeopleScreen() => _push(
    PeopleScreen(
      personStore: _personStore,
      assetRecordStore: assetRecordStore,
      aiAnalysisStore: _aiAnalysisStore,
      faceIdentity: _faceIdentity,
      onOpenAsset: _openById,
      fixQueue: _fixQueue,
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
    final filtered = _home;
    final selection = _selection;

    return Listener(
      onPointerDown: (_) => _touched = true,
      child: NotificationListener<ScrollNotification>(
        onNotification: (_) {
          _touched = true;
          return false;
        },
        child: _page(context, l10n, filtered, selection),
      ),
    );
  }

  Widget _page(
    BuildContext context,
    AppLocalizations l10n,
    List<AssetRecord> filtered,
    Set<String>? selection,
  ) {
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
                  selection: selection == null ? null : _picked,
                  // Never called: [onLongPress] replaces the menu.
                  actionsFor: _actionsFor,
                  // Only once the database has actually been read. An
                  // empty `_all` is also what "hasn't loaded yet" looks
                  // like, and offering "No Photos Yet — Add Files" for a
                  // moment on every launch says the library is gone.
                  // Nothing rather than a skeleton: the page opens at its
                  // rest (Albums at the top), and a skeleton grid there
                  // only drew a frame of the wrong place before the jump.
                  emptySliver: !_loaded
                      ? const SliverToBoxAdapter(child: SizedBox.shrink())
                      : _all.isEmpty
                      ? SliverToBoxAdapter(
                          child: _EmptyState(busy: _busy, onAddFiles: addFiles),
                        )
                      : null,
                  scrubberInsets: const EdgeInsets.only(top: 56, bottom: 16),
                  leadingSlivers: _leadingSlivers(
                    l10n,
                    selectAll: ValueListenableBuilder(
                      valueListenable: _picked,
                      builder: (context, picked, _) => SelectAllButton(
                        total: filtered.length,
                        selectedCount: picked.length,
                        onSelectNext: () => _select(
                          selectNextBatch(
                            filtered.reversed.map((r) => r.localId),
                            picked,
                          ),
                        ),
                        onDeselectAll: () => _select({}),
                      ),
                    ),
                  ),
                  // Nothing below the grid until it has photos: an empty
                  // grid put More at the top of a cold launch for a beat.
                  trailingSlivers: _loaded
                      ? _trailingSlivers(l10n, selection)
                      : const [],
                  // Opens on the grid, newest photos along the bottom;
                  // Albums and People are a scroll down.
                ),
                if (selection != null)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: ValueListenableBuilder(
                      valueListenable: _picked,
                      builder: (context, picked, _) => _SelectionBar(
                        count: picked.length,
                        onAddTag: _batchAddTag,
                        onAddToAlbum: _batchAddToAlbum,
                        onSetPlace: _batchSetPlace,
                        onAdjustDateTime: _batchAdjustDateTime,
                        onDelete: _batchDelete,
                        onHide: _batchHide,
                        onArchive: _batchArchive,
                        onResize: _batchResize,
                        onAnalyzeFaces: _batchAnalyzeFaces,
                      ),
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
        // Off while selecting: Select All sits under it.
        if (!_selecting)
          Positioned(
            top: MediaQuery.paddingOf(context).top,
            left: 0,
            right: 0,
            height: _navigationBarHeight,
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: _jumpHome,
            ),
          ),
      ],
    );
  }

  /// `CupertinoSliverNavigationBar`'s collapsed height — the strip that
  /// stays pinned under the status bar however far the page is scrolled.
  static const _navigationBarHeight = 44.0;

  /// The system's own status-bar tap. It never reaches the widget tree — iOS
  /// hands it to the engine, which forwards it to every
  /// [WidgetsBindingObserver] — so a `GestureDetector` laid over the status
  /// bar can't see it, however opaque. Overriding it here also takes it off
  /// [CupertinoPageScaffold], whose version scrolls the primary controller to
  /// its minimum: in a newest-first grid that's the *oldest* photo, the one
  /// place in a ten-year library nobody means to land.
  @override
  void handleStatusBarTap() => _jumpHome();

  /// Back home to the newest photos — and, tapped again from there, on up
  /// to the very top. Bound to the status bar, the navigation bar and the large
  /// title: the whole header, which is what a thumb reaches for when it's
  /// lost.
  void _jumpHome() => _gridKey.currentState?.toggleAnchor();

  List<Widget> _leadingSlivers(
    AppLocalizations l10n, {
    required Widget selectAll,
  }) => [
    CupertinoSliverNavigationBar(
      // Selecting: Select All and Done in opposite corners, clear of the
      // actions along the bottom.
      leading: _selecting ? selectAll : null,
      largeTitle: GestureDetector(
        onTap: _jumpHome,
        child: Text(l10n.tabLibrary),
      ),
      trailing: _selecting
          ? SelectionDoneButton(
              key: const ValueKey('librarySelectionDone'),
              onPressed: () => setState(() => _selection = null),
            )
          : null,
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
            // Favourites, Videos, Recently Added, Archive, then the user's
            // own. The first four aren't albums anybody made — they're groupings
            // the library can always answer for itself, so they're always
            // there and there's nothing to delete.
            itemCount: _albums.length + 4,
            separatorBuilder: (context, i) => const SizedBox(width: 12),
            itemBuilder: (context, i) => SizedBox(
              width: 140,
              child: switch (i) {
                0 => _AlbumCard(
                  album: _builtInAlbum(
                    BuiltInAlbum.favorites,
                    l10n.collectionsFavoritesRow,
                  ),
                  builtIn: BuiltInAlbum.favorites,
                  records: _favorites,
                  onTap: () => _push(
                    FavoritesScreen(
                      assetRecordStore: assetRecordStore,
                      notes: _albumStore.noteBook(BuiltInAlbum.favorites.id),
                    ),
                  ),
                ),
                1 => _AlbumCard(
                  album: _builtInAlbum(
                    BuiltInAlbum.videos,
                    l10n.albumsVideosName,
                  ),
                  builtIn: BuiltInAlbum.videos,
                  records: _videos,
                  onTap: _openVideos,
                ),
                2 => _AlbumCard(
                  album: _builtInAlbum(
                    BuiltInAlbum.recentlyAdded,
                    l10n.albumsRecentlyAddedName,
                  ),
                  builtIn: BuiltInAlbum.recentlyAdded,
                  records: _recentlyAdded,
                  onTap: _openRecentlyAdded,
                ),
                3 => _AlbumCard(
                  album: _builtInAlbum(
                    BuiltInAlbum.archive,
                    l10n.archiveAlbumName,
                  ),
                  builtIn: BuiltInAlbum.archive,
                  records: _archived,
                  onTap: _openArchive,
                ),
                _ => _AlbumCard(
                  album: _albums[i - 4],
                  records: _albumAssets[_albums[i - 4].id] ?? const [],
                  count: _earlyAlbumCounts?[_albums[i - 4].id],
                  onTap: () => _openAlbum(_albums[i - 4]),
                  onDelete: () => _confirmDeleteAlbum(_albums[i - 4]),
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
                        // Early, the library isn't read yet: each avatar
                        // looks itself up.
                        records: _earlyPeople
                            ? null
                            : assetRecordStore.visibleById,
                        photoCount: _personPhotoCounts[person.id] ?? 0,
                        firstPhoto: _personFirstPhotos[person.id],
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
          groups: _places,
          emptyNote: l10n.collectionsPlacesEmpty,
          icon: CupertinoIcons.map_pin_ellipse,
          color: CupertinoColors.systemTeal,
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
          ValueListenableBuilder(
            valueListenable: _fixLeft,
            builder: (context, left, _) => _row(
              icon: CupertinoIcons.chart_pie_fill,
              color: CupertinoColors.systemOrange,
              title: l10n.collectionsStorageRow,
              count: left,
              busy: left != null,
              onTap: () => _push(
                SuggestionsScreen(
                  store: assetRecordStore,
                  targetsStore: _backupTargetsStore,
                  advisor: _storageAdvisor,
                  queue: _fixQueue,
                  scan: _flagScan,
                  onOpenAsset: _openById,
                  albumStore: _albumStore,
                  personStore: _personStore,
                  aiAnalysisStore: _aiAnalysisStore,
                ),
              ),
            ),
          ),
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
          _row(
            icon: CupertinoIcons.globe,
            color: CupertinoColors.systemBlue,
            title: l10n.collectionsLanguageRow,
            onTap: _pickLanguage,
          ),
          // Photos and videos straight from Files — an SD card, a folder
          // copied onto the phone — never through Photos.
          _row(
            icon: CupertinoIcons.folder_fill_badge_plus,
            color: CupertinoColors.systemGreen,
            title: l10n.libraryAddFilesButton,
            onTap: addFiles,
          ),
          _row(
            icon: CupertinoIcons.hammer_fill,
            color: CupertinoColors.systemIndigo,
            title: l10n.collectionsDeveloperRow,
            onTap: () => _push(
              DeveloperOptionsScreen(
                personStore: _personStore,
                assetRecordStore: assetRecordStore,
                analysisStore: _aiAnalysisStore,
              ),
            ),
          ),
          _row(
            icon: CupertinoIcons.eye_slash_fill,
            color: CupertinoColors.systemGrey,
            title: l10n.collectionsHiddenRow,
            // No count. A number here answers "is there a hidden album,
            // and how big" for anyone holding the phone, before a single
            // digit of the passcode is typed — which is the whole thing
            // the gate exists not to answer. See DESIGN.md.
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
    SliverToBoxAdapter(child: _SectionHeader(title: l10n.privacyHeading)),
    const SliverToBoxAdapter(child: _PrivacyNote()),
    // Below the note, not in the menu: it is the proof of what the note
    // claims, so it sits where the claim is read.
    SliverToBoxAdapter(child: _WhereCard(onTap: _openSafety)),
    // The last thing on the page, under the note that explains what there
    // is to lose. It lived in Cloud Settings, which is a page about where
    // photos *go* — the wipe is about the whole app, so it belongs at the
    // end of the whole app rather than filed under one of its parts.
    SliverToBoxAdapter(
      child: _RemoveAllDataButton(
        busy: _removingAppData,
        onPressed: _confirmRemoveAppData,
      ),
    ),
    SliverToBoxAdapter(
      child: Center(
        child: CupertinoButton(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          minimumSize: Size.zero,
          onPressed: _busy ? null : _toggleDemoMode,
          child: Text(
            DemoFlag.active ? l10n.demoModeExitRow : l10n.demoModeEnterRow,
            style: const TextStyle(color: CupertinoColors.systemGrey),
          ),
        ),
      ),
    ),
    if (DemoFlag.active)
      SliverToBoxAdapter(
        child: Center(
          child: CupertinoButton(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            minimumSize: Size.zero,
            onPressed: _busy ? null : _confirmDemoReset,
            child: Text(
              l10n.settingsDemoResetRow,
              style: const TextStyle(color: CupertinoColors.systemGrey),
            ),
          ),
        ),
      ),
    SliverToBoxAdapter(child: SizedBox(height: selection == null ? 24 : 140)),
  ];

  Future<void> _confirmRemoveAppData() async {
    final l10n = AppLocalizations.of(context)!;
    // true = hidden photos go too; false = they are kept; null = cancelled.
    final includeHidden = await showCupertinoDialog<bool>(
      context: context,
      builder: (dialogContext) => CupertinoAlertDialog(
        title: Text(l10n.settingsRemoveAllAppDataTitle),
        content: Text(l10n.settingsRemoveAllAppDataBody),
        actions: [
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.settingsRemoveAllAppDataKeepHidden),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.settingsRemoveAllAppDataWithHidden),
          ),
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l10n.actionCancel),
          ),
        ],
      ),
    );
    if (includeHidden == null || !mounted) return;
    setState(() => _removingAppData = true);
    var outcome = AppDataOutcome.done;
    try {
      // No prompt, no share sheet: the copies are simply taken, and then
      // everything goes — rows, files, queue, credentials. See
      // `../settings/app_data_removal.dart` for why the order is what it is.
      outcome = await _appDataRemoval.run(includeHidden: includeHidden);
    } finally {
      if (mounted) setState(() => _removingAppData = false);
    }
    if (mounted) await reload();
    if (outcome != AppDataOutcome.done && mounted) {
      await showCupertinoDialog<void>(
        context: context,
        builder: (dialogContext) => CupertinoAlertDialog(
          content: Text(
            outcome == AppDataOutcome.refused
                ? l10n.settingsRemoveAllAppDataRefused
                : l10n.settingsRemoveAllAppDataKeptFiles,
          ),
          actions: [
            CupertinoDialogAction(
              isDefaultAction: true,
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(l10n.actionOk),
            ),
          ],
        ),
      );
    }
  }

  CupertinoListTile _row({
    required IconData icon,
    required Color color,
    required String title,
    int? count,
    bool busy = false,
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
          if (busy) ...[
            const CupertinoActivityIndicator(radius: 7),
            const SizedBox(width: 6),
          ],
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
    this.builtIn,
    this.onDelete,
    this.count,
  });

  final Album album;
  final List<AssetRecord> records;

  /// Last launch's count, while [records] holds only the cover.
  final int? count;
  final VoidCallback onTap;

  /// Set for the two the library makes itself, which draw a coloured cover
  /// rather than their newest photo — see [BuiltInAlbum].
  final BuiltInAlbum? builtIn;

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
  ///
  /// Except for the two built-in ones, which fall back to their colour
  /// rather than to a photo — the newest video in the library is not a
  /// picture of "Videos".
  AssetRecord? get _cover {
    if (records.isEmpty) return null;
    final chosen = album.coverLocalId;
    if (chosen != null) {
      // Built-in lists are library-sized, and cards rebuild with home.
      final hit = _chosenCovers[records];
      if (hit != null && hit.id == chosen) return hit.record ?? _fallback;
      AssetRecord? found;
      for (final record in records) {
        if (record.localId == chosen) {
          found = record;
          break;
        }
      }
      _chosenCovers[records] = (id: chosen, record: found);
      if (found != null) return found;
    }
    return _fallback;
  }

  AssetRecord? get _fallback => builtIn != null ? null : records.last;

  /// Keyed on the list itself: each reload hands over new lists.
  static final _chosenCovers = Expando<({String id, AssetRecord? record})>();

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
                  ? (builtIn != null
                        ? BuiltInAlbumCoverArt(builtIn!)
                        : const ColoredBox(
                            color: CupertinoColors.systemGrey5,
                            child: Icon(CupertinoIcons.photo_on_rectangle),
                          ))
                  // Drawn the way a grid tile is, which is what makes a
                  // camera-roll photo — or a video's poster frame — show
                  // up here at all.
                  : SizedBox(
                      width: double.infinity,
                      child: assetImage(
                        cover,
                        // Never the original's full size (UI-9).
                        fileDecodeSize:
                            (150 * MediaQuery.devicePixelRatioOf(context))
                                .round(),
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
            '${count ?? records.length}',
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
    required this.firstPhoto,
    required this.onTap,
    this.records,
  });

  final Person person;
  final AssetRecordStore assetRecordStore;
  final Map<String, AssetRecord>? records;
  final int photoCount;
  final String? firstPhoto;
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
          firstTaggedLocalId: firstPhoto,
          records: records,
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

/// A face with nobody's name on it. Same circle as a person card so the
/// row reads as one thing, but ringed rather than plain and captioned with
/// the question instead of a name — it is not a person yet, and a card
/// that looked like one would be claiming the app knows who this is.
/// Last thing on the page, after everything configurable above it: what the
/// app does with your photos, said once and in full.
class _PrivacyNote extends StatelessWidget {
  const _PrivacyNote();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.all(16),
      decoration: const BoxDecoration(
        color: Color(0xFF2C2C2E),
        borderRadius: BorderRadius.all(Radius.circular(10)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.privacyTitle,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Text(
            l10n.privacyBody,
            style: const TextStyle(
              fontSize: 13,
              height: 1.4,
              color: CupertinoColors.systemGrey,
            ),
          ),
        ],
      ),
    );
  }
}

/// Where Your Photos Are, as a card of its own under the privacy note:
/// the way to check every copy the note talks about.
class _WhereCard extends StatelessWidget {
  const _WhereCard({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: CupertinoButton(
        key: const ValueKey('where-your-photos-are'),
        padding: const EdgeInsets.all(14),
        color: const Color(0xFF2C2C2E),
        borderRadius: const BorderRadius.all(Radius.circular(10)),
        onPressed: onTap,
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: CupertinoColors.systemGreen.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(9),
              ),
              child: const Icon(
                CupertinoIcons.checkmark_shield_fill,
                size: 20,
                color: CupertinoColors.systemGreen,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.collectionsSafetyRow,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: CupertinoColors.white,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    l10n.privacyCheckRow,
                    style: const TextStyle(
                      fontSize: 13,
                      color: CupertinoColors.systemGrey,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(
              CupertinoIcons.chevron_right,
              size: 15,
              color: CupertinoColors.systemGrey2,
            ),
          ],
        ),
      ),
    );
  }
}

/// Remove All App Data, at the very foot of the page.
///
/// A bare red text button rather than a row in a list: it is not one of the
/// things the page offers, it is the way out of all of them, and giving it a
/// row would put it in reach of a thumb scrolling past.
class _RemoveAllDataButton extends StatelessWidget {
  const _RemoveAllDataButton({required this.busy, required this.onPressed});

  final bool busy;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.only(top: 24),
      child: Center(
        child: CupertinoButton(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          minimumSize: Size.zero,
          onPressed: busy ? null : onPressed,
          child: busy
              ? const CupertinoActivityIndicator(radius: 9)
              : Text(
                  l10n.settingsRemoveAllAppDataButton,
                  style: const TextStyle(color: CupertinoColors.systemRed),
                ),
        ),
      ),
    );
  }
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

/// Albums, People, Places — each a section of the page, not a subsection of
/// one. They used to sit under a "Collections" heading that named a category
/// nobody was looking for: you look for people, or for a place, and the
/// extra level only pushed all three further down.
class _SubsectionHeader extends StatelessWidget {
  const _SubsectionHeader({required this.title, this.onMore, this.onAdd});

  final String title;

  /// A "+" beside the title — the section's own create action (a new
  /// album). Sits opposite [onMore], which is where the section goes on to
  /// rather than what it makes.
  final VoidCallback? onAdd;

  /// Shows a "More" chevron beside the title (People's entry point to the
  /// full `PeopleScreen`) instead of a separate trailing card in the row
  /// below.
  final VoidCallback? onMore;

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

/// The bar that replaces per-tile actions while photos are selected: the
/// count and a way out up top, the batch actions below; the rarer ones and
/// delete sit behind More.
class _SelectionBar extends StatelessWidget {
  const _SelectionBar({
    required this.count,
    required this.onAddTag,
    required this.onAddToAlbum,
    required this.onSetPlace,
    required this.onAdjustDateTime,
    required this.onHide,
    required this.onArchive,
    required this.onResize,
    required this.onAnalyzeFaces,
    required this.onDelete,
  });

  final int count;
  final VoidCallback onAddTag;
  final VoidCallback onAddToAlbum;
  final VoidCallback onSetPlace;
  final VoidCallback onAdjustDateTime;
  final VoidCallback onHide;
  final VoidCallback onArchive;
  final VoidCallback onResize;
  final VoidCallback onAnalyzeFaces;
  final VoidCallback onDelete;

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
                  // The hint is a sentence: it wraps rather than pushing
                  // Select All and Done off a phone-width bar.
                  Expanded(
                    child: Text(
                      count == 0
                          ? l10n.selectionHint
                          : l10n.selectionTitle(count),
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 2, 8, 6),
              // Three, not six: room for a thumb-sized target each. Delete
              // lives in More — beside Done it was one slip from a mistake.
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
              onArchive();
            },
            child: Text(l10n.archiveAction),
          ),
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
              onAdjustDateTime();
            },
            child: Text(l10n.selectionAdjustDateTime),
          ),
          CupertinoActionSheetAction(
            onPressed: () {
              Navigator.of(sheetContext).pop();
              onResize();
            },
            child: Text(l10n.resizeOption),
          ),
          CupertinoActionSheetAction(
            key: const ValueKey('selectionAnalyzeFaces'),
            onPressed: () {
              Navigator.of(sheetContext).pop();
              onAnalyzeFaces();
            },
            child: Text(l10n.analyzeFacesAction),
          ),
          CupertinoActionSheetAction(
            onPressed: () {
              Navigator.of(sheetContext).pop();
              onHide();
            },
            child: Text(l10n.libraryHide),
          ),
          CupertinoActionSheetAction(
            isDestructiveAction: true,
            onPressed: () {
              Navigator.of(sheetContext).pop();
              onDelete();
            },
            child: Text(l10n.selectionDelete),
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
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
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
          Icon(icon, size: 26),
          const SizedBox(height: 4),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12),
          ),
        ],
      ),
    );
  }
}

/// Places: one text row per distinct value the user has set.
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
  const _EmptyState({required this.busy, required this.onAddFiles});

  final bool busy;
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
              onPressed: busy ? null : onAddFiles,
              child: Text(l10n.libraryAddFilesButton),
            ),
          ],
        ),
      ),
    );
  }
}
