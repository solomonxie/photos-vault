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

  Future<void> refresh() async {
    try {
      jobs.value = await store.all();
    } catch (_) {
      // Queue database unavailable (e.g. no platform channel in a test) —
      // an empty list beats tearing down whatever's showing it.
    }
  }

  /// Picks up anything a previous run left mid-flight, then starts draining.
  Future<void> resume() async {
    await _loadSettings();
    await store.requeueStaleRunning();
    await refresh();
    unawaited(start());
  }

  Future<void> enqueue({
    required String localId,
    required SyncJobKind kind,
    required String displayName,
  }) async {
    await store.enqueue(localId: localId, kind: kind, displayName: displayName);
    await refresh();
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

  /// Jobs run in batches of [concurrency] rather than as a continuously
  /// topped-up pool: a slow file holds up its batch, but the bound is
  /// obvious and there's no bookkeeping to get wrong.
  Future<void> _runDrain() async {
    draining.value = true;
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
