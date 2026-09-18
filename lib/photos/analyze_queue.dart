import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../settings/ai_settings_store.dart';
import '../settings/backup_targets_store.dart' show SyncFrequency;
import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import 'ai_analysis.dart';
import 'ai_analysis_store.dart';
import 'ai_vision_service.dart';
import 'on_device_analysis.dart';

/// What one unit of work in the analyze pass actually does.
enum AnalyzeStep {
  /// Re-read the camera roll: new photos, edits, deletions. One job for the
  /// whole library rather than one per photo — Photos answers in pages, and
  /// the pass is a single call that either ran or didn't.
  scanLibrary,

  /// Look for faces on the phone. Free, offline, and the only thing this
  /// app can learn about a photo without asking anyone for money.
  findFaces,

  /// Ask the configured vendor for tags, an event label and a caption.
  /// Costs one call per photo, which is why it is never on by default.
  suggest,
}

enum AnalyzeJobStatus { pending, running, done, failed }

/// One row in the analyze queue.
class AnalyzeJob {
  const AnalyzeJob({
    required this.id,
    required this.step,
    required this.displayName,
    this.localId,
    this.status = AnalyzeJobStatus.pending,
    this.note,
  });

  final String id;

  /// The photo this is about — `null` for [AnalyzeStep.scanLibrary], which
  /// is about the library rather than any one item in it.
  final String? localId;

  final AnalyzeStep step;
  final String displayName;
  final AnalyzeJobStatus status;

  /// Why a failed job failed, in the user's words rather than an exception's.
  final String? note;

  bool get isFinished =>
      status == AnalyzeJobStatus.done || status == AnalyzeJobStatus.failed;

  AnalyzeJob copyWith({AnalyzeJobStatus? status, String? note}) => AnalyzeJob(
    id: id,
    localId: localId,
    step: step,
    displayName: displayName,
    status: status ?? this.status,
    note: note ?? this.note,
  );
}

/// The slow pass over the library: re-read what Photos has, look for faces
/// in whatever hasn't been looked at, and — only if asked — pay a vendor to
/// suggest tags and a caption.
///
/// A queue of its own rather than more rows in the sync queue. The two are
/// unlike in every way that matters: uploads are owed to a bucket and want
/// to finish, analysis is enrichment that can take all week; uploads cost
/// bandwidth, the free half of this costs battery; and a queue that mixes
/// them can't answer "is my library backed up?" without the reader doing
/// arithmetic on rows about faces.
///
/// Nothing is persisted. The work is *derivable* — a photo with no analysis
/// row needs one — so a queue that survives a restart would only be a copy
/// of a question the database already answers, and a stale one. What
/// persists is the settings: paused, pace, how often, and whether the paid
/// step is in.
class AnalyzeQueue {
  AnalyzeQueue({
    required this.assetRecordStore,
    required this.analysisStore,
    required this.onDeviceAnalysis,
    required this.scanLibrary,
    required this.resolvePath,
    required this.displayNameFor,
    this.aiVision,
    Future<bool> Function()? hasAiKey,
    this.rest = const Duration(milliseconds: 400),
  }) : _hasAiKey =
           hasAiKey ??
           (() async => (await AiSettingsStore().listKeys()).isNotEmpty);

  final AssetRecordStore assetRecordStore;
  final AiAnalysisStore analysisStore;
  final OnDeviceAnalysisService onDeviceAnalysis;

  /// The camera-roll pass, owned by the library screen because it is what
  /// redraws while the pages arrive.
  final Future<void> Function() scanLibrary;

  /// A photo's file on disk — `null` for one the library can't produce
  /// right now, which is a skip rather than a failure.
  final Future<String?> Function(AssetRecord record) resolvePath;

  /// What a row is called. Injected so the queue never has to know about
  /// localization or which photos are hidden.
  final String Function(AssetRecord record) displayNameFor;

  /// Absent, the paid step simply isn't offered.
  final AiVisionService? aiVision;

  /// Whether there's a key to spend. A switch that can be turned on with
  /// nothing behind it just queues a hundred jobs that all fail the same
  /// way.
  final Future<bool> Function() _hasAiKey;

  /// The wait between batches. The whole point of this queue is that it
  /// never makes the phone hot: a pass that finishes in an hour instead of
  /// a minute is the feature, not a compromise.
  final Duration rest;

  /// The longest list the sheet will show. The backlog on a fresh install
  /// is the whole camera roll, and thirty thousand rows is not a list
  /// anyone can act on — [remaining] carries the real number.
  static const capacity = 60;

  /// How many just-finished rows stay under the list.
  static const _finishedShown = 20;

  /// How long a re-read of the camera roll stays good for. Without this the
  /// queue would re-add the scan the moment it finished it and spend the
  /// day reading Photos.
  static const scanEvery = Duration(minutes: 5);

  final ValueNotifier<List<AnalyzeJob>> jobs = ValueNotifier(const []);
  final ValueNotifier<bool> running = ValueNotifier(false);
  final ValueNotifier<bool> paused = ValueNotifier(false);
  final ValueNotifier<int> pace = ValueNotifier(1);
  final ValueNotifier<SyncFrequency> frequency = ValueNotifier(
    SyncFrequency.everyHour,
  );

  /// Whether the vendor step is in. Off until someone says otherwise: it is
  /// the only part of this that arrives as a bill.
  final ValueNotifier<bool> suggest = ValueNotifier(false);

  /// Whether it *can* be switched on — an AI key is configured.
  final ValueNotifier<bool> canSuggest = ValueNotifier(false);

  /// Everything still outstanding, including what didn't fit in [jobs].
  final ValueNotifier<int> remaining = ValueNotifier(0);

  static const pausedKey = 'analyze_paused';
  static const paceKey = 'analyze_pace';
  static const frequencyKey = 'analyze_frequency';
  static const suggestKey = 'analyze_suggest';
  static const lastRunKey = 'analyze_last_run_at';

  bool _loaded = false;

  /// When the camera roll was last re-read. In memory: a scan on launch is
  /// exactly what a fresh start should do.
  DateTime? _scannedAt;

  /// When the pass last looked at photos. Persisted, because "every six
  /// hours" has to mean something across a restart.
  DateTime? _lastRunAt;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      paused.value = await assetRecordStore.getAppState(pausedKey) == 'true';
      suggest.value = await assetRecordStore.getAppState(suggestKey) == 'true';
      final storedPace = int.tryParse(
        await assetRecordStore.getAppState(paceKey) ?? '',
      );
      if (storedPace != null) pace.value = storedPace.clamp(1, 4);
      _lastRunAt = DateTime.tryParse(
        await assetRecordStore.getAppState(lastRunKey) ?? '',
      );
      final storedFrequency = await assetRecordStore.getAppState(frequencyKey);
      frequency.value = SyncFrequency.values.firstWhere(
        (f) => f.name == storedFrequency,
        orElse: () => frequency.value,
      );
    } catch (_) {
      // No database (tests, no platform channel) — the defaults above are
      // a working queue, which is what matters.
    }
    // Deliberately not awaited: the answer comes from the keychain, which
    // on a device without one never answers at all. Reading the camera
    // roll must not wait behind a question about a key it doesn't need.
    unawaited(_loadCanSuggest());
  }

  Future<void> _loadCanSuggest() async {
    try {
      canSuggest.value = aiVision != null && await _hasAiKey();
    } catch (_) {
      // No keychain, no key — the paid step stays off, which is where it
      // starts anyway.
    }
  }

  Future<void> setPaused(bool value) async {
    await load();
    paused.value = value;
    await _write(pausedKey, value ? 'true' : 'false');
    if (!value) unawaited(start());
  }

  Future<void> setPace(int value) async {
    await load();
    pace.value = value.clamp(1, 4);
    await _write(paceKey, '${pace.value}');
  }

  Future<void> setFrequency(SyncFrequency value) async {
    await load();
    frequency.value = value;
    await _write(frequencyKey, value.name);
  }

  Future<void> setSuggest(bool value) async {
    await load();
    suggest.value = value;
    await _write(suggestKey, value ? 'true' : 'false');
    await refresh();
  }

  Future<void> _write(String key, String value) async {
    try {
      await assetRecordStore.setAppState(key, value);
    } catch (_) {
      // See [load].
    }
  }

  /// Rebuilds the list from what's actually outstanding. Cheap enough to
  /// call whenever something might have changed — it's three queries and a
  /// filter, not a pass over the photos themselves.
  Future<void> refresh() async {
    await load();
    final outstanding = await _outstanding();
    final ids = outstanding.map((job) => job.id).toSet();
    jobs.value = [
      ...outstanding.take(capacity),
      // What just happened stays on screen under what's next: a pass that
      // erases its own work as it goes looks like a pass that did nothing.
      ...jobs.value
          .where((job) => job.isFinished && !ids.contains(job.id))
          .take(_finishedShown),
    ];
    remaining.value = outstanding.length;
  }

  Future<List<AnalyzeJob>> _outstanding() async {
    // Re-reading Photos is listed first and on its own: it is the one job
    // here that doesn't need the analysis database, and a library that
    // can't be *looked at* must still be read — otherwise one broken cache
    // quietly stops new photos ever arriving.
    final scan = [
      if (_scannedAt == null ||
          DateTime.now().difference(_scannedAt!) >= scanEvery)
        const AnalyzeJob(
          id: 'scan',
          step: AnalyzeStep.scanLibrary,
          displayName: '',
        ),
    ];
    List<AssetRecord> records;
    Map<String, AiPhotoAnalysis> analyzed;
    try {
      records = await _activeRecords();
      analyzed = await analysisStore.listAll();
    } catch (_) {
      return scan;
    }
    return [
      ...scan,
      for (final record in records)
        if (!record.isVideo && !analyzed.containsKey(record.localId))
          AnalyzeJob(
            id: 'faces:${record.localId}',
            localId: record.localId,
            step: AnalyzeStep.findFaces,
            displayName: displayNameFor(record),
          ),
      if (suggest.value && canSuggest.value)
        for (final record in records)
          if (_wantsSuggestion(analyzed[record.localId]))
            AnalyzeJob(
              id: 'suggest:${record.localId}',
              localId: record.localId,
              step: AnalyzeStep.suggest,
              displayName: displayNameFor(record),
            ),
    ];
  }

  /// A photo the vendor hasn't been asked about. Once it has, the answer
  /// waits in the review list, and a photo whose answer was dismissed is
  /// never asked about again — paying twice for the same "no" is the one
  /// unforgivable thing a queue that spends money can do.
  bool _wantsSuggestion(AiPhotoAnalysis? analysis) =>
      analysis != null && !analysis.hasSuggestions && !analysis.reviewed;

  Future<List<AssetRecord>> _activeRecords() async {
    final all = await assetRecordStore.listAll();
    return all
        .where(
          (r) =>
              !r.isDeleted &&
              !r.isHidden &&
              r.passcodeHash == null &&
              !r.localDeleted,
        )
        .toList();
  }

  // ---------------------------------------------------------------- running

  /// Runs until there's nothing left or it's paused. A second call joins
  /// the drain already running rather than starting another set of workers.
  ///
  /// [rescan] puts a re-read of the camera roll at the head of the pass
  /// whatever [scanEvery] says — what coming back from Photos means, where
  /// the whole point is that something may have changed over there while
  /// we weren't looking.
  Future<void> start({bool rescan = false}) =>
      _start(rescan: rescan, analyse: true);

  /// The scheduled version. Two different things follow the schedule here,
  /// and only one of them is analysis: the camera roll is re-read whenever
  /// the app comes back ([rescan]), because a photo taken while we were
  /// away isn't in the library at all until it is — "Manual Only" is about
  /// not *looking* at photos unasked, not about pretending new ones don't
  /// exist.
  Future<void> startIfDue({bool rescan = false}) async {
    await load();
    if (paused.value) return;
    final due = _isDue();
    if (!due && !rescan) return;
    await _start(rescan: rescan, analyse: due);
  }

  bool _isDue() {
    final interval = switch (frequency.value) {
      SyncFrequency.manual => null,
      SyncFrequency.every15Minutes => const Duration(minutes: 15),
      SyncFrequency.everyHour => const Duration(hours: 1),
      SyncFrequency.every6Hours => const Duration(hours: 6),
      SyncFrequency.daily => const Duration(days: 1),
    };
    if (interval == null) return false;
    final last = _lastRunAt;
    return last == null || DateTime.now().difference(last) >= interval;
  }

  Future<void>? _drain;

  Future<void> _start({required bool rescan, required bool analyse}) async {
    await load();
    if (paused.value) return;
    if (rescan) _scannedAt = null;
    final inFlight = _drain;
    if (inFlight != null) return inFlight;
    final future = _run(analyse: analyse);
    _drain = future;
    try {
      await future;
    } finally {
      _drain = null;
    }
  }

  Future<void> _run({required bool analyse}) async {
    running.value = true;
    try {
      await refresh();
      while (!paused.value) {
        final batch = jobs.value
            .where(
              (job) =>
                  job.status == AnalyzeJobStatus.pending &&
                  (analyse || job.step == AnalyzeStep.scanLibrary),
            )
            .take(pace.value)
            .toList();
        if (batch.isEmpty) break;
        _mark(batch, AnalyzeJobStatus.running);
        await Future.wait(batch.map(_runOne));
        // A breath between batches. See [rest].
        if (!paused.value) await Future<void>.delayed(rest);
        await refresh();
      }
      // Only a pass that actually looked at photos resets the clock — a
      // scan-only trip would otherwise keep pushing the next real pass out
      // of reach.
      if (analyse) {
        _lastRunAt = DateTime.now();
        await _write(lastRunKey, _lastRunAt!.toIso8601String());
      }
    } finally {
      running.value = false;
    }
  }

  void _mark(List<AnalyzeJob> batch, AnalyzeJobStatus status) {
    final ids = batch.map((job) => job.id).toSet();
    jobs.value = [
      for (final job in jobs.value)
        if (ids.contains(job.id)) job.copyWith(status: status) else job,
    ];
  }

  Future<void> _runOne(AnalyzeJob job) async {
    try {
      switch (job.step) {
        case AnalyzeStep.scanLibrary:
          await scanLibrary();
          _scannedAt = DateTime.now();
        case AnalyzeStep.findFaces:
          await _findFaces(job);
        case AnalyzeStep.suggest:
          await _suggestFor(job);
      }
      _mark([job], AnalyzeJobStatus.done);
    } catch (e) {
      jobs.value = [
        for (final row in jobs.value)
          if (row.id == job.id)
            row.copyWith(status: AnalyzeJobStatus.failed, note: '$e')
          else
            row,
      ];
    }
  }

  Future<void> _findFaces(AnalyzeJob job) async {
    final record = await assetRecordStore.getByLocalId(job.localId!);
    if (record == null) return;
    final path = await resolvePath(record);
    // Nothing on disk to look at yet — a cloud-only photo, or one Photos
    // is still exporting. Left for a later pass rather than failed.
    if (path == null) return;
    await onDeviceAnalysis.analyze(record, path);
  }

  Future<void> _suggestFor(AnalyzeJob job) async {
    final vision = aiVision;
    if (vision == null) return;
    final record = await assetRecordStore.getByLocalId(job.localId!);
    if (record == null) return;
    final path = await resolvePath(record);
    if (path == null) return;
    final analysis = await vision.analyze(
      localId: record.localId,
      imageFile: File(path),
    );
    // Nothing worth asking about: marked answered so the photo never costs
    // a second call to be told the same thing.
    if (!analysis.hasSuggestions) {
      await analysisStore.markReviewed(record.localId);
      return;
    }
    await analysisStore.saveSuggestion(analysis);
  }

  void dispose() {
    jobs.dispose();
    running.dispose();
    paused.dispose();
    pace.dispose();
    frequency.dispose();
    suggest.dispose();
    canSuggest.dispose();
    remaining.dispose();
  }
}
