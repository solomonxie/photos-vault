import 'dart:async';

import 'package:flutter/foundation.dart';

import '../settings/backup_targets_store.dart';
import 'sync_job.dart';
import 'sync_job_store.dart';

/// Drains [SyncJobStore] with bounded concurrency. Every unit of sync work —
/// change checks included — goes through here rather than being awaited
/// inline, so progress is visible per file, pausable, and retryable instead
/// of being one opaque loop.
class SyncQueue {
  SyncQueue({
    required this.store,
    required this.settings,
    required Future<void> Function(SyncJob job) process,
  }) : _process = process;

  final SyncJobStore store;

  /// Where `paused`/`concurrency` persist, alongside the other backup
  /// preferences.
  final BackupTargetsStore settings;

  final Future<void> Function(SyncJob job) _process;

  /// The most unfinished jobs the queue will hold. Past this, [enqueue]
  /// refuses rather than growing: a camera roll is hundreds of thousands of
  /// assets, and a queue that long is neither reviewable nor cancellable —
  /// it's just a list nobody can act on. Work is picked up a queueful at a
  /// time instead, topped up as it drains.
  static const capacity = 100;

  /// What counts against [capacity]: work still to be done. A *failed* job
  /// isn't — it's a row waiting for someone to look at it, and letting
  /// failures fill the queue would mean a hundred dead entries quietly
  /// blocking every future sync, with nothing on screen saying so.
  static const _outstanding = [SyncJobStatus.pending, SyncJobStatus.running];

  /// The live queue, for the UI to render. Refreshed after every state
  /// change rather than polled.
  final ValueNotifier<List<SyncJob>> jobs = ValueNotifier(const []);

  /// True while a drain loop is running — distinct from "there are pending
  /// jobs", which is what the queue list itself shows.
  final ValueNotifier<bool> draining = ValueNotifier(false);

  final ValueNotifier<bool> paused = ValueNotifier(false);
  final ValueNotifier<int> concurrency = ValueNotifier(2);

  bool _loadedSettings = false;

  Future<void> _loadSettings() async {
    if (_loadedSettings) return;
    _loadedSettings = true;
    try {
      paused.value = await settings.getQueuePaused();
      concurrency.value = await settings.getQueueConcurrency();
    } catch (_) {
      // Secure storage unavailable — the defaults above are fine.
    }
  }

  /// Loads the persisted settings first. A screen that opens on the queue
  /// calls this and nothing else, and without it `paused`/`concurrency`
  /// render as their constructor defaults — a stopped queue drawn with a
  /// Pause button and a running look, which is how uploads go missing for
  /// a week.
  Future<void> refresh() async {
    await _loadSettings();
    try {
      jobs.value = await store.all();
    } catch (_) {
      // Queue database unavailable (e.g. no platform channel in a test) —
      // an empty list beats tearing down whatever's showing it.
    }
  }

  /// Picks up anything a previous run left mid-flight, then starts draining.
  /// [drain] false repairs and reloads the queue but starts nothing — what
  /// a "Manual" sync frequency means on launch. The jobs stay visible and
  /// countable; none of them goes up until somebody asks.
  Future<void> resume({bool drain = true}) async {
    await _loadSettings();
    await store.requeueStaleRunning();
    await store.trimHistory();
    await refresh();
    if (drain) unawaited(start());
  }

  /// How many jobs are still to be done — waiting or running. What
  /// [capacity] is measured against.
  Future<int> unfinishedCount() => store.countWhere(_outstanding);

  /// Returns whether the job was taken. `false` means the queue is paused
  /// or full — both of which the caller should read as "not now", not as a
  /// failure: the work is still pending on the asset itself, and the next
  /// sync pass picks it up.
  Future<bool> enqueue({
    required String localId,
    required SyncJobKind kind,
    required String displayName,
    required DateTime assetCreatedAt,
  }) async {
    await _loadSettings();
    // Paused means paused: a queue that keeps growing while stopped is
    // just a delayed surprise.
    if (paused.value) return false;
    if (await unfinishedCount() >= capacity) return false;
    await store.enqueue(
      localId: localId,
      kind: kind,
      displayName: displayName,
      assetCreatedAt: assetCreatedAt,
    );
    await refresh();
    return true;
  }

  Future<void> setPaused(bool value) async {
    await _loadSettings();
    paused.value = value;
    try {
      await settings.setQueuePaused(value);
    } catch (_) {
      // See `_loadSettings`.
    }
    if (!value) unawaited(start());
  }

  Future<void> setConcurrency(int value) async {
    await _loadSettings();
    concurrency.value = value.clamp(1, 8);
    try {
      await settings.setQueueConcurrency(concurrency.value);
    } catch (_) {
      // See `_loadSettings`.
    }
  }

  Future<void> clearQueue() async {
    await store.clearQueue();
    await refresh();
  }

  Future<void> clearSynced() async {
    await store.clearSynced();
    await refresh();
  }

  Future<void> retry(SyncJob job) async {
    await store.retry(job.id);
    await refresh();
    unawaited(start());
  }

  /// Jobs actually run by the drain that just finished. Lets a caller tell
  /// "the queue emptied, there may be more to feed it" from "there was
  /// never anything to do" — the difference between continuing a sync and
  /// starting one nobody asked for.
  int processedInLastDrain = 0;

  Future<void>? _drain;

  /// Runs until the queue empties or it's paused. Safe to call whenever
  /// something is enqueued: a call made while a drain is already running
  /// joins that one rather than starting a second set of workers — and
  /// still only returns once the queue is actually idle, so callers can
  /// await it meaningfully.
  Future<void> start() async {
    await _loadSettings();
    if (paused.value) return;
    final inFlight = _drain;
    if (inFlight != null) return inFlight;
    final future = _runDrain();
    _drain = future;
    try {
      await future;
    } finally {
      _drain = null;
    }
  }

  /// Jobs already in flight when [setPaused] is called are allowed to
  /// finish — an upload killed mid-request leaves a partial object in the
  /// bucket, which costs more than the second it saves.
  ///
  /// Jobs run in batches of [concurrency] rather than as a continuously
  /// topped-up pool: a slow file holds up its batch, but the bound is
  /// obvious and there's no bookkeeping to get wrong.
  ///
  /// Each batch is claimed newest-photo-first (see
  /// [SyncJobStore.dequeueNextPending]), so a photo taken while a years-deep
  /// backlog is draining goes up in the next batch rather than behind it.
  Future<void> _runDrain() async {
    draining.value = true;
    processedInLastDrain = 0;
    try {
      while (!paused.value) {
        final batch = <Future<void>>[];
        for (var i = 0; i < concurrency.value; i++) {
          final job = await store.dequeueNextPending();
          if (job == null) break;
          batch.add(_run(job));
        }
        if (batch.isEmpty) break;
        await refresh();
        await Future.wait(batch);
        await refresh();
      }
    } finally {
      draining.value = false;
    }
  }

  Future<void> _run(SyncJob job) async {
    processedInLastDrain++;
    try {
      await _process(job);
      await store.markDone(job.id);
    } catch (e) {
      await store.markFailed(job.id, e.toString());
    }
  }

  void dispose() {
    jobs.dispose();
    draining.dispose();
    paused.dispose();
    concurrency.dispose();
  }
}
