import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite/sqflite.dart'
    show Database, DatabaseFactory, OpenDatabaseOptions;
import 'package:uuid/uuid.dart';

import 'sync_job.dart';

/// Persisted sync queue. Deliberately its own database rather than another
/// table in `asset_record`'s: jobs are throwaway operational state with
/// their own lifecycle, and nothing needs a transaction spanning both.
class SyncJobStore {
  SyncJobStore({DatabaseFactory? databaseFactory, this._path, Uuid? uuid})
    : _databaseFactory = databaseFactory ?? sqflite.databaseFactory,
      _uuid = uuid ?? const Uuid();

  final DatabaseFactory _databaseFactory;
  final String? _path;
  final Uuid _uuid;

  Database? _db;

  static const _table = 'sync_job';

  Future<Database> _open() async {
    final existing = _db;
    if (existing != null) return existing;
    final path =
        _path ??
        p.join(await _databaseFactory.getDatabasesPath(), 'sync_jobs.db');
    final db = await _databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 2,
        onCreate: (db, version) => db.execute('''
          CREATE TABLE $_table (
            id TEXT PRIMARY KEY,
            local_id TEXT NOT NULL,
            kind TEXT NOT NULL,
            display_name TEXT NOT NULL,
            status TEXT NOT NULL,
            error_message TEXT,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            asset_created_at INTEGER NOT NULL DEFAULT 0
          )
        '''),
        // Rows queued before the drain went newest-first keep the epoch,
        // which sorts them behind everything queued since. They were the
        // oldest work anyway.
        onUpgrade: (db, from, to) async {
          if (from < 2) {
            await db.execute(
              'ALTER TABLE $_table '
              'ADD COLUMN asset_created_at INTEGER NOT NULL DEFAULT 0',
            );
          }
        },
      ),
    );
    _db = db;
    return db;
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }

  /// Adds a job unless one for the same asset+kind is already outstanding —
  /// tapping Sync Now twice shouldn't double every file. Returns the job,
  /// existing or new.
  ///
  /// A *failed* job counts as outstanding and is reset to pending rather
  /// than duplicated: a retry is what re-queueing a failure means, and
  /// inserting a second row instead would grow the queue by one dead entry
  /// per asset per sync until nothing else fit in it.
  Future<SyncJob> enqueue({
    required String localId,
    required SyncJobKind kind,
    required String displayName,
    required DateTime assetCreatedAt,
  }) async {
    final db = await _open();
    final existing = await db.query(
      _table,
      where: 'local_id = ? AND kind = ? AND status IN (?, ?, ?)',
      whereArgs: [
        localId,
        kind.name,
        SyncJobStatus.pending.name,
        SyncJobStatus.running.name,
        SyncJobStatus.failed.name,
      ],
      limit: 1,
    );
    if (existing.isNotEmpty) {
      final job = _fromRow(existing.first);
      if (job.status != SyncJobStatus.failed) return job;
      await retry(job.id);
      return SyncJob(
        id: job.id,
        localId: job.localId,
        kind: job.kind,
        displayName: job.displayName,
        status: SyncJobStatus.pending,
        createdAt: job.createdAt,
        updatedAt: DateTime.now(),
        assetCreatedAt: job.assetCreatedAt,
      );
    }

    final now = DateTime.now();
    final job = SyncJob(
      id: _uuid.v4(),
      localId: localId,
      kind: kind,
      displayName: displayName,
      status: SyncJobStatus.pending,
      createdAt: now,
      updatedAt: now,
      assetCreatedAt: assetCreatedAt,
    );
    await db.insert(_table, _toRow(job));
    return job;
  }

  Future<List<SyncJob>> all() async {
    final db = await _open();
    final rows = await db.query(_table, orderBy: 'created_at ASC');
    return rows.map(_fromRow).toList();
  }

  Future<int> countWhere(Iterable<SyncJobStatus> statuses) async {
    final db = await _open();
    final placeholders = List.filled(statuses.length, '?').join(', ');
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM $_table WHERE status IN ($placeholders)',
      statuses.map((s) => s.name).toList(),
    );
    return sqflite.Sqflite.firstIntValue(rows) ?? 0;
  }

  /// Claims the pending job for the newest photo — marked `running` inside
  /// the same transaction it's read in, so two workers can never take the
  /// same one.
  ///
  /// Newest-first, not oldest-first: the backlog on a real library is
  /// years deep, and the picture someone wants safe is the one they just
  /// took. Ties (same capture date, or rows from before the column
  /// existed) fall back to queue order.
  Future<SyncJob?> dequeueNextPending() async {
    final db = await _open();
    return db.transaction((txn) async {
      final rows = await txn.query(
        _table,
        where: 'status = ?',
        whereArgs: [SyncJobStatus.pending.name],
        orderBy: 'asset_created_at DESC, created_at ASC',
        limit: 1,
      );
      if (rows.isEmpty) return null;
      final job = _fromRow(rows.first);
      await txn.update(
        _table,
        {
          'status': SyncJobStatus.running.name,
          'updated_at': DateTime.now().millisecondsSinceEpoch,
        },
        where: 'id = ?',
        whereArgs: [job.id],
      );
      return SyncJob(
        id: job.id,
        localId: job.localId,
        kind: job.kind,
        displayName: job.displayName,
        status: SyncJobStatus.running,
        createdAt: job.createdAt,
        updatedAt: DateTime.now(),
        assetCreatedAt: job.assetCreatedAt,
      );
    });
  }

  Future<void> markDone(String id) => _setStatus(id, SyncJobStatus.done);

  Future<void> markFailed(String id, String error) =>
      _setStatus(id, SyncJobStatus.failed, error: error);

  /// Puts a failed job back in line.
  Future<void> retry(String id) => _setStatus(id, SyncJobStatus.pending);

  Future<void> _setStatus(
    String id,
    SyncJobStatus status, {
    String? error,
  }) async {
    final db = await _open();
    await db.update(
      _table,
      {
        'status': status.name,
        'error_message': error,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Empties the queue: waiting, failed, finished and in-flight alike.
  ///
  /// Running rows go too. A file mid-upload keeps going — the native
  /// transfer can't be called back — and the worker's own "done" write
  /// lands on a row that isn't there any more, which is a no-op. That
  /// beats the alternative, where Empty Queue leaves rows on screen and
  /// reads as a button that didn't work.
  ///
  /// Nothing about the assets changes: whatever was queued just gets
  /// queued again by the next manual or scheduled sync.
  Future<void> clearQueue() async {
    final db = await _open();
    await db.delete(_table);
  }

  /// Clears the finished-successfully rows so the list stops growing,
  /// leaving anything still pending/running/failed visible.
  Future<void> clearSynced() async {
    final db = await _open();
    await db.delete(
      _table,
      where: 'status = ?',
      whereArgs: [SyncJobStatus.done.name],
    );
  }

  /// Keeps the history short and drops failures nothing can act on.
  ///
  /// Two kinds of row pile up. Finished ones, which are a receipt nobody
  /// reads past the last few dozen — a queue of two hundred green ticks is
  /// a log, and the one row that matters is lost in it. And failed
  /// *change-checks*, which ask "is this photo different from the copy in
  /// the bucket?" — a question with no answer when the file has gone, and
  /// nothing to retry: the backup already up there is still good.
  Future<void> trimHistory({int keepFinished = 40}) async {
    final db = await _open();
    await db.delete(
      _table,
      where: 'status = ? AND kind = ?',
      whereArgs: [SyncJobStatus.failed.name, SyncJobKind.checkChanges.name],
    );
    final rows = await db.query(
      _table,
      columns: ['id'],
      where: 'status = ?',
      whereArgs: [SyncJobStatus.done.name],
      orderBy: 'updated_at DESC',
    );
    if (rows.length <= keepFinished) return;
    final stale = rows.skip(keepFinished).map((r) => r['id'] as String);
    final placeholders = List.filled(stale.length, '?').join(', ');
    await db.delete(
      _table,
      where: 'id IN ($placeholders)',
      whereArgs: stale.toList(),
    );
  }

  /// A crash mid-sync leaves rows stuck as `running` with no worker behind
  /// them — put them back in line at startup rather than stranding them.
  Future<void> requeueStaleRunning() async {
    final db = await _open();
    await db.update(
      _table,
      {
        'status': SyncJobStatus.pending.name,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'status = ?',
      whereArgs: [SyncJobStatus.running.name],
    );
  }

  static Map<String, Object?> _toRow(SyncJob job) => {
    'id': job.id,
    'local_id': job.localId,
    'kind': job.kind.name,
    'display_name': job.displayName,
    'status': job.status.name,
    'error_message': job.errorMessage,
    'created_at': job.createdAt.millisecondsSinceEpoch,
    'updated_at': job.updatedAt.millisecondsSinceEpoch,
    'asset_created_at': job.assetCreatedAt.millisecondsSinceEpoch,
  };

  static SyncJob _fromRow(Map<String, Object?> row) => SyncJob(
    id: row['id'] as String,
    localId: row['local_id'] as String,
    kind: SyncJobKind.values.byName(row['kind'] as String),
    displayName: row['display_name'] as String,
    status: SyncJobStatus.values.byName(row['status'] as String),
    errorMessage: row['error_message'] as String?,
    createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int),
    updatedAt: DateTime.fromMillisecondsSinceEpoch(row['updated_at'] as int),
    assetCreatedAt: DateTime.fromMillisecondsSinceEpoch(
      row['asset_created_at'] as int? ?? 0,
    ),
  );
}
