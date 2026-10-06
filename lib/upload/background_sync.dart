import 'dart:async';

import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:photo_manager/photo_manager.dart';

import '../demo/demo_flag.dart';
import '../demo/demo_mode.dart';
import '../photos/asset_removal.dart';
import '../photos/file_hash.dart' as file_hash;
import '../photos/photo_library_service.dart';
import '../photos/thumbnail_cache.dart';
import '../settings/backup_targets_store.dart';
import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import '../vault/carrier_upload.dart';
import '../vault/keys.dart';
import '../vault/store.dart';
import 'backup_coordinator.dart';
import 'backup_verifier.dart';
import 'pending_deletes.dart';
import 'sync_engine.dart';
import 'sync_job.dart';
import 'sync_job_store.dart';

/// Why a background run did nothing. Each is a decision made before any
/// work starts, so a run that has nothing to do costs a few queries.
enum BackgroundSkip {
  demo,
  manual,
  noTarget,
  foregroundRecent,
  notDue,
  nothingToDo,
}

/// The only record of the foreground app, in `app_state`: written on every
/// resume and pause, read by the background run to stay out of its way.
/// Both run in one process with two engines on one database, and the
/// foreground always wins.
class ForegroundHeartbeat {
  ForegroundHeartbeat(this.store);

  final AssetRecordStore store;

  static const key = 'foreground_heartbeat';

  /// How long after the app last left (or was in) the foreground a
  /// background run keeps off.
  static const quiet = Duration(minutes: 5);

  Future<void> beat() =>
      store.setAppState(key, DateTime.now().toIso8601String());

  Future<DateTime?> last() async {
    final raw = await store.getAppState(key);
    return raw == null ? null : DateTime.tryParse(raw);
  }
}

/// Whether a background run should start, and if not, why. Pure so the
/// rules are tested without a phone.
BackgroundSkip? backgroundSkipReason({
  required bool demo,
  required SyncFrequency frequency,
  required bool hasTarget,
  required DateTime? lastSyncAt,
  required DateTime? foregroundAt,
  required bool hasWork,
  required DateTime now,
}) {
  if (demo) return BackgroundSkip.demo;
  if (frequency == SyncFrequency.manual) return BackgroundSkip.manual;
  if (!hasTarget) return BackgroundSkip.noTarget;
  if (foregroundAt != null &&
      now.difference(foregroundAt) < ForegroundHeartbeat.quiet) {
    return BackgroundSkip.foregroundRecent;
  }
  if (!isSyncDue(frequency: frequency, lastSyncAt: lastSyncAt, now: now)) {
    return BackgroundSkip.notDue;
  }
  if (!hasWork) return BackgroundSkip.nothingToDo;
  return null;
}

/// One headless sync pass, started by iOS (`BGProcessingTask`, see
/// `ios/Runner/BackgroundSync.swift`) in a second Flutter engine with no
/// screen. Runs the same [SyncEngine] the library screen does.
///
/// Left to the foreground, on purpose: hidden photos (no album key is open),
/// the change-check re-hash of the whole library, and the full camera-roll
/// scan. New photos are picked up from the newest end only.
class BackgroundSync {
  bool _cancelled = false;

  /// iOS is about to take the time away. Nothing new starts; jobs already
  /// in flight are left to the next run, which requeues any left `running`.
  void cancel() {
    _cancelled = true;
    _stopQueue?.call();
  }

  void Function()? _stopQueue;

  bool get cancelled => _cancelled;

  /// True when the pass ran to the end, false when it skipped or was cut
  /// short.
  Future<bool> run({DateTime Function() now = DateTime.now}) async {
    try {
      await DemoMode.init();
    } catch (_) {
      // Demo plumbing must never be why the real app doesn't sync.
    }
    final started = now();
    final recordStore = AssetRecordStore();
    final targets = BackupTargetsStore();
    final heartbeat = ForegroundHeartbeat(recordStore);
    final library = PhotoLibraryService(
      store: recordStore,
      // Never asks: a permission prompt has nobody to answer it.
      requestPermission: () => PhotoManager.getPermissionState(
        requestOption: const PermissionRequestOption(),
      ),
    );
    final thumbnails = ThumbnailCache(store: recordStore);
    var records = const <AssetRecord>[];
    Future<void> reload() async => records = [
      for (final r in await recordStore.listAll())
        if (r.passcodeHash == null) r,
    ];

    final engine = SyncEngine(
      recordStore: recordStore,
      targetsStore: targets,
      coordinator: BackupCoordinator(
        targetsStore: targets,
        recordStore: recordStore,
        carriers: CarrierBuilder(
          posterFrame: thumbnails.libraryThumbnail,
          videoDuration: library.durationOf,
        ),
        vaultKeys: VaultKeys(),
        vaultStore: VaultStore(),
      ),
      thumbnailCache: thumbnails,
      library: library,
      syncJobStore: SyncJobStore(),
      kinds: const {
        SyncJobKind.uploadOriginal,
        SyncJobKind.uploadThumbnail,
        SyncJobKind.uploadLivePhoto,
      },
      pendingDeletes: PendingDeletes(store: recordStore),
      records: () => records,
      displayName: (record) => record.sourcePath != null
          ? p.basename(record.sourcePath!)
          : DateFormat.yMMMd().add_jm().format(record.createdAt),
      hashFile: file_hash.hashFile,
    );

    _stopQueue = () => engine.syncQueue.paused.value = true;
    await reload();
    final reason = backgroundSkipReason(
      demo: DemoFlag.active,
      frequency: await _try<SyncFrequency>(
        targets.getSyncFrequency,
        SyncFrequency.manual,
      ),
      hasTarget: await engine.hasBackupTarget(),
      lastSyncAt: await _try<DateTime?>(targets.getLastSyncAt, null),
      foregroundAt: await heartbeat.last(),
      hasWork:
          engine.pendingAndFailed.isNotEmpty ||
          engine.thumbnailsOwed.isNotEmpty ||
          await engine.pendingDeletes.count() > 0,
      now: started,
    );
    if (reason != null) return false;

    // The app coming to the foreground cancels the run: two engines and
    // one database is a race the user should never lose.
    final watch = Timer.periodic(const Duration(seconds: 15), (_) async {
      final at = await heartbeat.last();
      if (at != null && at.isAfter(started)) cancel();
    });
    try {
      await _pass(engine, recordStore, targets, library, thumbnails, reload);
    } finally {
      watch.cancel();
    }
    return !_cancelled;
  }

  Future<void> _pass(
    SyncEngine engine,
    AssetRecordStore recordStore,
    BackupTargetsStore targets,
    PhotoLibraryService library,
    ThumbnailCache thumbnails,
    Future<void> Function() reload,
  ) async {
    await engine.syncQueue.resume(drain: false);

    final access = await library.requestAccess();
    if (access != PhotoLibraryAccess.denied && !_cancelled) {
      try {
        await library.syncRecent();
        await reload();
      } catch (_) {
        // Photos unavailable right now; what is already known still goes up.
      }
    }

    final verifier = BackupVerifier(
      targetsStore: targets,
      recordStore: recordStore,
    );
    try {
      await DeferredDeletes(
        store: recordStore,
        pending: engine.pendingDeletes,
      ).release();
      await engine.pendingDeletes.drain(await targets.loadAll());
      await AssetRemoval(
        store: recordStore,
        thumbnails: thumbnails,
        library: library,
        verifier: verifier,
      ).expireBin();
      await verifier.spotCheck();
    } catch (_) {
      // Best-effort, like the foreground: the tasks stay queued.
    }

    engine.forgetFailures();
    var first = true;
    // The queue is capped, so a long backlog goes up a queueful at a time.
    for (var round = 0; round < 50 && !_cancelled; round++) {
      final queued = await engine.backUpRecords(engine.pendingAndFailed);
      if (first) {
        first = false;
        await _try<void>(() => targets.setLastSyncAt(DateTime.now()), null);
      }
      await engine.syncQueue.start();
      await reload();
      if (queued == 0) break;
    }
  }

  static Future<T> _try<T>(Future<T> Function() read, T fallback) async {
    try {
      return await read();
    } catch (_) {
      return fallback;
    }
  }
}
