import 'package:photos_vault/upload/sync_job.dart';
import 'package:photos_vault/upload/sync_job_store.dart';

/// Pure-Dart, in-memory stand-in for [SyncJobStore] — for widget tests.
///
/// Same reasoning as `FakeAssetRecordStore`: widget tests run in
/// `testWidgets`' fake-async zone, where real `sqflite_common_ffi` calls
/// (isolate round-trips) never resolve. Use the real ffi-backed store (via
/// a plain `test()`) to test [SyncJobStore] itself.
class FakeSyncJobStore implements SyncJobStore {
  final List<SyncJob> _jobs = [];
  var _nextId = 0;

  @override
  Future<void> close() async {}

  @override
  Future<SyncJob> enqueue({
    required String localId,
    required SyncJobKind kind,
    required String displayName,
    required DateTime assetCreatedAt,
  }) async {
    final outstanding = _jobs.where(
      (j) => j.localId == localId && j.kind == kind && !j.isFinished,
    );
    if (outstanding.isNotEmpty) return outstanding.first;
    final now = DateTime.now();
    final job = SyncJob(
      id: 'job-${_nextId++}',
      localId: localId,
      kind: kind,
      displayName: displayName,
      status: SyncJobStatus.pending,
      createdAt: now,
      updatedAt: now,
      assetCreatedAt: assetCreatedAt,
    );
    _jobs.add(job);
    return job;
  }

  @override
  Future<List<SyncJob>> all() async => List.unmodifiable(_jobs);

  @override
  Future<int> countWhere(Iterable<SyncJobStatus> statuses) async =>
      _jobs.where((j) => statuses.contains(j.status)).length;

  /// Newest photo first, like the real store's `ORDER BY
  /// asset_created_at DESC`.
  @override
  Future<SyncJob?> dequeueNextPending() async {
    var index = -1;
    for (var i = 0; i < _jobs.length; i++) {
      if (_jobs[i].status != SyncJobStatus.pending) continue;
      if (index < 0 ||
          _jobs[i].assetCreatedAt.isAfter(_jobs[index].assetCreatedAt)) {
        index = i;
      }
    }
    if (index < 0) return null;
    final claimed = _copy(_jobs[index], SyncJobStatus.running);
    _jobs[index] = claimed;
    return claimed;
  }

  @override
  Future<void> markDone(String id) async => _setStatus(id, SyncJobStatus.done);

  @override
  Future<void> markFailed(String id, String error) async =>
      _setStatus(id, SyncJobStatus.failed, error: error);

  @override
  Future<void> retry(String id) async => _setStatus(id, SyncJobStatus.pending);

  @override
  Future<void> clearQueue() async => _jobs.clear();

  @override
  Future<void> clearSynced() async =>
      _jobs.removeWhere((j) => j.status == SyncJobStatus.done);

  @override
  Future<void> trimHistory({int keepFinished = 40}) async {
    _jobs.removeWhere(
      (j) =>
          j.status == SyncJobStatus.failed &&
          j.kind == SyncJobKind.checkChanges,
    );
    final done = _jobs.where((j) => j.status == SyncJobStatus.done).toList();
    if (done.length <= keepFinished) return;
    for (final job in done.take(done.length - keepFinished)) {
      _jobs.remove(job);
    }
  }

  @override
  Future<void> requeueStaleRunning() async {
    for (var i = 0; i < _jobs.length; i++) {
      if (_jobs[i].status == SyncJobStatus.running) {
        _jobs[i] = _copy(_jobs[i], SyncJobStatus.pending);
      }
    }
  }

  void _setStatus(String id, SyncJobStatus status, {String? error}) {
    final index = _jobs.indexWhere((j) => j.id == id);
    if (index < 0) return;
    _jobs[index] = _copy(_jobs[index], status, error: error);
  }

  static SyncJob _copy(SyncJob job, SyncJobStatus status, {String? error}) =>
      SyncJob(
        id: job.id,
        localId: job.localId,
        kind: job.kind,
        displayName: job.displayName,
        status: status,
        errorMessage: error,
        createdAt: job.createdAt,
        updatedAt: DateTime.now(),
        assetCreatedAt: job.assetCreatedAt,
      );
}
