import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import '../storage/bucket_object.dart';
import '../upload/bucket_flagged.dart';
import '../upload/bucket_leftovers.dart';
import '../vault/object_key.dart' show fitsProtocol;
import 'fix_rates.dart';
import 'record_fixer.dart';
import 'storage_advice.dart';
import 'storage_optimizer.dart';

/// What is wrong with a flagged item — one filter chip each. Space on this
/// phone first, then the bucket.
enum FlagProblem {
  onDevice,
  largeFile,
  highResolution,
  optimizableFormat,
  offProtocol,
  orphanThumbnail,
  unclaimed,
  likelyLeftover,
  duplicate,
  noThumbnail,
  missingFromBucket,
  leftoverCopy,
  extraCopies,
  liveHalf,
}

/// One way of dealing with a flag — one batch button each.
enum FlagSolution {
  backUp,
  optimize,
  optimizeRemote,
  removeDuplicate,
  removeFromDevice,
  import,
  rename,
  reformat,
  removeThumbnail,
  removeOldCopy,
  removeBucketDuplicate,
  ignore,
  importAnyway,
  makeThumbnail,
  getFromPhotos,
  removeFromLibrary,
  finishOptimize,
  removeExtraCopies,
  removeImportCopy,
  attachLiveHalf;

  bool get onDevice => _storageFix != null;

  /// Done to the library's own record, by [RecordFixer].
  bool get onRecord =>
      this == makeThumbnail ||
      this == getFromPhotos ||
      this == removeFromLibrary ||
      this == finishOptimize ||
      this == removeExtraCopies ||
      this == removeImportCopy;

  /// Which section it is listed under: what it changes, not what it is
  /// about. Optimize in the bucket is about a photo, and changes the bucket.
  bool get inBucket => (!onDevice && !onRecord) || this == optimizeRemote;

  StorageFix? get _storageFix => switch (this) {
    backUp => StorageFix.backUpFirst,
    removeFromDevice => StorageFix.removeFromDevice,
    optimize => StorageFix.optimize,
    optimizeRemote => StorageFix.optimizeRemote,
    removeDuplicate => StorageFix.removeDuplicate,
    _ => null,
  };

  static FlagSolution of(StorageFix fix) =>
      values.firstWhere((s) => s._storageFix == fix);
}

/// One row of the Flagged Items page: a photo with space to give back, or
/// a bucket object the app doesn't understand.
class Flag {
  Flag._({
    required this.id,
    required this.problems,
    required this.solutions,
    this.oneAtATime = const {},
    this.storage,
    this.bucket,
    this.asset,
    this._bytes = 0,
    this._name = '',
  });

  factory Flag.storage(StorageItem item) => Flag._(
    id: storageFlagId(item.record.localId),
    problems: {
      for (final issue in item.issues)
        switch (issue) {
          StorageIssue.onDevice => FlagProblem.onDevice,
          StorageIssue.largeFile => FlagProblem.largeFile,
          StorageIssue.highResolution => FlagProblem.highResolution,
          StorageIssue.optimizableFormat => FlagProblem.optimizableFormat,
          StorageIssue.duplicate => FlagProblem.duplicate,
        },
    },
    solutions: [for (final fix in item.fixes) FlagSolution.of(fix)],
    storage: item,
  );

  factory Flag.bucket(FlaggedObject object, {bool reformatable = false}) {
    final duplicate = object.likelyDuplicateOf != null;
    return Flag._(
      id: bucketFlagId(object.object),
      problems: {
        switch (object.kind) {
          FlagKind.offProtocol => FlagProblem.offProtocol,
          FlagKind.orphanThumbnail => FlagProblem.orphanThumbnail,
          FlagKind.unclaimed => FlagProblem.unclaimed,
          FlagKind.likelyLeftover ||
          FlagKind.oldCopy => FlagProblem.likelyLeftover,
          FlagKind.duplicate => FlagProblem.duplicate,
          FlagKind.liveHalf => FlagProblem.liveHalf,
        },
      },
      solutions: switch (object.kind) {
        FlagKind.orphanThumbnail => [FlagSolution.removeThumbnail],
        FlagKind.oldCopy => [FlagSolution.removeOldCopy, FlagSolution.ignore],
        FlagKind.duplicate => [
          FlagSolution.removeBucketDuplicate,
          FlagSolution.ignore,
        ],
        FlagKind.unclaimed => [FlagSolution.import],
        FlagKind.liveHalf => [FlagSolution.attachLiveHalf, FlagSolution.ignore],
        FlagKind.likelyLeftover => [
          FlagSolution.ignore,
          FlagSolution.importAnyway,
        ],
        FlagKind.offProtocol => [
          if (duplicate) FlagSolution.ignore,
          FlagSolution.rename,
          if (reformatable) FlagSolution.reformat,
        ],
      },
      // A guess either way, so a person looks at each: an old copy, or a
      // file the same size as one already here. A video's old copy may be
      // another phone's only clip of the moment.
      oneAtATime: {
        FlagSolution.importAnyway,
        if (duplicate) FlagSolution.rename,
        if (object.isVideo && object.kind == FlagKind.oldCopy)
          FlagSolution.removeOldCopy,
      },
      bucket: object,
    );
  }

  /// A cloud-only record and its [RecordScan] problem.
  factory Flag.asset(
    AssetRecord record, {
    required FlagProblem problem,
    required List<FlagSolution> solutions,
    int bytes = 0,
    String name = '',
  }) => Flag._(
    id: assetFlagId(problem, record.localId),
    problems: {problem},
    solutions: solutions,
    asset: record,
    bytes: bytes,
    name: name,
  );

  final String id;
  final Set<FlagProblem> problems;

  /// The first is what the row's own button does.
  final List<FlagSolution> solutions;
  final Set<FlagSolution> oneAtATime;

  final StorageItem? storage;
  final FlaggedObject? bucket;
  final AssetRecord? asset;
  final int _bytes;
  final String _name;

  /// The record behind a photo flag, either kind.
  AssetRecord? get record => storage?.record ?? asset;

  bool batchable(FlagSolution s) =>
      solutions.contains(s) && !oneAtATime.contains(s);

  int get bytes => storage?.bytes ?? bucket?.object.size ?? _bytes;
  int get saving => storage?.estimatedSaving ?? 0;
  String get name => storage?.name ?? bucket?.name ?? _name;
  DateTime get date =>
      record?.createdAt ?? bucket!.takenAt ?? bucket!.object.lastModified;
}

/// What a flag was detected from: the same id found again from the same
/// facts is the same finding, a changed one is new.
String flagFingerprint(Flag f) {
  if (f.bucket case final b?) {
    return '${b.kind.name}|${b.object.size}|'
        '${b.object.lastModified.millisecondsSinceEpoch}';
  }
  final r = f.record;
  if (r == null) return '';
  final original = r.stateOf(DerivativeKind.original);
  return [
    r.updatedAt.millisecondsSinceEpoch,
    r.localDeleted,
    r.localOptimized,
    r.isDeleted,
    original.status.name,
    original.destinationKey,
    r.thumbnailPath,
    f.bytes,
  ].join('|');
}

String storageFlagId(String localId) => 'asset:$localId';
String assetFlagId(FlagProblem problem, String localId) =>
    '${problem.name}:$localId';
String bucketFlagId(BucketObject o) => 'bucket:${o.targetId}|${o.key}';

enum FixJobState { waiting, running, failed }

enum FixFailure { failed, needsAlbum, unverified }

class FixJob {
  const FixJob(
    this.flag,
    this.solution,
    this.state, {
    this.failure,
    this.detail,
  });

  final Flag flag;
  final FlagSolution solution;
  final FixJobState state;
  final FixFailure? failure;
  final String? detail;

  FixJob withState(FixJobState state, {FixFailure? failure, String? detail}) =>
      FixJob(flag, solution, state, failure: failure, detail: detail);
}

/// Runs the fixes asked for on the Flagged Items page, one after another,
/// whether or not the page is open.
///
/// Owned by the library screen, so leaving the page doesn't stop it. The
/// waiting jobs are filed in app state, so a kill doesn't lose them either:
/// [resume] picks them up on the next launch. Unlike the analyze queue this
/// can't be re-derived — which of several fixes a person chose is a choice,
/// not a fact about the library.
///
/// While iOS has the app suspended nothing runs; it carries on where it
/// was when the app comes back.
class FixQueue extends ChangeNotifier {
  FixQueue({
    required this.store,
    required this.advisor,
    required this.optimizer,
    required this.fixer,
    required this.refreshBucket,
    this.records,
  });

  final AssetRecordStore store;
  final StorageAdvisor advisor;
  final StorageOptimizer optimizer;
  final BucketFixer fixer;
  final Future<void> Function() refreshBucket;

  /// Null where nothing wires it (most tests): its flags aren't found, and
  /// a resumed one fails.
  final RecordFixer? records;

  static const _stateKey = 'fix_queue_v1';

  /// A removal is one iOS confirmation per batch, and the bucket check is
  /// one listing per batch; the re-encodes are slow, so their batches stay
  /// small enough for the list to visibly drain.
  static int _batchOf(FlagSolution s) => switch (s) {
    FlagSolution.backUp => 500,
    // Each batch of camera-roll photos is one iOS prompt, so as many as
    // one prompt takes.
    FlagSolution.removeFromDevice ||
    FlagSolution.optimize ||
    FlagSolution.removeDuplicate => 100,
    _ => 10,
  };

  static const _keptKey = 'flag_kept_v1';

  /// Photos somebody chose to keep as they are. Never offered again.
  Set<String> _kept = {};
  bool _keptLoaded = false;

  Future<void> loadKept() async {
    if (_keptLoaded) return;
    _keptLoaded = true;
    try {
      final raw = await store.getAppState(_keptKey);
      if (raw != null) {
        _kept = {..._kept, ...(jsonDecode(raw) as List).cast<String>()};
      }
    } catch (_) {
      // Unreadable: offered again, which loses nothing.
    }
    try {
      final raw = await store.getAppState(_resolvedKey);
      if (raw != null) {
        for (final MapEntry(:key, :value)
            in (jsonDecode(raw) as Map).cast<String, dynamic>().entries) {
          _resolved.putIfAbsent(
            key,
            () => (
              at: (value as Map)['at'] as int? ?? 0,
              fp: value['fp'] as String?,
            ),
          );
        }
      }
    } catch (_) {
      // Unreadable: a fix whose finding the scan still makes is offered
      // again; nothing is lost.
    }
    try {
      final raw = await store.getAppState(_failuresKey);
      if (raw != null) {
        final read = (jsonDecode(raw) as Map).cast<String, String>();
        for (final MapEntry(:key, :value) in read.entries) {
          _failureLog.putIfAbsent(key, () => value);
        }
      }
    } catch (_) {}
  }

  bool isKept(Flag flag) => _kept.contains(flag.id);

  /// Hide from List: off the list, now and on every later scan. A bucket
  /// file is also left out of detection, as [FlagSolution.ignore] does.
  Future<void> keep(Iterable<Flag> flags) async {
    await loadKept();
    _kept.addAll(flags.map((f) => f.id));
    final keys = [
      for (final f in flags)
        if (f.bucket case final b?) b.object.key,
    ];
    if (keys.isNotEmpty) await IgnoredBucketKeys(store).addAll(keys);
    notifyListeners();
    await store.setAppState(_keptKey, jsonEncode([..._kept]));
  }

  final LinkedHashMap<String, FixJob> _jobs = LinkedHashMap();

  static const _resolvedKey = 'fix_resolved_v1';
  static const _failuresKey = 'fix_failures_v1';

  /// Ids with their solution (`id#solution`) fixed, when, and the
  /// [flagFingerprint] the first scan after found it with (null before).
  /// Keyed by solution because Back Up First comes back as Remove from
  /// Device once the upload lands — the same photo, a new flag. Persisted:
  /// a relaunch doesn't bring back what was fixed. [settle] drops an entry
  /// once the scan agrees, or finds the item again from new facts.
  final Map<String, ({int at, String? fp})> _resolved = {};

  bool _settled(String key, Flag flag) => switch (_resolved[key]) {
    null => false,
    (fp: null, at: _) => true,
    (:final fp, at: _) => fp == flagFingerprint(flag),
  };

  /// Squares the fixed list with a scan begun at [startedAt] that
  /// found [detected], before anything was filtered out of it.
  Future<void> settle(Iterable<Flag> detected, DateTime startedAt) async {
    await loadKept();
    final byId = {for (final f in detected) f.id: f};
    final since = startedAt.millisecondsSinceEpoch;
    var changed = false;
    for (final MapEntry(:key, :value) in _resolved.entries.toList()) {
      // Fixed while that scan ran: it can't speak for the fix.
      if (value.at >= since) continue;
      final cut = key.lastIndexOf('#');
      final flag = byId[key.substring(0, cut)];
      final solution = key.substring(cut + 1);
      if (flag == null || !flag.solutions.any((s) => s.name == solution)) {
        _resolved.remove(key);
        changed = true;
      } else if (value.fp == null) {
        _resolved[key] = (at: value.at, fp: flagFingerprint(flag));
        changed = true;
      } else if (value.fp != flagFingerprint(flag)) {
        _resolved.remove(key);
        changed = true;
      }
    }
    final stale = [
      for (final id in _failureLog.keys)
        if (!byId.containsKey(id) && _jobs[id] == null) id,
    ];
    for (final id in stale) {
      _failureLog.remove(id);
    }
    if (!changed && stale.isEmpty) return;
    notifyListeners();
    await _saveResolved();
    if (stale.isNotEmpty) await _saveFailures();
  }

  Future<void> _saveResolved() => store.setAppState(
    _resolvedKey,
    jsonEncode({
      for (final MapEntry(:key, :value) in _resolved.entries)
        key: {'at': value.at, 'fp': value.fp},
    }),
  );

  Future<void> _saveFailures() =>
      store.setAppState(_failuresKey, jsonEncode(_failureLog));

  /// Failed the last time it was run, this launch or before, and not
  /// done since.
  bool failedBefore(String id) =>
      _jobs[id]?.state == FixJobState.failed ||
      (_jobs[id] == null && _failureLog.containsKey(id));

  int done = 0;
  int total = 0;

  /// What the run is doing this moment: which file, how big, and to it.
  FixStep? step;

  void _setStep(Flag flag, FixAction action) {
    step = FixStep(name: flag.name, bytes: flag.bytes, action: action);
    notifyListeners();
  }

  /// Filed for the one iOS prompt, by flag id, with the job when this run
  /// filed it. Off the list (the banner covers them) until it's answered.
  final Map<String, FixJob?> _filed = {};

  /// Originals filed and not yet asked about: the Flagged Items banner.
  int swapsWaiting = 0;

  /// Whether this run ends with the prompt: only one somebody started. A
  /// run picked up at launch leaves its swaps to the banner.
  bool _promptAtEnd = false;

  int get progressed => done;
  int freedBytes = 0;
  final Set<String> _failedThisRun = {};
  bool _pumping = false;
  bool _stopping = false;

  Map<String, FixJob> get jobs => UnmodifiableMapView(_jobs);
  bool get running => _pumping;
  bool get stopping => _stopping;
  int get left => total - done;
  int get failed => _failedThisRun.length;

  /// A run that has ended and not yet been dismissed.
  bool get finished => !_pumping && total > 0;

  bool isResolved(Flag flag) =>
      _kept.contains(flag.id) ||
      _filed.containsKey(flag.id) ||
      flag.solutions.any((s) => _settled('${flag.id}#${s.name}', flag));

  /// Somebody asked: the run ends with the one prompt.
  void enqueue(Iterable<Flag> flags, FlagSolution solution) {
    _promptAtEnd = true;
    _enqueue(flags, solution);
  }

  void _enqueue(Iterable<Flag> flags, FlagSolution solution) {
    if (!_pumping) _resetRun();
    for (final flag in flags) {
      // Done, or waiting on the prompt: never queued twice.
      if (isResolved(flag)) continue;
      final existing = _jobs[flag.id];
      if (existing != null && existing.state != FixJobState.failed) continue;
      _failedThisRun.remove(flag.id);
      _jobs[flag.id] = FixJob(flag, solution, FixJobState.waiting);
      total++;
    }
    notifyListeners();
    unawaited(_persist());
    unawaited(_pump());
  }

  /// Ends the run after the batch in flight. What hadn't started is
  /// dropped: still flagged, and offered again.
  void stop() {
    if (!_pumping) return;
    _stopping = true;
    final before = _jobs.length;
    _jobs.removeWhere((_, job) => job.state == FixJobState.waiting);
    total -= before - _jobs.length;
    notifyListeners();
    unawaited(_persist());
  }

  /// Clears the finished run's summary.
  void dismiss() {
    if (_pumping) return;
    _resetRun();
    notifyListeners();
  }

  void _resetRun() {
    _jobs.removeWhere((_, job) => job.state != FixJobState.failed);
    done = 0;
    total = 0;
    freedBytes = 0;
    _failedThisRun.clear();
  }

  late final FixRates rates = FixRates(store);

  /// How long [flags] should take under [solution], from what this phone
  /// has timed so far: by size for re-encodes and uploads, by count for
  /// the rest. Photos and videos are timed apart.
  Duration estimate(FlagSolution solution, Iterable<Flag> flags) {
    final byKind = <String, List<Flag>>{};
    for (final f in flags) {
      (byKind[_rateKind(solution, f)] ??= []).add(f);
    }
    var total = Duration.zero;
    for (final MapEntry(key: kind, value: group) in byKind.entries) {
      final video = kind.endsWith(':video');
      total += rates.estimate(
        kind,
        bySize: _bySize(solution),
        bytes: group.fold(0, (sum, f) => sum + f.bytes),
        items: group.length,
        perItem: _defaultPerItem(solution),
        bytesPerSecond: _defaultRate(solution, video: video),
      );
    }
    return total;
  }

  static String _rateKind(FlagSolution s, Flag f) => _bySize(s)
      ? '${s.name}:${(f.storage?.record.isVideo ?? f.bucket?.isVideo ?? false) ? 'video' : 'photo'}'
      : s.name;

  static bool _bySize(FlagSolution s) => switch (s) {
    FlagSolution.optimize ||
    FlagSolution.optimizeRemote ||
    FlagSolution.reformat ||
    FlagSolution.backUp => true,
    _ => false,
  };

  /// Before anything is timed: modest guesses, erring long.
  static double _defaultRate(FlagSolution s, {required bool video}) =>
      switch (s) {
        FlagSolution.optimize => video ? 15e6 : 4e6,
        FlagSolution.optimizeRemote => video ? 4e6 : 2e6,
        FlagSolution.reformat => 1e6,
        _ => 3e6,
      };

  static Duration _defaultPerItem(FlagSolution s) => switch (s) {
    FlagSolution.ignore => const Duration(milliseconds: 10),
    FlagSolution.removeThumbnail => const Duration(milliseconds: 150),
    // A video's frame is streamed from the bucket by iOS.
    FlagSolution.makeThumbnail => const Duration(milliseconds: 1500),
    FlagSolution.getFromPhotos ||
    FlagSolution.removeFromLibrary ||
    FlagSolution.finishOptimize ||
    FlagSolution.removeExtraCopies ||
    FlagSolution.removeImportCopy ||
    FlagSolution.attachLiveHalf => const Duration(milliseconds: 100),
    _ => const Duration(milliseconds: 300),
  };

  /// Asks the one prompt for every filed original: the banner's button.
  void finishPending() {
    _promptAtEnd = true;
    unawaited(_pump());
  }

  Future<void> _countSwaps() async {
    final swaps = await optimizer.pendingSwaps();
    final flags = {for (final s in swaps) s.flag ?? storageFlagId(s.localId)};
    _filed.removeWhere((id, _) => !flags.contains(id));
    for (final id in flags) {
      _filed.putIfAbsent(id, () => null);
    }
    if (swaps.length == swapsWaiting) return;
    swapsWaiting = swaps.length;
    notifyListeners();
  }

  Future<void> resume() async {
    await loadKept();
    await rates.load();
    // A quit between the last fix and the delete prompt: the banner asks,
    // never a system sheet at launch with nothing to explain it.
    await _countSwaps();
    final raw = await store.getAppState(_stateKey);
    if (raw == null) return;
    List<Map<String, dynamic>> rows;
    try {
      rows = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
    } catch (_) {
      return;
    }
    if (rows.isEmpty) return;

    final storage = {
      for (final item in (await advisor.cached()).items)
        storageFlagId(item.record.localId): item,
    };
    final bucketRows = rows.where((r) => r['kind'] != null);
    if (bucketRows.isNotEmpty) {
      // A rename finished just before the kill left its old name in the
      // index; a fresh listing drops it rather than renaming it twice.
      try {
        await refreshBucket();
      } catch (_) {
        // Offline: the fixes themselves will say so, item by item.
      }
    }
    final objects = {
      for (final o in await store.listBucketObjects()) bucketFlagId(o): o,
    };
    final assets = await store.getByLocalIds([
      for (final r in rows)
        if (r['localId'] case final String id) id,
    ]);

    final grouped = <FlagSolution, List<Flag>>{};
    for (final row in rows) {
      final solution = FlagSolution.values.asNameMap()[row['solution']];
      if (solution == null) continue;
      final id = row['id'] as String;
      Flag? flag;
      if (solution.onRecord) {
        final record = assets[row['localId']];
        final problem = FlagProblem.values.asNameMap()[row['problem']];
        if (record != null && !_offLimits(record) && problem != null) {
          flag = Flag.asset(
            record,
            problem: problem,
            solutions: [solution],
            bytes: row['bytes'] as int? ?? 0,
            name: row['name'] as String? ?? '',
          );
        }
      } else if (solution.onDevice) {
        final item = storage[id];
        // Only if that is still the fix on offer: a photo backed up since
        // has moved on to the next one.
        if (item != null && item.fixes.contains(solution._storageFix)) {
          flag = Flag.storage(item);
        }
      } else {
        final object = objects[id];
        final kind = FlagKind.values.asNameMap()[row['kind']];
        if (object != null && kind != null) {
          flag = Flag.bucket(
            FlaggedObject(
              object: object,
              kind: kind,
              takenAt: DateTime.tryParse(row['takenAt'] as String? ?? ''),
              likelyDuplicateOf: row['duplicateOf'] as String?,
              ownerId: row['ownerId'] as String?,
            ),
            reformatable: solution == FlagSolution.reformat,
          );
        }
      }
      if (flag != null) (grouped[solution] ??= []).add(flag);
    }
    for (final MapEntry(key: solution, value: flags) in grouped.entries) {
      _enqueue(flags, solution);
    }
    if (grouped.isEmpty) await _persist();
  }

  /// Hidden, locked or binned since the scan: no fix touches it.
  static bool _offLimits(AssetRecord r) =>
      r.isDeleted || r.isLocked || r.isHidden || r.passcodeHash != null;

  /// [ids]' records as they are now; null for one that is gone or
  /// [_offLimits].
  Future<Map<String, AssetRecord>> _fresh(Iterable<String> ids) async => {
    for (final r in (await store.getByLocalIds(ids)).values)
      if (!_offLimits(r)) r.localId: r,
  };

  Future<void> _persist() => store.setAppState(
    _stateKey,
    jsonEncode([
      for (final job in _jobs.values)
        if (job.state != FixJobState.failed)
          {
            'id': job.flag.id,
            'solution': job.solution.name,
            if (job.flag.bucket case final b?) ...{
              'kind': b.kind.name,
              'takenAt': b.takenAt?.toIso8601String(),
              'duplicateOf': b.likelyDuplicateOf,
              'ownerId': ?b.ownerId,
            },
            if (job.flag.asset case final r?) ...{
              'localId': r.localId,
              'problem': job.flag.problems.first.name,
              'bytes': job.flag.bytes,
              'name': job.flag.name,
            },
          },
    ]),
  );

  Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;
    var touchedBucket = false;
    try {
      while (!_stopping) {
        final batch = _nextBatch();
        if (batch.isEmpty) {
          if (_promptAtEnd) {
            _promptAtEnd = false;
            await _finishSwaps();
          }
          // Jobs queued while the prompt was up run too.
          if (_stopping || _nextBatch().isEmpty) break;
          continue;
        }
        for (final job in batch) {
          _jobs[job.flag.id] = job.withState(FixJobState.running);
        }
        notifyListeners();
        final clock = Stopwatch()..start();
        if (batch.first.solution.onRecord) {
          await Future.wait(batch.map(_runOnRecord));
        } else if (batch.first.solution == FlagSolution.optimizeRemote) {
          touchedBucket = true;
          await _runRemoteOptimize(batch);
        } else if (batch.first.solution.onDevice) {
          await _runOnDevice(batch);
        } else {
          touchedBucket = true;
          // Each is a few round trips to the bucket, nearly all waiting.
          await Future.wait(batch.map(_runInBucket));
        }
        await _time(batch, clock.elapsed);
        await _persist();
        await _countSwaps();
      }
    } finally {
      await _remeasureTouched();
      _pumping = false;
      _stopping = false;
      _promptAtEnd = false;
      step = null;
      notifyListeners();
    }
    if (touchedBucket) {
      try {
        await refreshBucket();
      } catch (_) {
        // The next Rescan lists it.
      }
    }
  }

  static const _bucketParallel = 8;

  /// Each thumbnail is a stream from the bucket; fewer at once than a
  /// rename.
  static const _recordParallel = 4;

  static bool _isVideo(FixJob job) => job.flag.storage?.record.isVideo ?? false;

  List<FixJob> _nextBatch() {
    final waiting = _jobs.values.where((j) => j.state == FixJobState.waiting);
    if (waiting.isEmpty) return const [];
    final solution = waiting.first.solution;
    if (!solution.onDevice) {
      // One at a time where each is a person's call; otherwise a few in
      // flight together.
      if (waiting.first.flag.oneAtATime.contains(solution)) {
        return [waiting.first];
      }
      return waiting
          .where(
            (j) =>
                j.solution == solution && !j.flag.oneAtATime.contains(solution),
          )
          .take(solution.onRecord ? _recordParallel : _bucketParallel)
          .toList();
    }
    // Videos apart from photos, and few at a time: one compression can take
    // minutes, and a hundred photos shouldn't wait behind them.
    final video = _isVideo(waiting.first);
    final mixed = solution != FlagSolution.optimize;
    return waiting
        .where((j) => j.solution == solution && (mixed || _isVideo(j) == video))
        .take(!mixed && video ? 10 : _batchOf(solution))
        .toList();
  }

  /// What a filed swap may have been filed by.
  static const _swapSolutions = [
    FlagSolution.optimize,
    FlagSolution.removeDuplicate,
    FlagSolution.finishOptimize,
    FlagSolution.removeExtraCopies,
  ];

  /// Every original the run replaced or found duplicated, out of Photos in
  /// one prompt once everything else is done — not one prompt per batch.
  /// Reported by the flag each was filed under; a flag with several swaps
  /// is fixed only when all of them are.
  Future<void> _finishSwaps() async {
    final swaps = await optimizer.pendingSwaps();
    if (swaps.isEmpty) return _countSwaps();
    step = FixStep(
      name: '',
      bytes: swaps.fold(0, (sum, s) => sum + s.oldBytes),
      action: FixAction.confirming,
    );
    notifyListeners();
    final ids = <String>{};
    final outcomes = <String, Set<StorageItemOutcome>>{};
    try {
      final result = await optimizer.finishSwaps(
        onItem: (swap, outcome) {
          ids.add(swap.localId);
          (outcomes[swap.flag ?? storageFlagId(swap.localId)] ??= {}).add(
            outcome,
          );
        },
      );
      freedBytes += result.freedBytes;
    } catch (_) {
      // Still filed: the banner asks again.
    }
    for (final MapEntry(key: id, value: seen) in outcomes.entries) {
      final job = _filed.remove(id);
      if (seen.every((o) => o == StorageItemOutcome.freed)) {
        for (final s in job == null ? _swapSolutions : [job.solution]) {
          _markResolved('$id#${s.name}');
        }
        if (_failureLog.remove(id) != null) unawaited(_saveFailures());
        continue;
      }
      final unverified = seen.contains(StorageItemOutcome.unverified);
      // Left filed when the bucket didn't answer: still the banner's.
      if (unverified) _filed[id] = job;
      if (job == null) continue;
      _jobs[id] = job.withState(
        FixJobState.failed,
        failure: unverified ? FixFailure.unverified : FixFailure.failed,
        detail: unverified ? null : 'kept in Photos',
      );
      _failedThisRun.add(id);
    }
    await _countSwaps();
    notifyListeners();
    _touched.addAll(ids);
  }

  /// Photos a run changed, re-measured once when it ends rather than per
  /// batch: each is a read and rewrite of the whole storage scan.
  final Set<String> _touched = {};

  Future<void> _remeasureTouched() async {
    if (_touched.isEmpty) return;
    final ids = {..._touched};
    _touched.clear();
    try {
      await advisor.remeasure(await advisor.cached(), ids);
    } catch (_) {
      // The cache catches up on the next scan.
    }
  }

  /// Files how long [batch] took, per kind, for [estimate]. A batch mixing
  /// photos and videos is split by bytes.
  Future<void> _time(List<FixJob> batch, Duration took) async {
    final byKind = <String, List<Flag>>{};
    for (final job in batch) {
      (byKind[_rateKind(job.solution, job.flag)] ??= []).add(job.flag);
    }
    final all = batch.fold(0, (sum, j) => sum + j.flag.bytes);
    for (final MapEntry(key: kind, value: flags) in byKind.entries) {
      final bytes = flags.fold(0, (sum, f) => sum + f.bytes);
      final share = byKind.length == 1 || all == 0
          ? took
          : took * (bytes / all);
      await rates.record(kind, took: share, bytes: bytes, items: flags.length);
    }
  }

  /// One at a time: each is a re-encode on the phone and an upload.
  Future<void> _runRemoteOptimize(List<FixJob> batch) async {
    for (final job in batch) {
      if (_stopping) break;
      final record = job.flag.storage!.record;
      File? smaller;
      try {
        final fresh = (await _fresh([record.localId]))[record.localId];
        if (fresh == null) {
          _skip(job.flag.id);
          continue;
        }
        _setStep(job.flag, FixAction.optimizing);
        smaller = await optimizer.smallerFile(
          fresh,
          fromBucket: (path) async {
            _setStep(job.flag, FixAction.downloading);
            final got = await fixer.downloadOriginal(fresh, path);
            _setStep(job.flag, FixAction.optimizing);
            return got;
          },
        );
        if (smaller == null && optimizer.smallestAlready) {
          await advisor.markRemoteOptimized(record.localId);
          _resolve(job.flag.id);
          continue;
        }
        if (smaller == null) {
          _fail(
            job.flag.id,
            FixFailure.failed,
            detail: optimizer.smallerFileProblem ?? 'no smaller copy',
          );
          continue;
        }
        _setStep(job.flag, FixAction.uploading);
        final result = await fixer.replaceRemoteOriginal(record, smaller);
        if (result.ok) {
          await advisor.markRemoteOptimized(record.localId);
          _resolve(job.flag.id);
        } else {
          _fail(job.flag.id, FixFailure.failed, detail: result.detail);
        }
      } catch (e) {
        _fail(job.flag.id, FixFailure.failed, detail: '$e');
      } finally {
        try {
          await smaller?.delete();
        } catch (_) {}
      }
    }
  }

  Future<void> _runOnDevice(List<FixJob> asked) async {
    final fresh = await _fresh([
      for (final job in asked) job.flag.storage!.record.localId,
    ]);
    final batch = <FixJob>[];
    for (final job in asked) {
      // Cloud-only since the scan has no copy here to fix either.
      if (fresh[job.flag.storage!.record.localId] case final r?
          when worthMeasuring(r)) {
        batch.add(job);
      } else {
        _skip(job.flag.id);
      }
    }
    if (batch.isEmpty) return;
    final reported = <String>{};
    final smallest = <String>[];
    final byId = {for (final job in batch) job.flag.id: job.flag};
    try {
      final result = await optimizer.apply(
        [
          for (final job in batch)
            job.flag.storage!
                .withRecord(fresh[job.flag.storage!.record.localId]!)
                .withFix(job.solution._storageFix!),
        ],
        deferDeletes: true,
        onStep: (localId, action) {
          if (byId[storageFlagId(localId)] case final flag?) {
            _setStep(flag, action);
          }
        },
        onPrepared: (localId) {
          final id = storageFlagId(localId);
          reported.add(id);
          _fileJob(id);
        },
        onItem: (localId, outcome) {
          final id = storageFlagId(localId);
          reported.add(id);
          switch (outcome) {
            case StorageItemOutcome.freed:
            case StorageItemOutcome.queued:
              _resolve(id);
            case StorageItemOutcome.unverified:
              _fail(id, FixFailure.unverified);
            case StorageItemOutcome.skipped:
              if (optimizer.notSmaller.remove(localId)) {
                smallest.add(localId);
                _resolve(id);
              } else {
                _fail(id, FixFailure.failed);
              }
          }
        },
      );
      freedBytes += result.freedBytes;
    } catch (_) {
      // Whatever didn't report below fails with it.
    }
    for (final job in batch) {
      if (!reported.contains(job.flag.id)) {
        _fail(job.flag.id, FixFailure.failed);
      }
    }
    try {
      await advisor.markSmallestAlready(smallest);
    } catch (_) {
      // Offered again, and found not smaller again.
    }
    _touched.addAll([
      for (final job in batch) job.flag.storage!.record.localId,
    ]);
  }

  Future<void> _runInBucket(FixJob job) async {
    final object = job.flag.bucket!;
    if (switch (job.solution) {
          FlagSolution.rename => FixAction.renaming,
          FlagSolution.import ||
          FlagSolution.importAnyway ||
          FlagSolution.attachLiveHalf => FixAction.adding,
          FlagSolution.reformat => FixAction.converting,
          FlagSolution.removeThumbnail ||
          FlagSolution.removeOldCopy ||
          FlagSolution.removeBucketDuplicate => FixAction.deleting,
          _ => null,
        }
        case final action?) {
      _setStep(job.flag, action);
    }
    FixResult result;
    try {
      result = switch (job.solution) {
        FlagSolution.import => await fixer.adopt(object),
        FlagSolution.attachLiveHalf => await fixer.attachLiveHalf(object),
        FlagSolution.rename => await fixer.rename(object),
        FlagSolution.reformat => await fixer.reformat(object),
        FlagSolution.removeThumbnail => await fixer.removeOrphan(object),
        FlagSolution.removeOldCopy ||
        FlagSolution.removeBucketDuplicate => await fixer.removeOldCopy(object),
        FlagSolution.importAnyway =>
          fitsProtocol(object.name)
              ? await fixer.adopt(object)
              : await fixer.rename(object),
        FlagSolution.ignore => await _ignore(object),
        _ => const FixResult(FixOutcome.failed),
      };
    } catch (e) {
      result = FixResult(FixOutcome.failed, detail: '$e');
    }
    if (result.ok) {
      _resolve(job.flag.id);
    } else {
      _fail(
        job.flag.id,
        result.outcome == FixOutcome.needsAlbum
            ? FixFailure.needsAlbum
            : FixFailure.failed,
        detail: result.detail,
      );
    }
  }

  Future<void> _runOnRecord(FixJob job) async {
    final record = (await _fresh([
      job.flag.asset!.localId,
    ]))[job.flag.asset!.localId];
    if (record == null) return _skip(job.flag.id);
    _setStep(job.flag, switch (job.solution) {
      FlagSolution.makeThumbnail => FixAction.downloading,
      FlagSolution.getFromPhotos => FixAction.adding,
      _ => FixAction.deleting,
    });
    final fixer = records;
    FixResult result;
    try {
      result = fixer == null
          ? const FixResult(FixOutcome.failed)
          : switch (job.solution) {
              FlagSolution.makeThumbnail => await fixer.makeThumbnail(record),
              FlagSolution.getFromPhotos => await fixer.getFromPhotos(record),
              FlagSolution.removeFromLibrary => await fixer.removeFromLibrary(
                record,
              ),
              FlagSolution.finishOptimize || FlagSolution.removeExtraCopies =>
                await fixer.finishOptimize(record, flag: job.flag.id),
              FlagSolution.removeImportCopy => await fixer.removeImportCopy(
                record,
              ),
              _ => const FixResult(FixOutcome.failed),
            };
    } catch (e) {
      result = FixResult(FixOutcome.failed, detail: '$e');
    }
    if (result.outcome == FixOutcome.filed) {
      _fileJob(job.flag.id);
    } else if (result.ok) {
      _resolve(job.flag.id);
    } else {
      _fail(job.flag.id, FixFailure.failed, detail: result.detail);
    }
  }

  /// Library-side only: the bucket keeps the file, and no scan offers it
  /// again.
  Future<FixResult> _ignore(FlaggedObject object) async {
    await IgnoredBucketKeys(store).addAll([object.object.key]);
    return const FixResult(FixOutcome.removed);
  }

  /// Filed for the prompt: counted as progress, decided by [_finishSwaps].
  void _fileJob(String id) {
    final job = _jobs.remove(id);
    if (job == null) return;
    _filed[id] = job;
    done++;
    notifyListeners();
  }

  /// Hidden, locked or binned since the scan: dropped, not fixed, and off
  /// the list, which no longer has anything to offer for it.
  void _skip(String id) => _resolve(id);

  void _resolve(String id) {
    final job = _jobs.remove(id);
    if (job == null) return;
    _markResolved('$id#${job.solution.name}');
    if (_failureLog.remove(id) != null) unawaited(_saveFailures());
    done++;
    notifyListeners();
  }

  void _markResolved(String key) {
    _resolved[key] = (at: DateTime.now().millisecondsSinceEpoch, fp: null);
    unawaited(_saveResolved());
  }

  /// Failures and why, until fixed or no longer found: shown on the list
  /// after a relaunch, and readable off the phone for a bug report.
  final Map<String, String> _failureLog = {};

  void _fail(String id, FixFailure failure, {String? detail}) {
    final job = _jobs[id];
    if (job == null || job.state == FixJobState.failed) return;
    _failureLog[id] = '${job.solution.name}: ${failure.name} ${detail ?? ''}';
    unawaited(_saveFailures());
    _jobs[id] = job.withState(
      FixJobState.failed,
      failure: failure,
      detail: detail,
    );
    done++;
    _failedThisRun.add(id);
    notifyListeners();
  }
}

class FixStep {
  const FixStep({
    required this.name,
    required this.bytes,
    required this.action,
  });

  final String name;
  final int bytes;
  final FixAction action;
}
