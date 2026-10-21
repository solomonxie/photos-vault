import 'dart:async';

import 'package:flutter/foundation.dart';

import '../settings/backup_targets_store.dart' show SyncFrequency;
import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import 'ai_analysis.dart';
import 'ai_analysis_store.dart';
import 'face_identity.dart';
import 'face_matcher.dart' show ConfirmedFace;
import 'on_device_analysis.dart';
import 'on_device_vision.dart' show FaceDescriptor;
import 'person.dart' show FaceRect;

/// What one unit of work in the analyze pass actually does.
///
/// Re-reading the camera roll isn't one of them: it's nobody's choice and
/// nobody's cost, so it runs out of sight in `library_scanner.dart` rather
/// than as a row here that can be paced and paused.
enum AnalyzeStep {
  /// Look for faces on the phone. Free, offline, and the only thing this
  /// app can learn about a photo without asking anyone for money.
  findFaces,

  /// Remember what an already-named person looks like, from a photo that
  /// can only be about them. Catches up a library where people were named
  /// long before the app could recognise anybody — without it, every
  /// person already in the list contributes nothing and nothing is ever
  /// suggested.
  learnFaces,

  /// Work out who the faces in a photo might be, from the faces already
  /// named. Free and offline, like [findFaces] — and useless until
  /// somebody has been named once, which is why it runs after it.
  matchFaces,
}

/// [skipped]: nothing to work from yet (no file on the phone, a face not
/// described). Still outstanding; the next run tries again.
enum AnalyzeJobStatus { pending, running, done, skipped, failed }

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

  /// The photo this is about.
  final String? localId;

  final AnalyzeStep step;
  final String displayName;
  final AnalyzeJobStatus status;

  /// Why a failed job failed, in the user's words rather than an exception's.
  final String? note;

  bool get isFinished =>
      status == AnalyzeJobStatus.done ||
      status == AnalyzeJobStatus.skipped ||
      status == AnalyzeJobStatus.failed;

  AnalyzeJob copyWith({AnalyzeJobStatus? status, String? note}) => AnalyzeJob(
    id: id,
    localId: localId,
    step: step,
    displayName: displayName,
    status: status ?? this.status,
    note: note ?? this.note,
  );
}

/// The slow pass over the library for face recognition: find faces, learn
/// named people, match the rest. Nothing else runs here. Finding the photos
/// in the first place is `library_scanner.dart`'s job, not this one's.
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
    required this.resolvePath,
    required this.displayNameFor,
    Future<String?> Function(AssetRecord record)? resolveSource,
    this.faceIdentity,
    this.taggedPeople,
    this.taggedPeopleOf,
    this.rest = const Duration(milliseconds: 400),
  }) : resolveSource = resolveSource ?? resolvePath;

  final AssetRecordStore assetRecordStore;
  final AiAnalysisStore analysisStore;
  final OnDeviceAnalysisService onDeviceAnalysis;

  /// A photo's file on disk — `null` for one the library can't produce
  /// right now, which is a skip rather than a failure.
  final Future<String?> Function(AssetRecord record) resolvePath;

  /// What Vision reads for a photo: a camera-roll asset rendered natively
  /// (`OnDeviceVisionService.assetSource`), or a file. [resolvePath]
  /// when not given.
  final Future<String?> Function(AssetRecord record) resolveSource;

  /// What a row is called. Injected so the queue never has to know about
  /// localization or which photos are hidden.
  final String Function(AssetRecord record) displayNameFor;

  /// Puts names to faces across photos. Absent, faces are still found —
  /// they just stay anonymous, which is where this app started.
  final FaceIdentityService? faceIdentity;

  /// Who is already tagged in each photo, `localId` → person ids. Feeds
  /// [AnalyzeStep.learnFaces]. Absent, the backfill simply doesn't run.
  final Future<Map<String, List<String>>> Function()? taggedPeople;

  /// Who is tagged in one photo, read fresh per job. Absent, the whole
  /// [taggedPeople] map is read instead.
  final Future<List<String>> Function(String localId)? taggedPeopleOf;

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

  final ValueNotifier<List<AnalyzeJob>> jobs = ValueNotifier(const []);
  final ValueNotifier<bool> running = ValueNotifier(false);
  final ValueNotifier<bool> paused = ValueNotifier(false);
  final ValueNotifier<int> pace = ValueNotifier(1);

  /// Manual until asked otherwise — looking at photos costs battery. The
  /// camera-roll *scan* still runs on open whatever this says (see
  /// [startIfDue]): a photo taken while the app was away isn't in the
  /// library at all until it does.
  final ValueNotifier<SyncFrequency> frequency = ValueNotifier(
    SyncFrequency.manual,
  );

  /// Everything still outstanding, including what didn't fit in [jobs].
  final ValueNotifier<int> remaining = ValueNotifier(0);

  /// Why the face model didn't load, when it didn't (05#5). Faces are then
  /// described by the fallback and kept; nothing restarts over it.
  final ValueNotifier<String?> faceModelProblem = ValueNotifier(null);

  static const pausedKey = 'analyze_paused';
  static const paceKey = 'analyze_pace';
  static const frequencyKey = 'analyze_frequency';
  static const lastRunKey = 'analyze_last_run_at';

  bool _loaded = false;

  /// When the pass last looked at photos. Persisted, because "every six
  /// hours" has to mean something across a restart.
  DateTime? _lastRunAt;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      paused.value = await assetRecordStore.getAppState(pausedKey) == 'true';
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
  }

  Future<void> setPaused(bool value) async {
    await load();
    paused.value = value;
    await _write(pausedKey, value ? 'true' : 'false');
    if (!value) {
      _listCleared = false;
      unawaited(start());
    }
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

  Future<void> _write(String key, String value) async {
    try {
      await assetRecordStore.setAppState(key, value);
    } catch (_) {
      // See [load].
    }
  }

  /// Set by [clear], lifted by resuming. Holds the *list* empty; the
  /// count is left alone, because how much work is outstanding is a fact
  /// about the library and emptying a list on screen doesn't change it.
  bool _listCleared = false;

  /// Rebuilds the list from what's actually outstanding. Cheap enough to
  /// call whenever something might have changed — it's three queries and a
  /// filter, not a pass over the photos themselves.
  Future<void> refresh() async {
    await load();
    _backlog = await _outstanding();
    _backlogIds = {for (final spec in _backlog) spec.id};
    _refreshedAt = DateTime.now();
    _publish();
  }

  /// Everything outstanding, in order: worked out once per [refresh] and
  /// then patched per batch ([_advance]), not re-derived from the whole
  /// library every 0.4 s.
  List<_Spec> _backlog = [];
  Set<String> _backlogIds = {};
  DateTime? _refreshedAt;
  List<AssetRecord>? _records;

  /// What [_outstanding] read, kept to re-derive a photo after its batch.
  Map<String, AiPhotoAnalysis> _analyzed = {};
  Map<String, List<FaceRect>> _faces = {};
  Set<String> _matched = {};
  Set<String> _learned = {};
  Map<String, List<String>> _tagged = const {};

  /// Job ids this run has had a go at — see [_run].
  Set<String> _attempted = {};

  /// [jobs] from the head of [_backlog]: only the rows shown get a name.
  void _publish() {
    remaining.value = _backlog.length;
    if (_listCleared) {
      jobs.value = const [];
      return;
    }
    // What this run already tried is left off the head, so a run of photos
    // that can't be done yet never fills it (05#6).
    final head = [
      for (final spec
          in _backlog.where((s) => !_attempted.contains(s.id)).take(capacity))
        AnalyzeJob(
          id: spec.id,
          localId: spec.record.localId,
          step: spec.step,
          displayName: displayNameFor(spec.record),
        ),
    ];
    final ids = {for (final job in head) job.id};
    jobs.value = [
      ...head,
      // What just happened stays on screen under what's next: a pass that
      // erases its own work as it goes looks like a pass that did nothing.
      ...jobs.value
          .where((job) => job.isFinished && !ids.contains(job.id))
          .take(_finishedShown),
    ];
  }

  /// After a batch: what the batch's photos still owe, worked out from
  /// what they just did, in their old place. A library that moved (a scan,
  /// a delete) is patched at most twice a minute ([_patchRecords]), and
  /// read whole again ([refresh]) at most every [_fullEvery].
  Future<void> _advance(List<AnalyzeJob> batch) async {
    try {
      final all = await assetRecordStore.listAll();
      final now = DateTime.now();
      if (libraryDelta(_records, all).shape) {
        if (now.difference(_refreshedAt ?? DateTime(0)) >= _fullEvery) {
          return await refresh();
        }
        if (now.difference(_patchedAt ?? DateTime(0)) >=
            const Duration(seconds: 30)) {
          _patchRecords(all);
          _patchedAt = now;
        }
      }
    } catch (_) {
      // Patched from what is known.
    }
    for (final job in batch) {
      final id = job.localId!;
      if (job.status == AnalyzeJobStatus.done) {
        switch (job.step) {
          case AnalyzeStep.findFaces:
            try {
              final analysis = await analysisStore.get(id);
              if (analysis != null) _analyzed[id] = analysis;
              if (faceIdentity != null) {
                final faces = await analysisStore.facesFor(id);
                if (faces.isEmpty) {
                  _faces.remove(id);
                } else {
                  _faces[id] = faces;
                }
              }
            } catch (_) {
              // Left as it was; the next refresh reads it again.
            }
          case AnalyzeStep.learnFaces:
            _learned.add(id);
          case AnalyzeStep.matchFaces:
            _matched.add(id);
        }
      }
    }
    final photos = {for (final job in batch) job.localId!};
    final backlog = _backlog;
    for (final id in photos) {
      // Near the head: batches are taken from it.
      final at = backlog.indexWhere((s) => s.record.localId == id);
      if (at == -1) continue;
      var end = at;
      while (end < backlog.length && backlog[end].record.localId == id) {
        _backlogIds.remove(backlog[end].id);
        end++;
      }
      final next = _specsFor(backlog[at].record);
      backlog.replaceRange(at, end, next);
      _backlogIds.addAll(next.map((s) => s.id));
    }
    _publish();
  }

  static const _fullEvery = Duration(minutes: 5);
  DateTime? _patchedAt;

  /// [all]'s added, changed and removed photos, without re-reading the
  /// analysis tables: an unchanged row keeps its record instance, so only
  /// those not identical to the last read are derived again; the rest keep
  /// their specs. The analysis maps may lag writes made elsewhere since the
  /// last [refresh]; each step re-checks the database before it acts
  /// ([_findFaces], [_learnFaces]), and a stale "owed" is a skip at worst.
  void _patchRecords(List<AssetRecord> all) {
    final before = _byId;
    final byPhoto = <String, List<_Spec>>{};
    for (final spec in _backlog) {
      (byPhoto[spec.record.localId] ??= []).add(spec);
    }
    final backlog = <_Spec>[];
    final byId = <String, AssetRecord>{};
    for (var i = all.length - 1; i >= 0; i--) {
      final r = all[i];
      byId[r.localId] = r;
      if (identical(before[r.localId], r)) {
        backlog.addAll(byPhoto[r.localId] ?? const []);
      } else if (r.isVisibleInLibrary && !r.localDeleted) {
        backlog.addAll(_specsFor(r));
      }
    }
    _records = all;
    _byId = byId;
    _backlog = backlog;
    _backlogIds = {for (final spec in backlog) spec.id};
  }

  /// [_records] by id, for [_patchRecords].
  Map<String, AssetRecord> _byId = {};

  /// Throws away everything the free pass has ever worked out — the faces
  /// it found and the names it guessed — so the next run walks the whole
  /// library again, newest first.
  ///
  /// Not what Empty Queue does. That drops a list; this drops the answers
  /// the list is derived from, which is the only thing that makes an
  /// already-looked-at photo worth looking at again.
  ///
  /// Confirmed faces survive — those are the user's answers, not the
  /// app's.
  Future<void> rescanAll() async {
    await load();
    try {
      await analysisStore.forgetFaces();
    } catch (_) {
      // No analysis database — nothing was worked out to throw away.
    }
    _confirmed = null;
    _listCleared = false;
    await refresh();
    unawaited(start());
  }

  /// Empties the list and stops, leaving it empty until somebody hits
  /// Resume — which is when it's built again, from scratch and in whatever
  /// the current order is.
  ///
  /// Pausing is the point, not a side effect. The outstanding half of this
  /// list is derived from the library, so a clear that didn't stop would
  /// refill in the same frame and look like a button that does nothing.
  ///
  /// Nothing analyzed is lost — a photo already looked at doesn't come
  /// back — and [remaining] still says how much there is to do, because
  /// emptying a list on screen doesn't change the size of the job.
  Future<void> clear() async {
    _listCleared = true;
    await setPaused(true);
    jobs.value = const [];
  }

  Future<List<_Spec>> _outstanding() async {
    List<AssetRecord> records;
    try {
      records = await _activeRecords();
      _analyzed = Map.of(await analysisStore.listAll());
    } catch (_) {
      return [];
    }
    _faces = {};
    _matched = {};
    _learned = {};
    _tagged = const {};
    if (faceIdentity != null) {
      try {
        _faces = Map.of(await analysisStore.facesByAsset());
        _matched = Set.of(await analysisStore.matchedAssets())
          ..removeAll(
            // Described in a space this build no longer speaks. Worth
            // another look, or they sit there being incomparable.
            await analysisStore.staleDescriptorAssets(
              faceIdentity!.livePipelines,
            ),
          );
        _learned = Set.of(await analysisStore.assetsWithDescriptors());
        _tagged = await taggedPeople?.call() ?? const {};
      } catch (_) {
        // No analysis database — nothing to match against either.
      }
    }
    // One photo at a time, all of its steps together, newest first —
    // rather than the whole library's faces, then the whole library's
    // matching. Three library-wide passes meant the second never started
    // until the first had finished: on a real camera roll, thousands of
    // photos were scanned for faces while not one of them was described,
    // so "who else looks like this?" had nothing to compare and every
    // face came back alone.
    //
    // The cost is that an early guess is made against fewer confirmed
    // faces than a late one. That is what naming somebody re-opening
    // every unanswered guess is for.
    return [for (final record in records) ..._specsFor(record)];
  }

  List<_Spec> _specsFor(AssetRecord record) {
    final id = record.localId;
    final analysis = _analyzed[id];
    if (record.isVideo) return const [];
    // Boxes still to be turned upright: nothing else of this photo runs
    // alongside, or it would write under the old boxes.
    if (analysis != null && analysis.legacyBoxes) {
      return [(step: AnalyzeStep.findFaces, record: record)];
    }
    return [
      if (analysis == null || analysis.needsLookingAt)
        (step: AnalyzeStep.findFaces, record: record),
      // One face, one person, or nothing. iOS won't say whose face is
      // whose, so a group shot with three faces and one name in it
      // can't say which of the three is theirs — and a reference set
      // built on a guess makes every later guess worse.
      if (_faces[id]?.length == 1 &&
          _tagged[id]?.length == 1 &&
          !_learned.contains(id))
        (step: AnalyzeStep.learnFaces, record: record),
      if (_faces.containsKey(id) && !_matched.contains(id))
        (step: AnalyzeStep.matchFaces, record: record),
    ];
  }

  /// Newest photo first. The backlog on a fresh install is the whole
  /// camera roll and this pass takes all week by design, so the order
  /// decides what gets faces and captions today: the photos from this
  /// month, which are the ones anybody is going to open. The rest is
  /// enqueued behind them and gets there eventually.
  Future<List<AssetRecord>> _activeRecords() async {
    final all = _records = await assetRecordStore.listAll();
    _byId = {for (final r in all) r.localId: r};
    // `listAll` is oldest first already: walked backwards, not re-sorted.
    return [
      for (var i = all.length - 1; i >= 0; i--)
        if (all[i].isVisibleInLibrary && !all[i].localDeleted) all[i],
    ];
  }

  // ---------------------------------------------------------------- running

  /// Runs until there's nothing left or it's paused. A second call joins
  /// the drain already running rather than starting another set of workers.
  Future<void> start() => _start();

  /// The scheduled version: nothing happens unless the frequency says it's
  /// due, and "Manual" means it never is. New photos still arrive whatever
  /// this says — that's `library_scanner.dart`, which this queue neither
  /// owns nor gates.
  Future<void> startIfDue() async {
    await load();
    if (paused.value) return;
    if (!_isDue()) return;
    await _start();
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

  /// Photos actually looked at by the pass that just finished. Lets a
  /// caller tell "faces were found, the People row is out of date" from
  /// "there was nothing to do" — without it, a pass can fill the database
  /// with faces that nothing on screen ever reads.
  int analyzedInLastRun = 0;

  Future<void>? _drain;

  Future<void> _start() async {
    await load();
    if (paused.value) return;
    final inFlight = _drain;
    if (inFlight != null) return inFlight;
    final future = _run();
    _drain = future;
    try {
      await future;
    } finally {
      _drain = null;
    }
  }

  Future<void> _run() async {
    running.value = true;
    analyzedInLastRun = 0;
    _confirmed = null;
    _attempted = {};
    try {
      await _checkFaceModel();
      await refresh();
      // What this run has already had a go at.
      //
      // The list is *derived* — [refresh] rebuilds it from what's still
      // outstanding — so a job that didn't clear comes straight back as
      // pending: a photo whose file couldn't be resolved, one that threw,
      // one Vision found nothing in. Without this the loop picks the same
      // row again on the next pass, and again, and never reaches the
      // second photo. Newest-first made it obvious (it's always the same
      // familiar picture), but it would spin on the oldest just as hard.
      //
      // Per run, not persisted: the next run should try them again, and by
      // then the iCloud download may have finished.
      final attempted = _attempted;
      while (!paused.value) {
        final batch = jobs.value
            .where(
              (job) =>
                  job.status == AnalyzeJobStatus.pending &&
                  !attempted.contains(job.id),
            )
            .take(pace.value)
            .toList();
        if (batch.isEmpty) break;
        attempted.addAll(batch.map((job) => job.id));
        _mark(batch, AnalyzeJobStatus.running);
        await Future.wait(batch.map(_runOne));
        // Out before the refresh, not after: pausing mid-batch and then
        // rebuilding the list would put back the rows that Empty Queue
        // has just taken off the screen.
        if (paused.value) break;
        // A breath between batches. See [rest].
        await Future<void>.delayed(rest);
        await _advance([
          for (final job in jobs.value)
            if (batch.any((b) => b.id == job.id)) job,
        ]);
      }
      _lastRunAt = DateTime.now();
      await _write(lastRunKey, _lastRunAt!.toIso8601String());
    } finally {
      _attempted = {};
      running.value = false;
    }
  }

  /// Once per run. Without the model the fallback's space is the live one,
  /// so its faces are kept rather than re-described forever (05#5).
  Future<void> _checkFaceModel() async {
    final identity = faceIdentity;
    if (identity == null) return;
    String? problem;
    try {
      problem = await identity.vision.faceModelFailure;
    } catch (_) {
      problem = null;
    }
    faceModelProblem.value = problem;
    identity.livePipelines = problem == null
        ? FaceDescriptor.livePipelines
        : FaceDescriptor.livePipelinesWithoutModel;
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
      final did = switch (job.step) {
        AnalyzeStep.findFaces => await _findFaces(job),
        AnalyzeStep.learnFaces => await _learnFaces(job),
        AnalyzeStep.matchFaces => await _matchFaces(job),
      };
      if (!did) {
        _mark([job], AnalyzeJobStatus.skipped);
        return;
      }
      analyzedInLastRun++;
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

  /// Each step says whether it did anything; false is a skip.
  Future<bool> _findFaces(AnalyzeJob job) async {
    final record = await assetRecordStore.getByLocalId(job.localId!);
    if (record == null) return true;
    // Fresh, not [_analyzed]: a patched backlog can hold a photo analysed
    // elsewhere since the last [refresh].
    AiPhotoAnalysis? existing;
    try {
      existing = await analysisStore.get(record.localId);
    } catch (_) {
      // Read below from what the last refresh saw.
    }
    existing ??= _analyzed[record.localId];
    if (existing != null && !existing.needsLookingAt && !existing.legacyBoxes) {
      return true;
    }
    // Old boxes are turned by the file's own EXIF orientation, which only
    // the file has: those keep the file, once.
    final legacy = existing?.legacyBoxes ?? false;
    final path = legacy
        ? await resolvePath(record)
        : await resolveSource(record);
    // Nothing on disk to look at yet — a cloud-only photo, or one Photos
    // is still exporting. Left for a later pass rather than failed.
    if (path == null) return false;
    if (existing != null && !existing.needsLookingAt && legacy) {
      return onDeviceAnalysis.settleBoxes(record, path);
    }
    return await onDeviceAnalysis.analyze(record, path) != null;
  }

  /// The reference set, read once per run rather than per photo — it only
  /// changes when somebody is named, and that restarts the pass anyway.
  List<ConfirmedFace>? _confirmed;

  Future<bool> _learnFaces(AnalyzeJob job) async {
    final identity = faceIdentity;
    if (identity == null) return true;
    final record = await assetRecordStore.getByLocalId(job.localId!);
    if (record == null) return true;
    final faces = await analysisStore.facesFor(record.localId);
    final people = taggedPeopleOf != null
        ? await taggedPeopleOf!(record.localId)
        : (await taggedPeople?.call())?[record.localId];
    // Re-checked rather than trusted from the list: it was built before
    // this batch, and somebody may have been tagged since.
    if (faces.length != 1 || people?.length != 1) return true;
    final saved = await identity.remember(
      record: record,
      face: faces.single,
      personId: people!.single,
    );
    // The reference set just grew, so the guesses made without it are
    // worth making again.
    if (saved) _confirmed = null;
    return saved;
  }

  Future<bool> _matchFaces(AnalyzeJob job) async {
    final identity = faceIdentity;
    if (identity == null) return true;
    final record = await assetRecordStore.getByLocalId(job.localId!);
    if (record == null) return true;
    final faces = await analysisStore.facesFor(record.localId);
    if (faces.isEmpty) return true;
    final confirmed = _confirmed ??= await analysisStore.confirmedFaces();
    return identity.suggestFor(
      record: record,
      faces: faces,
      confirmed: confirmed,
    );
  }

  void dispose() {
    jobs.dispose();
    running.dispose();
    paused.dispose();
    pace.dispose();
    frequency.dispose();
    remaining.dispose();
    faceModelProblem.dispose();
  }
}

typedef _Spec = ({AnalyzeStep step, AssetRecord record});

extension on _Spec {
  String get id =>
      '${switch (step) {
        AnalyzeStep.findFaces => 'faces',
        AnalyzeStep.learnFaces => 'learn',
        AnalyzeStep.matchFaces => 'match',
      }}:${record.localId}';
}
