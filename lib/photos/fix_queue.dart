import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../storage/asset_record_store.dart';
import '../storage/bucket_object.dart';
import '../upload/bucket_flagged.dart';
import '../upload/bucket_leftovers.dart';
import '../vault/object_key.dart' show fitsProtocol;
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
}

/// One way of dealing with a flag — one batch button each.
enum FlagSolution {
  backUp,
  removeFromDevice,
  reduceResolution,
  convertFormat,
  import,
  rename,
  reformat,
  removeThumbnail,
  ignore,
  importAnyway;

  bool get onDevice => _storageFix != null;

  StorageFix? get _storageFix => switch (this) {
    backUp => StorageFix.backUpFirst,
    removeFromDevice => StorageFix.removeFromDevice,
    reduceResolution => StorageFix.reduceResolution,
    convertFormat => StorageFix.convertFormat,
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
        },
    },
    solutions: [FlagSolution.of(item.fix)],
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
          FlagKind.likelyLeftover => FlagProblem.likelyLeftover,
        },
      },
      solutions: switch (object.kind) {
        FlagKind.orphanThumbnail => [FlagSolution.removeThumbnail],
        FlagKind.unclaimed => [FlagSolution.import],
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
      // file the same size as one already here.
      oneAtATime: {
        FlagSolution.importAnyway,
        if (duplicate) FlagSolution.rename,
      },
      bucket: object,
    );
  }

  final String id;
  final Set<FlagProblem> problems;

  /// The first is what the row's own button does.
  final List<FlagSolution> solutions;
  final Set<FlagSolution> oneAtATime;

  final StorageItem? storage;
  final FlaggedObject? bucket;

  bool batchable(FlagSolution s) =>
      solutions.contains(s) && !oneAtATime.contains(s);

  int get bytes => storage?.bytes ?? bucket!.object.size;
  int get saving => storage?.estimatedSaving ?? 0;
  String get name => storage?.name ?? bucket!.name;
  DateTime get date =>
      storage?.record.createdAt ??
      bucket!.takenAt ??
      bucket!.object.lastModified;
}

String storageFlagId(String localId) => 'asset:$localId';
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
  });

  final AssetRecordStore store;
  final StorageAdvisor advisor;
  final StorageOptimizer optimizer;
  final BucketFixer fixer;
  final Future<void> Function() refreshBucket;

  static const _stateKey = 'fix_queue_v1';

  /// A removal is one iOS confirmation per batch, and the bucket check is
  /// one listing per batch; the re-encodes are slow, so their batches stay
  /// small enough for the list to visibly drain.
  static int _batchOf(FlagSolution s) => switch (s) {
    FlagSolution.backUp => 500,
    FlagSolution.removeFromDevice => 100,
    _ => 10,
  };

  final LinkedHashMap<String, FixJob> _jobs = LinkedHashMap();

  /// Ids with their solution (`id#solution`) fixed since launch. Keyed by
  /// solution because Back Up First comes back as Remove from Device once
  /// the upload lands — the same photo, a new flag.
  final Set<String> _resolved = {};

  int done = 0;
  int total = 0;
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
      flag.solutions.any((s) => _resolved.contains('${flag.id}#${s.name}'));

  void enqueue(Iterable<Flag> flags, FlagSolution solution) {
    if (!_pumping) _resetRun();
    for (final flag in flags) {
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

  Future<void> resume() async {
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

    final grouped = <FlagSolution, List<Flag>>{};
    for (final row in rows) {
      final solution = FlagSolution.values.asNameMap()[row['solution']];
      if (solution == null) continue;
      final id = row['id'] as String;
      Flag? flag;
      if (solution.onDevice) {
        final item = storage[id];
        // Only if that is still the fix on offer: a photo backed up since
        // has moved on to the next one.
        if (item != null && FlagSolution.of(item.fix) == solution) {
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
            ),
            reformatable: solution == FlagSolution.reformat,
          );
        }
      }
      if (flag != null) (grouped[solution] ??= []).add(flag);
    }
    for (final MapEntry(key: solution, value: flags) in grouped.entries) {
      enqueue(flags, solution);
    }
    if (grouped.isEmpty) await _persist();
  }

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
        if (batch.isEmpty) break;
        for (final job in batch) {
          _jobs[job.flag.id] = job.withState(FixJobState.running);
        }
        notifyListeners();
        if (batch.first.solution.onDevice) {
          await _runOnDevice(batch);
        } else {
          touchedBucket = true;
          for (final job in batch) {
            await _runInBucket(job);
          }
        }
        await _persist();
      }
    } finally {
      _pumping = false;
      _stopping = false;
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

  List<FixJob> _nextBatch() {
    final waiting = _jobs.values.where((j) => j.state == FixJobState.waiting);
    if (waiting.isEmpty) return const [];
    final solution = waiting.first.solution;
    if (!solution.onDevice) return [waiting.first];
    return waiting
        .where((j) => j.solution == solution)
        .take(_batchOf(solution))
        .toList();
  }

  Future<void> _runOnDevice(List<FixJob> batch) async {
    final reported = <String>{};
    try {
      final result = await optimizer.apply(
        [for (final job in batch) job.flag.storage!],
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
              _fail(id, FixFailure.failed);
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
      await advisor.remeasure(await advisor.cached(), {
        for (final job in batch) job.flag.storage!.record.localId,
      });
    } catch (_) {
      // The cache catches up on the next scan.
    }
  }

  Future<void> _runInBucket(FixJob job) async {
    final object = job.flag.bucket!;
    FixResult result;
    try {
      result = switch (job.solution) {
        FlagSolution.import => await fixer.adopt(object),
        FlagSolution.rename => await fixer.rename(object),
        FlagSolution.reformat => await fixer.reformat(object),
        FlagSolution.removeThumbnail => await fixer.removeOrphan(object),
        FlagSolution.importAnyway =>
          fitsProtocol(object.name)
              ? await fixer.adopt(object)
              : await fixer.rename(object),
        FlagSolution.ignore => await _ignore(object),
        _ => const FixResult(FixOutcome.failed),
      };
    } catch (_) {
      result = const FixResult(FixOutcome.failed);
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

  /// Library-side only: the bucket keeps the file, and no scan offers it
  /// again.
  Future<FixResult> _ignore(FlaggedObject object) async {
    await IgnoredBucketKeys(store).addAll([object.object.key]);
    return const FixResult(FixOutcome.removed);
  }

  void _resolve(String id) {
    final job = _jobs.remove(id);
    if (job == null) return;
    _resolved.add('$id#${job.solution.name}');
    done++;
    notifyListeners();
  }

  void _fail(String id, FixFailure failure, {String? detail}) {
    final job = _jobs[id];
    if (job == null || job.state == FixJobState.failed) return;
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
