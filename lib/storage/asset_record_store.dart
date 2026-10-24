import 'dart:async';
import 'dart:collection' show MapBase;
import 'dart:convert';
import 'dart:io';
import 'dart:math' show max, min;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite/sqflite.dart'
    show ConflictAlgorithm, Database, DatabaseFactory, OpenDatabaseOptions;

import '../backup/change_log.dart';
import '../backup/database_copy.dart';
import 'after_first_frame.dart';
import 'container_path.dart';
import 'asset_record.dart';
import 'bucket_object.dart';

/// What the photo library knows about a photo, for the blanks it fills.
typedef LibraryMetadata = ({
  double? latitude,
  double? longitude,
  int? width,
  int? height,
});

/// A camera-roll asset the scan found untracked, for
/// [AssetRecordStore.insertScanned].
class ScannedAsset {
  const ScannedAsset({
    required this.localId,
    required this.libraryId,
    required this.platform,
    required this.createdAt,
    this.isVideo = false,
    this.isGif = false,
    this.isLivePhoto = false,
    this.isFavorite = false,
    this.latitude,
    this.longitude,
    this.width,
    this.height,
  });

  final String localId;
  final String libraryId;
  final String platform;
  final DateTime createdAt;
  final bool isVideo;
  final bool isGif;
  final bool isLivePhoto;
  final bool isFavorite;
  final double? latitude;
  final double? longitude;
  final int? width;
  final int? height;
}

/// Local `sqflite` store for per-asset backup state — the single source of
/// truth for what's been uploaded, so a restart or a killed background task
/// resumes without re-scanning derivatives from scratch.
class AssetRecordStore {
  AssetRecordStore({
    DatabaseFactory? databaseFactory,
    this._path,
    Future<Directory> Function()? appSupportDirectory,
    String? container,
  }) : _databaseFactory = databaseFactory ?? sqflite.databaseFactory,
       _appSupportDirectory =
           appSupportDirectory ?? getApplicationSupportDirectory,
       _container = container ?? currentContainerId;

  final DatabaseFactory _databaseFactory;
  final String? _path;

  static var _instances = 0;
  final int _id = _instances++;

  /// Where `ManualAddService`/`DemoAssetsService` copy owned files into —
  /// used to re-resolve a `manualFile` record's `sourcePath` by filename
  /// when its stored absolute path goes stale (the app container's UUID
  /// isn't stable across reinstalls, even though the files inside it move
  /// together).
  final Future<Directory> Function() _appSupportDirectory;

  /// This run's container folder name ([currentContainerId]).
  final String? _container;

  Database? _db;
  Directory? _appSupport;

  static const _table = 'asset_record';

  Future<Database>? _opening;

  /// One open at a time per store: concurrent callers share it rather than
  /// each running the migrations and the path pass.
  Future<Database> _open() async {
    final existing = _db;
    if (existing != null) return existing;
    final opening = _opening ??= _openOnce();
    try {
      return await opening;
    } catch (_) {
      _opening = null;
      rethrow;
    }
  }

  Future<Database> _openOnce() async {
    final path =
        _path ??
        p.join(await _databaseFactory.getDatabasesPath(), 'photos_vault.db');
    final db = await _databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 32,
        onCreate: (db, version) async {
          await db.execute(_createTableSql);
          await db.execute(_createLibraryIdIndexSql);
          await db.execute(_createPendingSwapTableSql);
          await db.execute(_createTransitionTableSql);
          await db.execute(_createPlaceNameTableSql);
          await db.execute(_createAppStateTableSql);
          await db.execute(_createDerivativeTargetTableSql);
          await db.execute(_createHiddenNoteTableSql);
          await db.execute(_createBucketObjectTableSql);
          await db.execute(_createBucketScanTableSql);
          await db.execute(_createBucketScanObjectTableSql);
          await db.execute(_createRelinkTableSql);
          await db.execute(_createRelinkIndexSql);
          await db.execute(_createBucketEditTableSql);
          await db.execute(_createChangeCheckTableSql);
          await _addSpotChecked(db);
          await _addRevisions(db);
          await db.execute(_editedKeyIndexSql);
          await _addLookupIndexes(db);
        },
        onUpgrade: (db, oldVersion, newVersion) async {
          if (oldVersion < 2) {
            await db.execute(
              'ALTER TABLE $_table ADD COLUMN is_video INTEGER NOT NULL DEFAULT 0',
            );
          }
          if (oldVersion < 3) {
            await db.execute(
              "ALTER TABLE $_table ADD COLUMN description TEXT NOT NULL DEFAULT ''",
            );
            await db.execute(
              "ALTER TABLE $_table ADD COLUMN tags TEXT NOT NULL DEFAULT '[]'",
            );
            await db.execute('ALTER TABLE $_table ADD COLUMN location TEXT');
          }
          if (oldVersion < 4) {
            await db.execute(
              'ALTER TABLE $_table ADD COLUMN passcode_hash TEXT',
            );
          }
          if (oldVersion < 5) {
            await db.execute(
              'ALTER TABLE $_table ADD COLUMN thumbnail_hash TEXT',
            );
            await db.execute('ALTER TABLE $_table ADD COLUMN medium_hash TEXT');
            await db.execute(
              'ALTER TABLE $_table ADD COLUMN original_hash TEXT',
            );
          }
          if (oldVersion < 6) {
            await db.execute(
              'ALTER TABLE $_table ADD COLUMN thumbnail_path TEXT',
            );
            await db.execute(
              'ALTER TABLE $_table ADD COLUMN local_deleted INTEGER NOT NULL DEFAULT 0',
            );
          }
          if (oldVersion < 8) {
            await db.execute(
              'ALTER TABLE $_table ADD COLUMN is_live_photo INTEGER NOT NULL DEFAULT 0',
            );
          }
          if (oldVersion < 10) {
            await db.execute('ALTER TABLE $_table ADD COLUMN latitude REAL');
            await db.execute('ALTER TABLE $_table ADD COLUMN longitude REAL');
            await db.execute('ALTER TABLE $_table ADD COLUMN width INTEGER');
            await db.execute('ALTER TABLE $_table ADD COLUMN height INTEGER');
            await db.execute(_createPlaceNameTableSql);
          }
          if (oldVersion < 11) {
            await db.execute('ALTER TABLE $_table ADD COLUMN library_id TEXT');
            // Every camera-roll record so far carried the library's id
            // inside its own — 'photo:<id>'. Lift it out so the two can
            // part ways when a hidden photo leaves the library.
            await db.execute(
              "UPDATE $_table SET library_id = substr(local_id, 7) "
              "WHERE source_type = 'photoManager' AND local_id LIKE 'photo:%'",
            );
          }
          if (oldVersion < 12) {
            await db.execute(_createAppStateTableSql);
          }
          if (oldVersion < 13) {
            // Backfilled where the name gives it away; camera-roll GIFs
            // scanned before this get theirs on the next scan.
            await db.execute(
              'ALTER TABLE $_table ADD COLUMN is_gif INTEGER NOT NULL DEFAULT 0',
            );
            await db.execute(
              "UPDATE $_table SET is_gif = 1 WHERE lower(source_path) LIKE '%.gif'",
            );
          }
          if (oldVersion < 14) {
            // The moving half of a Live Photo. Every Live Photo backed up
            // before this is a still in the bucket and needs uploading
            // again — the columns default to `pending`, which is exactly
            // what makes the next sync pick them up.
            await db.execute(
              "ALTER TABLE $_table ADD COLUMN live_status TEXT NOT NULL "
              "DEFAULT 'pending'",
            );
            await db.execute('ALTER TABLE $_table ADD COLUMN live_key TEXT');
            await db.execute('ALTER TABLE $_table ADD COLUMN live_hash TEXT');
          }
          if (oldVersion < 15) {
            await db.execute(
              'ALTER TABLE $_table ADD COLUMN is_locked INTEGER NOT NULL '
              'DEFAULT 0',
            );
            await db.execute(
              'ALTER TABLE $_table ADD COLUMN local_optimized INTEGER NOT '
              'NULL DEFAULT 0',
            );
          }
          if (oldVersion < 16) {
            await db.execute(_createDerivativeTargetTableSql);
            await _adoptExistingUploads(db);
          }
          if (oldVersion < 17) {
            // Null for rows from before, read as their own date — the
            // honest stand-in, so the upgrade doesn't call the whole
            // library new.
            await db.execute('ALTER TABLE $_table ADD COLUMN added_at INTEGER');
            await db.execute(_createHiddenNoteTableSql);
          }
          if (oldVersion < 18) {
            await db.execute(_createBucketObjectTableSql);
          }
          if (oldVersion < 19) {
            await db.execute(_createBucketScanTableSql);
            await db.execute(_createBucketScanObjectTableSql);
          }
          if (oldVersion < 20) {
            // Null on rows binned before: who did it is unknown. A scan
            // that lists the asset again takes it out (`unbinListed`).
            await db.execute('ALTER TABLE $_table ADD COLUMN binned_by TEXT');
          }
          if (oldVersion < 21) {
            await db.execute(_createTransitionTableSql);
          }
          if (oldVersion < 22) {
            final columns = await db.rawQuery('PRAGMA table_info($_table)');
            if (!columns.any((c) => c['name'] == 'held_name')) {
              await db.execute('ALTER TABLE $_table ADD COLUMN held_name TEXT');
            }
          }
          if (oldVersion < 23) {
            await _unlinkDuplicateLibraryIds(db);
            await db.execute('DROP INDEX IF EXISTS asset_record_library_id');
            await db.execute(_createLibraryIdIndexSql);
            await db.execute(_createPendingSwapTableSql);
            await _migrateSwapJson(db);
          }
          if (oldVersion < 24) {
            await db.execute(_createRelinkTableSql);
            await db.execute(_createRelinkIndexSql);
          }
          if (oldVersion < 25) {
            // Every row starts at 0: the first read after this is a full
            // one, and every write from here on is above it.
            final columns = await db.rawQuery('PRAGMA table_info($_table)');
            if (!columns.any((c) => c['name'] == 'rev')) {
              await db.execute(
                'ALTER TABLE $_table ADD COLUMN rev INTEGER NOT NULL '
                'DEFAULT 0',
              );
            }
            await _addRevisions(db);
            await db.execute(_createBucketEditTableSql);
          }
          if (oldVersion < 26) {
            // Empty: every backed-up photo is hashed once more, newest
            // first, and from then on only when its date moves.
            await db.execute(_createChangeCheckTableSql);
          }
          if (oldVersion < 27) {
            // PW3b: every backup so far stays as it is. A NULL
            // `original_source` says its hash is of a full-size JPEG render,
            // which its change check keeps comparing against; `has_edit` 0
            // owes no second object. Nothing here re-sends or deletes.
            final had = {
              for (final c in await db.rawQuery('PRAGMA table_info($_table)'))
                c['name'],
            };
            for (final (name, type) in const [
              ('edited_status', "TEXT NOT NULL DEFAULT 'pending'"),
              ('edited_key', 'TEXT'),
              ('edited_hash', 'TEXT'),
              ('original_source', 'TEXT'),
              ('has_edit', 'INTEGER NOT NULL DEFAULT 0'),
            ]) {
              if (had.contains(name)) continue;
              await db.execute('ALTER TABLE $_table ADD COLUMN $name $type');
            }
            await db.execute(_editedKeyIndexSql);
          }
          if (oldVersion < 28) {
            // PW5: entries so far hold whole rows; [_slimLog] cuts the ones
            // below this to diffs after the first frame.
            await _markLogToSlim(db);
          }
          if (oldVersion < 29) {
            // PW6: the spot check's dates move from one app-state JSON
            // into `change_check`, so a round writes its few rows only.
            await _addSpotChecked(db);
            await _importSpotChecks(db);
          }
          if (oldVersion < 30) await _addLookupIndexes(db);
          // An older step that rebuilt the table already has it.
          if (oldVersion < 31 &&
              !(await db.rawQuery('PRAGMA table_info($_table)'))
                  .any((c) => c['name'] == 'is_archived')) {
            await db.execute(
              'ALTER TABLE $_table ADD COLUMN is_archived INTEGER NOT NULL '
              'DEFAULT 0',
            );
          }
          if (oldVersion < 32 &&
              !(await db.rawQuery('PRAGMA table_info($_table)'))
                  .any((c) => c['name'] == 'people_only')) {
            await db.execute(
              'ALTER TABLE $_table ADD COLUMN people_only INTEGER NOT NULL '
              'DEFAULT 0',
            );
          }
        },
      ),
    );
    // Sorts and temp indexes stay off disk: with no usable `tmp` a query
    // fails and sqflite's queue stalls behind it.
    await db.execute('PRAGMA temp_store = MEMORY');
    // A deleted hidden row is zeroed, not left in a free page.
    await db.rawQuery(
      'PRAGMA secure_delete = ON',
    ); // Returns a row: execute fails on iOS.
    await db.execute(
      'CREATE INDEX IF NOT EXISTS asset_record_passcode_hash '
      'ON $_table (passcode_hash)',
    );
    // After the migrations, never inside them: a trigger has to describe
    // the schema the app just finished upgrading to.
    await installChangeLog(
      db,
      const [_table],
      private: const {_table: privateRowSql},
      quiet: const {_table: _quietColumns},
      silent: const {_table: _silentColumns},
    );
    await _rehomeOnce(db);
    await _dropSquareThumbnails(db);
    await _undoRedate(db);
    _db = db;
    unawaited(_maintain(db));
    return db;
  }

  /// After the first frame: the log trimmed and slimmed, in slices. The
  /// one-time `VACUUM` no earlier than half a minute in, on what is left.
  Future<void> _maintain(Database db) async {
    final opened = Stopwatch()..start();
    await afterFirstFrame();
    await tidyLog(db);
    final wait = const Duration(seconds: 30) - opened.elapsed;
    if (wait > Duration.zero) await Future<void>.delayed(wait);
    await compact(db);
  }

  /// The private purge, the prune, then [_slimLog]. FAST only once the
  /// purge has run: from then on no entry is about a hidden row (the
  /// private triggers drop a row's history as it is hidden).
  @visibleForTesting
  static Future<void> tidyLog(Database db) async {
    final purged = await _purgePrivateLog(db);
    await pruneChangeLog(db, fast: purged);
    if (purged) await _slimLog(db);
  }

  static const _slimBelowKey = 'change_log_slim_below';

  static Future<void> _markLogToSlim(Database db) async {
    final has = await db.rawQuery(
      "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
      [changeLogTable],
    );
    if (has.isEmpty) return;
    final rows = await db.rawQuery(
      'SELECT COALESCE(MAX(seq), 0) + 1 AS s FROM $changeLogTable',
    );
    await _putAppState(db, _slimBelowKey, '${rows.first['s']}');
  }

  /// Whole-row update entries from before PW5, down to diffs. After the
  /// private purge, which reads `passcode_hash` out of whole rows.
  static Future<void> _slimLog(Database db) async {
    try {
      final below = int.tryParse(await _appState(db, _slimBelowKey) ?? '');
      if (below == null) return;
      final done = await slimChangeLog(
        db,
        _table,
        below: below,
        silent: _silentColumns,
      );
      if (!done) return;
      await db.delete(
        _appStateTable,
        where: 'key = ?',
        whereArgs: [_slimBelowKey],
      );
    } catch (_) {
      // Next launch.
    }
  }

  /// A row behind a passcode, as the change log tests it.
  static const privateRowSql = '{row}.passcode_hash IS NOT NULL';

  static const _privateLogPurgedKey = 'private_log_purged_v1';

  /// What builds before the log's private rule wrote about hidden rows.
  /// Once; after [_undoRedate], which read them. True once it has run.
  static Future<bool> _purgePrivateLog(Database db) async {
    try {
      if (await _appState(db, _privateLogPurgedKey) != null) return true;
      await purgePrivateEntries(
        db,
        _table,
        privateRowSql,
        rowKeySql: "COALESCE(CAST(local_id AS TEXT), '')",
      );
      await _putAppState(db, _privateLogPurgedKey, '1');
      return true;
    } catch (_) {
      // Tried again next launch.
      return false;
    }
  }

  /// Free pages hold what was deleted before `secure_delete` (wiped rows,
  /// hidden rows, the log's old copies) and keep the file at its largest.
  /// Once: `auto_vacuum = INCREMENTAL` and the `VACUUM` that applies it,
  /// knowingly holding the connection for the seconds it takes, half a
  /// minute after launch. After that, each launch hands back what the
  /// log prune freed.
  ///
  /// The rebuild goes through temp files: in memory it costs about the
  /// live database again. In memory only as a fallback, and only when
  /// what is live is small.
  static Future<void> compact(Database db) async {
    try {
      final mode = await db.rawQuery('PRAGMA auto_vacuum');
      if (mode.first.values.first != 2) {
        await db.execute('PRAGMA auto_vacuum = INCREMENTAL');
        try {
          await Directory.systemTemp.create(recursive: true);
          await db.execute('PRAGMA temp_store = FILE');
          await db.execute('VACUUM');
        } catch (_) {
          if (await _liveBytes(db) > _memoryVacuumLimit) rethrow;
          await db.execute('PRAGMA temp_store = MEMORY');
          await db.execute('VACUUM');
        } finally {
          await db.execute('PRAGMA temp_store = MEMORY');
        }
      } else {
        // Stepped to the end by rawQuery: one page per step.
        await db.rawQuery('PRAGMA incremental_vacuum');
      }
    } catch (_) {
      // A full disk; next launch.
    }
  }

  static const _memoryVacuumLimit = 64 << 20;

  static Future<int> _liveBytes(Database db) async {
    final rows = await db.rawQuery(
      'SELECT (page_count - freelist_count) * page_size AS b '
      'FROM pragma_page_count, pragma_freelist_count, pragma_page_size',
    );
    return rows.first['b'] as int? ?? 0;
  }

  static Future<String?> _appState(Database db, String key) async {
    final rows = await db.query(
      _appStateTable,
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  static Future<void> _putAppState(Database db, String key, String value) =>
      db.insert(_appStateTable, {
        'key': key,
        'value': value,
      }, conflictAlgorithm: ConflictAlgorithm.replace);

  static const _fittedThumbnailsKey = 'thumbnails_fitted_v1';

  /// Forgets thumbnails cached back when the app asked PhotoKit for a
  /// square one, so the background pass makes them again at the photo's
  /// own shape (`ThumbnailCache`'s `thumbnailOption`).
  ///
  /// Only where the original is still here to re-make from — a cloud-only
  /// photo's cached thumbnail is the only picture of it left, and a
  /// wrongly-cropped picture beats none. Hidden photos keep theirs too;
  /// they are encrypted elsewhere and this column is already null for
  /// them.
  ///
  /// Once ever, on the launch after the upgrade, and a no-op on every
  /// launch after that.
  Future<void> _dropSquareThumbnails(Database db) async {
    final done = await db.query(
      _appStateTable,
      where: 'key = ?',
      whereArgs: [_fittedThumbnailsKey],
      limit: 1,
    );
    if (done.isNotEmpty) return;
    await db.update(
      _table,
      {
        'thumbnail_path': null,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where:
          'thumbnail_path IS NOT NULL AND local_deleted = 0 AND '
          'deleted_at IS NULL AND passcode_hash IS NULL',
    );
    await db.insert(_appStateTable, {
      'key': _fittedThumbnailsKey,
      'value': '1',
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static const _redateUndoneKey = 'imports_redate_undone_v1';

  /// A build re-dated imports from the stamp in their object name, which
  /// for a hidden photo is the decoy's date, not the photo's. Each such
  /// change is still in the change log with the real date beside it; put
  /// that back wherever the row hasn't changed date since. Once ever.
  Future<void> _undoRedate(Database db) async {
    final done = await db.query(
      _appStateTable,
      where: 'key = ?',
      whereArgs: [_redateUndoneKey],
      limit: 1,
    );
    if (done.isNotEmpty) return;
    try {
      await db.execute(
        """
        UPDATE $_table SET
          created_at = (
            SELECT json_extract(c.before, '\$.created_at')
            FROM $changeLogTable c
            WHERE c.table_name = '$_table' AND c.op = 'update'
              AND c.row_key = $_table.local_id
              AND json_extract(c.before, '\$.created_at')
                  != json_extract(c.after, '\$.created_at')
              AND json_extract(c.after, '\$.created_at') = $_table.created_at
            ORDER BY c.seq DESC LIMIT 1),
          updated_at = ?
        WHERE (passcode_hash IS NOT NULL OR local_id LIKE 'manual:vault-%')
          AND EXISTS (
            SELECT 1 FROM $changeLogTable c
            WHERE c.table_name = '$_table' AND c.op = 'update'
              AND c.row_key = $_table.local_id
              AND json_extract(c.before, '\$.created_at')
                  != json_extract(c.after, '\$.created_at')
              AND json_extract(c.after, '\$.created_at') = $_table.created_at)
      """,
        [DateTime.now().millisecondsSinceEpoch],
      );
    } catch (_) {
      // No log to read from: nothing was re-dated on this phone.
    }
    await db.insert(_appStateTable, {
      'key': _redateUndoneKey,
      'value': '1',
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static const _rehomedForKey = 'paths_rehomed_for';

  /// [_rehomePaths] once per container rather than once per launch: three
  /// full scans otherwise, before the first query. Every path this app
  /// writes is under the container it runs in, so only a new container
  /// (or a database from another one) has any to move. The mark lives in
  /// the same file, so a database copied in brings its own. Outside a
  /// container (tests, no phone) it runs every time, as before.
  Future<void> _rehomeOnce(Database db) async {
    final container = _container;
    if (container != null && await _appState(db, _rehomedForKey) == container) {
      return;
    }
    final done = await _rehomePaths(db);
    if (done && container != null) {
      await _putAppState(db, _rehomedForKey, container);
    }
  }

  /// Paths into a *previous* app container, pointed at the current one.
  ///
  /// iOS gives the container a new UUID whenever the app is reinstalled
  /// (and a bundle-ID change does the same), so every absolute path this
  /// app has ever stored — originals it owns, cached thumbnails — dies at
  /// that moment while the files themselves move across intact.
  /// [rebaseContainerPath] already fixes what [_fromRow] hands out; this
  /// keeps the stored paths current too, for the queries that match on
  /// them ([plainIdsUnder], [sourcePathShared]).
  ///
  /// The container's UUID is swapped in SQL, one statement per column, no
  /// file checks: the files move together. Path columns are quiet in the
  /// change log, so a reinstall no longer writes the library into it
  /// twice. Only paths with no container in them (none on a phone) go
  /// through the per-row check.
  /// False when the per-row check couldn't run.
  Future<bool> _rehomePaths(Database db) async {
    final container = _container;
    final inContainer =
        '*$containerMarker${List.filled(36, '[0-9A-Fa-f-]').join()}/*';
    if (container != null) {
      for (final column in const ['source_path', 'thumbnail_path']) {
        final at = "instr($column, '$containerMarker')";
        final start = '$at + ${containerMarker.length}';
        await db.rawUpdate(
          'UPDATE $_table SET $column = '
          'substr($column, 1, $start - 1) || ? || substr($column, $start + 36), '
          'updated_at = ? '
          'WHERE $column GLOB ? AND substr($column, $start, 36) <> ?',
          [
            container,
            DateTime.now().millisecondsSinceEpoch,
            inContainer,
            container,
          ],
        );
      }
    }
    final Directory root;
    try {
      root = _appSupport ??= await _appSupportDirectory();
    } catch (_) {
      // No platform to ask (a pure-Dart test) — paths stay as they are.
      return false;
    }
    final under = '${root.path}%';
    final rows = await db.query(
      _table,
      columns: ['local_id', 'source_path', 'thumbnail_path'],
      // Not what the SQL above already moved.
      where:
          '(source_path IS NOT NULL AND source_path NOT LIKE ? '
          'AND source_path NOT GLOB ?) OR '
          '(thumbnail_path IS NOT NULL AND thumbnail_path NOT LIKE ? '
          'AND thumbnail_path NOT GLOB ?)',
      whereArgs: [under, inContainer, under, inContainer],
    );
    String? outside(Object? path) =>
        path is String && !inAContainer(path) ? path : null;
    final updates = <(String, Map<String, Object?>)>[];
    for (final row in rows) {
      final values = <String, Object?>{};
      final source = await _rehomed(outside(row['source_path']), root.path);
      if (source != null) values['source_path'] = source;
      final thumbnail = await _rehomed(
        outside(row['thumbnail_path']),
        root.path,
      );
      if (thumbnail != null) values['thumbnail_path'] = thumbnail;
      if (values.isEmpty) continue;
      values['updated_at'] = DateTime.now().millisecondsSinceEpoch;
      updates.add((row['local_id'] as String, values));
    }
    if (updates.isEmpty) return true;
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final (localId, values) in updates) {
        batch.update(
          _table,
          values,
          where: 'local_id = ?',
          whereArgs: [localId],
        );
      }
      await batch.commit(noResult: true);
    });
    return true;
  }

  /// [path] as it would be under the current container, or null if it
  /// already is, isn't from one, or nothing is there to point at.
  ///
  /// The tail after `Application Support/` is kept, so a file in a
  /// subdirectory (`thumbnails/`) lands back in the same one rather than
  /// loose at the top.
  static Future<String?> _rehomed(String? path, String root) async {
    if (path == null || p.isWithin(root, path)) return null;
    const marker = '/Application Support/';
    final at = path.lastIndexOf(marker);
    final moved = p.join(
      root,
      at == -1 ? p.basename(path) : path.substring(at + marker.length),
    );
    if (moved == path || !await File(moved).exists()) return null;
    return moved;
  }

  static const _createTableSql =
      '''
    CREATE TABLE $_table (
      local_id TEXT PRIMARY KEY,
      content_hash TEXT NOT NULL,
      platform TEXT NOT NULL,
      source_type TEXT NOT NULL DEFAULT 'photoManager',
      source_path TEXT,
      thumbnail_path TEXT,
      local_deleted INTEGER NOT NULL DEFAULT 0,
      is_video INTEGER NOT NULL DEFAULT 0,
      is_live_photo INTEGER NOT NULL DEFAULT 0,
      is_gif INTEGER NOT NULL DEFAULT 0,
      thumbnail_status TEXT NOT NULL DEFAULT 'pending',
      thumbnail_key TEXT,
      thumbnail_hash TEXT,
      medium_status TEXT NOT NULL DEFAULT 'pending',
      medium_key TEXT,
      medium_hash TEXT,
      original_status TEXT NOT NULL DEFAULT 'pending',
      original_key TEXT,
      original_hash TEXT,
      live_status TEXT NOT NULL DEFAULT 'pending',
      live_key TEXT,
      live_hash TEXT,
      edited_status TEXT NOT NULL DEFAULT 'pending',
      edited_key TEXT,
      edited_hash TEXT,
      original_source TEXT,
      has_edit INTEGER NOT NULL DEFAULT 0,
      is_favorite INTEGER NOT NULL DEFAULT 0,
      is_hidden INTEGER NOT NULL DEFAULT 0,
      is_locked INTEGER NOT NULL DEFAULT 0,
      is_archived INTEGER NOT NULL DEFAULT 0,
      people_only INTEGER NOT NULL DEFAULT 0,
      local_optimized INTEGER NOT NULL DEFAULT 0,
      deleted_at INTEGER,
      binned_by TEXT,
      description TEXT NOT NULL DEFAULT '',
      tags TEXT NOT NULL DEFAULT '[]',
      location TEXT,
      passcode_hash TEXT,
      library_id TEXT,
      latitude REAL,
      longitude REAL,
      width INTEGER,
      height INTEGER,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL,
      added_at INTEGER,
      held_name TEXT,
      rev INTEGER NOT NULL DEFAULT 0
    )
  ''';

  static const _revTable = 'record_rev';

  /// A counter that only goes up, stamped on every row a write touches:
  /// [listAll]'s "what moved since" without trusting a clock. Its own row,
  /// not `MAX(rev)`, which steps back when the newest row is deleted.
  /// Triggers, so no write path can forget it; the inner update changes
  /// only `rev`, which the change log ignores.
  static Future<void> _addRevisions(Database db) async {
    await db.execute(
      'CREATE TABLE IF NOT EXISTS $_revTable '
      '(id INTEGER PRIMARY KEY CHECK (id = 0), n INTEGER NOT NULL)',
    );
    await db.execute('INSERT OR IGNORE INTO $_revTable (id, n) VALUES (0, 0)');
    const stamp =
        'UPDATE $_revTable SET n = n + 1 WHERE id = 0; '
        'UPDATE $_table SET rev = (SELECT n FROM $_revTable WHERE id = 0) '
        'WHERE rowid = NEW.rowid;';
    await db.execute(
      'CREATE TRIGGER IF NOT EXISTS ${_table}_rev_insert AFTER INSERT ON '
      '$_table BEGIN $stamp END',
    );
    await db.execute(
      'CREATE TRIGGER IF NOT EXISTS ${_table}_rev_update AFTER UPDATE ON '
      '$_table WHEN NEW.rev IS OLD.rev BEGIN $stamp END',
    );
    for (final sql in _indexSql) {
      await db.execute(sql);
    }
  }

  /// [listAll]'s incremental read, the grid's order, and the key lookups a
  /// bulk delete makes per photo ([keyHeldByOthers], [originalStemHeld]).
  static const _indexSql = [
    'CREATE INDEX IF NOT EXISTS asset_record_rev ON $_table (rev)',
    'CREATE INDEX IF NOT EXISTS asset_record_created ON $_table '
        '(created_at, local_id)',
    'CREATE INDEX IF NOT EXISTS asset_record_original_key ON $_table '
        '(original_key)',
    'CREATE INDEX IF NOT EXISTS asset_record_thumbnail_key ON $_table '
        '(thumbnail_key)',
    'CREATE INDEX IF NOT EXISTS asset_record_medium_key ON $_table '
        '(medium_key)',
    'CREATE INDEX IF NOT EXISTS asset_record_live_key ON $_table (live_key)',
    'CREATE INDEX IF NOT EXISTS derivative_target_key ON '
        '$_derivativeTargetTable (destination_key)',
  ];

  /// v30 (DB-12, DB-13): [sourcePathShared] and [plainIdsUnder] (only
  /// manual and hidden rows have a path), and [listAwaitingPlaceName].
  static Future<void> _addLookupIndexes(Database db) async {
    await db.execute(
      'CREATE INDEX IF NOT EXISTS asset_record_source_path ON $_table '
      '(source_path) WHERE source_path IS NOT NULL',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS asset_record_awaiting_place ON $_table '
      '(created_at) WHERE $_awaitingPlaceSql',
    );
  }

  /// Must read exactly so in the query, or the partial index is not used.
  static const _awaitingPlaceSql =
      'latitude IS NOT NULL AND longitude IS NOT NULL '
      "AND (location IS NULL OR location = '') AND deleted_at IS NULL";

  /// Apart from [_indexSql]: that runs at v25, before the column exists.
  static const _editedKeyIndexSql =
      'CREATE INDEX IF NOT EXISTS asset_record_edited_key ON $_table '
      '(edited_key)';

  /// `original_source` for a hash of PhotoKit's stored bytes; NULL is a
  /// full-size render (`DerivativeState.fromResource`).
  static const _resourceSource = 'resource';

  /// Upload state: a backup carries it, so a write moves the change mark,
  /// but no log row — it is most of the writes and none of them the user's.
  static const _quietColumns = {'source_path', 'has_edit', ..._uploadColumns};

  static const _uploadColumns = {
    'thumbnail_status',
    'thumbnail_key',
    'thumbnail_hash',
    'medium_status',
    'medium_key',
    'medium_hash',
    'original_status',
    'original_key',
    'original_hash',
    'live_status',
    'live_key',
    'live_hash',
    'edited_status',
    'edited_key',
    'edited_hash',
    'original_source',
  };

  /// A cache path and the bookkeeping stamps: nothing a backup carries.
  static const _silentColumns = {'thumbnail_path', 'updated_at', 'rev'};

  /// One record per Photos asset. Two rows on one asset is how a stray
  /// copy record came to have the keeper's asset deleted (Remove Extra
  /// Copies); the scan's lookup is this index too.
  static const _createLibraryIdIndexSql =
      'CREATE UNIQUE INDEX IF NOT EXISTS asset_record_library_id_unique '
      'ON $_table (library_id) WHERE library_id IS NOT NULL';

  static const _unlinkedKey = 'library_id_unlinked_v23';

  /// Before the unique index: of rows sharing an asset, one keeps it. In
  /// order: not binned, the record a swap or un-hide moved onto the asset
  /// (it carries the history), the oldest. The rest keep every column but
  /// the link, and are listed in [_unlinkedKey]. Nothing is deleted.
  static Future<void> _unlinkDuplicateLibraryIds(Database db) async {
    final rows = await db.rawQuery(
      'SELECT local_id, library_id FROM $_table WHERE library_id IN ('
      'SELECT library_id FROM $_table WHERE library_id IS NOT NULL '
      'GROUP BY library_id HAVING COUNT(*) > 1) '
      'ORDER BY library_id, deleted_at IS NOT NULL, '
      "local_id = 'photo:' || library_id, "
      'COALESCE(added_at, created_at), local_id',
    );
    if (rows.isEmpty) return;
    final unlinked = <String, String>{};
    String? keeping;
    for (final row in rows) {
      final asset = row['library_id'] as String;
      if (asset != keeping) {
        keeping = asset;
        continue;
      }
      unlinked[row['local_id'] as String] = asset;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final id in unlinked.keys) {
      await db.update(
        _table,
        {'library_id': null, 'updated_at': now},
        where: 'local_id = ?',
        whereArgs: [id],
      );
    }
    await _putAppState(db, _unlinkedKey, jsonEncode(unlinked));
  }

  /// Restored rows not yet matched to an asset on this phone. A new
  /// phone gives every asset a new id, so the scan adopts one by capture
  /// time and size instead of adding a second record (see
  /// [relinkCandidate]). Its own table: no change-log rows for bookkeeping.
  static const _relinkTable = 'relink_pending';

  static const _createRelinkTableSql =
      '''
    CREATE TABLE IF NOT EXISTS $_relinkTable (
      local_id TEXT PRIMARY KEY,
      created_at INTEGER NOT NULL
    )
  ''';

  static const _createRelinkIndexSql =
      'CREATE INDEX IF NOT EXISTS relink_pending_created '
      'ON $_relinkTable (created_at)';

  /// When each photo was last known to match its backup, as the
  /// modification date (seconds) of what it is read from: PhotoKit's for a
  /// camera-roll asset, the file's for one held here. `seen` is the latest
  /// date a scan reported; a change check is owed while it isn't `checked`.
  /// Its own table so a scan's stamp is no record write (no revision).
  static const _changeCheckTable = 'change_check';

  static const _createChangeCheckTableSql =
      '''
    CREATE TABLE IF NOT EXISTS $_changeCheckTable (
      local_id TEXT PRIMARY KEY,
      seen INTEGER,
      checked INTEGER
    )
  ''';

  /// `spot_checked`: when the spot check last had an answer from the
  /// bucket for a cloud-only photo (ms). Beside the change check: the same
  /// key, cleared with the record and scrubbed from copies with it.
  static Future<void> _addSpotChecked(Database db) async {
    final had = {
      for (final c in await db.rawQuery(
        'PRAGMA table_info($_changeCheckTable)',
      ))
        c['name'],
    };
    if (had.contains('spot_checked')) return;
    await db.execute(
      'ALTER TABLE $_changeCheckTable ADD COLUMN spot_checked INTEGER',
    );
  }

  static const _spotCheckedLegacyKey = 'spot_checked_at';

  /// The old JSON map, for records still here. Only an order: a value
  /// it can't read starts that photo as never checked.
  static Future<void> _importSpotChecks(Database db) async {
    try {
      await db.rawInsert(
        'INSERT INTO $_changeCheckTable (local_id, spot_checked) '
        'SELECT j.key, CAST(j.value AS INTEGER) FROM json_each(('
        'SELECT value FROM $_appStateTable WHERE key = ? '
        'AND json_valid(value))) j '
        'WHERE j.key IN (SELECT local_id FROM $_table) '
        'ON CONFLICT (local_id) DO UPDATE SET '
        'spot_checked = excluded.spot_checked',
        [_spotCheckedLegacyKey],
      );
    } catch (_) {
      // Unreadable: every photo starts as never spot-checked.
    }
    await db.delete(
      _appStateTable,
      where: 'key = ?',
      whereArgs: [_spotCheckedLegacyKey],
    );
  }

  static const _pendingSwapTable = 'pending_swap';

  static const _createPendingSwapTableSql =
      '''
    CREATE TABLE IF NOT EXISTS $_pendingSwapTable (
      local_id TEXT PRIMARY KEY,
      old_asset TEXT NOT NULL,
      new_asset TEXT,
      keeper_id TEXT,
      flag TEXT,
      keep_new INTEGER NOT NULL DEFAULT 0,
      width INTEGER,
      height INTEGER,
      old_bytes INTEGER NOT NULL DEFAULT 0,
      new_bytes INTEGER NOT NULL DEFAULT 0,
      proved_at INTEGER,
      filed_at INTEGER NOT NULL
    )
  ''';

  static const _legacySwapsKey = 'pending_swaps_v1';

  /// The old JSON list into [_pendingSwapTable], inside the upgrade's own
  /// transaction. An entry whose record already moved onto its copy was
  /// applied before a kill and is dropped: deleting "its asset" now would
  /// delete the copy.
  static Future<void> _migrateSwapJson(Database db) async {
    final raw = await _appState(db, _legacySwapsKey);
    if (raw == null) return;
    List<dynamic> entries;
    try {
      entries = jsonDecode(raw) as List;
    } catch (_) {
      entries = const [];
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final e in entries.whereType<Map>()) {
      final id = e['id'];
      if (id is! String) continue;
      final rows = await db.query(
        _table,
        columns: ['library_id'],
        where: 'local_id = ?',
        whereArgs: [id],
      );
      final old = rows.isEmpty ? null : rows.single['library_id'] as String?;
      final asset = e['asset'] as String?;
      if (old == null || old == asset) continue;
      await db.insert(_pendingSwapTable, {
        'local_id': id,
        'old_asset': old,
        'new_asset': asset,
        'keep_new': e['keep'] == true ? 1 : 0,
        'width': e['w'] as int?,
        'height': e['h'] as int?,
        'old_bytes': e['old'] as int? ?? 0,
        'new_bytes': e['new'] as int? ?? 0,
        'filed_at': now,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    }
    await db.delete(
      _appStateTable,
      where: 'key = ?',
      whereArgs: [_legacySwapsKey],
    );
  }

  /// One row per rounded-off patch of the world, so a thousand photos from
  /// one trip cost one question to the geocoder rather than a thousand —
  /// see `PhotoLocationService`, which owns the rounding and the reasoning.
  /// A row with a null `name` is a remembered "there's nothing there",
  /// which is just as worth not asking twice.
  /// Flags about the library as a whole — whether iCloud backup is on,
  /// whether a restore has already happened. In the same database file as
  /// the records they describe, so the two can't disagree: the keychain,
  /// the other obvious home, *outlives* an uninstall on iOS, which would
  /// leave a fresh install convinced it had already restored.
  static const _appStateTable = 'app_state';

  static const _createAppStateTableSql =
      '''
    CREATE TABLE $_appStateTable (
      key TEXT PRIMARY KEY,
      value TEXT NOT NULL
    )
  ''';

  /// Which target holds which derivative.
  ///
  /// `asset_record` carries one status and one key per derivative, which
  /// means "somewhere" rather than "where" — and with two buckets
  /// configured, one of them failing every time was recorded as a
  /// successful backup, because the aggregate only needed one to land. This
  /// is the row that says otherwise, so a target that missed an upload can
  /// be given it again without re-sending to the one that already has it.
  static const _derivativeTargetTable = 'derivative_target';

  static const _bucketObjectTable = 'bucket_object';

  static const _createBucketObjectTableSql =
      '''
    CREATE TABLE $_bucketObjectTable (
      target_id TEXT NOT NULL,
      key TEXT NOT NULL,
      size INTEGER NOT NULL,
      last_modified INTEGER NOT NULL,
      PRIMARY KEY (target_id, key)
    )
  ''';

  static const _bucketScanTable = 'bucket_scan';
  static const _bucketScanObjectTable = 'bucket_scan_object';

  static const _createBucketScanTableSql =
      '''
    CREATE TABLE $_bucketScanTable (
      target_id TEXT NOT NULL,
      dir TEXT NOT NULL,
      token TEXT,
      started_at INTEGER NOT NULL,
      PRIMARY KEY (target_id, dir)
    )
  ''';

  static const _createBucketScanObjectTableSql =
      '''
    CREATE TABLE $_bucketScanObjectTable (
      target_id TEXT NOT NULL,
      key TEXT NOT NULL,
      size INTEGER NOT NULL,
      last_modified INTEGER NOT NULL,
      PRIMARY KEY (target_id, key)
    )
  ''';

  /// Deletes and moves made here since the listing being staged began
  /// (null size: gone). Its pages may predate them, so the commit applies
  /// them on top; a forgotten key never comes back with the scan.
  static const _bucketEditTable = 'bucket_edit';

  static const _createBucketEditTableSql =
      '''
    CREATE TABLE IF NOT EXISTS $_bucketEditTable (
      target_id TEXT NOT NULL,
      key TEXT NOT NULL,
      size INTEGER,
      last_modified INTEGER,
      PRIMARY KEY (target_id, key)
    )
  ''';

  /// A half-done listing older than this is dropped rather than resumed:
  /// keys added behind the saved position would be missed.
  static const bucketScanMaxAge = Duration(minutes: 30);

  /// Where an interrupted listing of [dir] stopped, so a restart carries on
  /// from there instead of listing the bucket from the beginning. Null when
  /// there is nothing (or nothing fresh) to resume; `done` when that folder
  /// was fully listed and is only waiting on its sibling.
  Future<({String? token, bool done})?> bucketScanProgress(
    String targetId,
    String dir,
  ) async {
    final db = await _open();
    final rows = await db.query(
      _bucketScanTable,
      where: 'target_id = ? AND dir = ?',
      whereArgs: [targetId, dir],
    );
    if (rows.isEmpty) return null;
    final startedAt = DateTime.fromMillisecondsSinceEpoch(
      rows.first['started_at'] as int,
    );
    if (DateTime.now().difference(startedAt) > bucketScanMaxAge) {
      await discardBucketScan(targetId);
      return null;
    }
    final token = rows.first['token'] as String?;
    return (token: token, done: token == null);
  }

  /// One listed page and the token that continues after it, in one
  /// transaction: a kill between the two can't lose or repeat a page.
  Future<void> stageBucketPage(
    String targetId,
    String dir,
    String? nextToken,
    List<BucketObject> objects,
  ) async {
    final db = await _open();
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final o in objects) {
        batch.insert(_bucketScanObjectTable, {
          'target_id': o.targetId,
          'key': o.key,
          'size': o.size,
          'last_modified': o.lastModified.millisecondsSinceEpoch,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      batch.rawInsert(
        'INSERT INTO $_bucketScanTable (target_id, dir, token, started_at) '
        'VALUES (?, ?, ?, ?) ON CONFLICT(target_id, dir) '
        'DO UPDATE SET token = excluded.token',
        [targetId, dir, nextToken, DateTime.now().millisecondsSinceEpoch],
      );
      await batch.commit(noResult: true);
    });
  }

  /// Both folders listed: publish the staged rows as the bucket's contents
  /// and clear the scan state.
  Future<void> commitBucketScan(String targetId) async {
    final db = await _open();
    await db.transaction((txn) async {
      await txn.delete(
        _bucketObjectTable,
        where: 'target_id = ?',
        whereArgs: [targetId],
      );
      await txn.rawInsert(
        'INSERT INTO $_bucketObjectTable '
        'SELECT target_id, key, size, last_modified '
        'FROM $_bucketScanObjectTable WHERE target_id = ?',
        [targetId],
      );
      await txn.rawDelete(
        'DELETE FROM $_bucketObjectTable WHERE target_id = ? AND key IN '
        '(SELECT key FROM $_bucketEditTable WHERE target_id = ? '
        'AND size IS NULL)',
        [targetId, targetId],
      );
      await txn.rawInsert(
        'INSERT OR REPLACE INTO $_bucketObjectTable '
        'SELECT target_id, key, size, last_modified FROM $_bucketEditTable '
        'WHERE target_id = ? AND size IS NOT NULL',
        [targetId],
      );
      for (final table in [_bucketScanObjectTable, _bucketEditTable]) {
        await txn.delete(table, where: 'target_id = ?', whereArgs: [targetId]);
      }
      await txn.delete(
        _bucketScanTable,
        where: 'target_id = ?',
        whereArgs: [targetId],
      );
    });
  }

  Future<void> discardBucketScan(String targetId) async {
    final db = await _open();
    await db.transaction((txn) async {
      for (final table in [_bucketScanObjectTable, _bucketScanTable]) {
        await txn.delete(table, where: 'target_id = ?', whereArgs: [targetId]);
      }
    });
  }

  /// Makes the table say what [targetId]'s bucket holds right now: rows for
  /// objects that are gone are dropped, the rest are upserted. One
  /// transaction, so a half-written listing is never read.
  Future<void> replaceBucketObjects(
    String targetId,
    List<BucketObject> objects,
  ) async {
    final db = await _open();
    await db.transaction((txn) async {
      for (final table in [_bucketObjectTable, _bucketEditTable]) {
        await txn.delete(table, where: 'target_id = ?', whereArgs: [targetId]);
      }
      final batch = txn.batch();
      for (final o in objects) {
        batch.insert(_bucketObjectTable, {
          'target_id': o.targetId,
          'key': o.key,
          'size': o.size,
          'last_modified': o.lastModified.millisecondsSinceEpoch,
        });
      }
      await batch.commit(noResult: true);
    });
  }

  /// The listing follows a replace done here, so nothing reads the old key
  /// as still in the bucket before the next listing.
  Future<void> moveBucketObject(BucketObject from, BucketObject to) async {
    final db = await _open();
    final row = {
      'target_id': to.targetId,
      'key': to.key,
      'size': to.size,
      'last_modified': to.lastModified.millisecondsSinceEpoch,
    };
    final batch = db.batch()
      ..delete(
        _bucketObjectTable,
        where: 'target_id = ? AND key = ?',
        whereArgs: [from.targetId, from.key],
      )
      ..insert(
        _bucketObjectTable,
        row,
        conflictAlgorithm: ConflictAlgorithm.replace,
      )
      ..insert(_bucketEditTable, {
        'target_id': from.targetId,
        'key': from.key,
      }, conflictAlgorithm: ConflictAlgorithm.replace)
      ..insert(
        _bucketEditTable,
        row,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    await batch.commit(noResult: true);
  }

  /// Out of the listing on file, once the bucket no longer has it: a
  /// listing that still names a deleted file offers it forever.
  Future<void> forgetBucketObject(String targetId, String key) async {
    final db = await _open();
    final batch = db.batch()
      ..delete(
        _bucketObjectTable,
        where: 'target_id = ? AND key = ?',
        whereArgs: [targetId, key],
      )
      ..insert(_bucketEditTable, {
        'target_id': targetId,
        'key': key,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    await batch.commit(noResult: true);
  }

  /// A removed bucket's listing, staged scan and edits. Its upload rows
  /// stay: they are what a re-added bucket (same derived id) and the
  /// delete guard read.
  Future<void> forgetBucketListing(String targetId) async {
    final db = await _open();
    await db.transaction((txn) async {
      for (final table in [
        _bucketObjectTable,
        _bucketEditTable,
        _bucketScanObjectTable,
        _bucketScanTable,
      ]) {
        await txn.delete(table, where: 'target_id = ?', whereArgs: [targetId]);
      }
    });
  }

  /// Buckets with a listing on file.
  Future<Set<String>> bucketTargetIds() async {
    final db = await _open();
    final rows = await db.rawQuery(
      'SELECT DISTINCT target_id FROM $_bucketObjectTable',
    );
    return {for (final r in rows) r['target_id'] as String};
  }

  Future<List<BucketObject>> listBucketObjects() async {
    final db = await _open();
    final rows = await db.query(_bucketObjectTable);
    return [
      for (final row in rows)
        BucketObject(
          targetId: row['target_id'] as String,
          key: row['key'] as String,
          size: row['size'] as int,
          lastModified: DateTime.fromMillisecondsSinceEpoch(
            row['last_modified'] as int,
          ),
        ),
    ];
  }

  /// Bumped by every write to a record row and never reset: what a result
  /// worked out from the library is compared against, across launches.
  Future<int> revision() async {
    final db = await _open();
    final rows = await db.rawQuery('SELECT n FROM $_revTable WHERE id = 0');
    return rows.isEmpty ? 0 : rows.first['n'] as int? ?? 0;
  }

  /// The bucket index and the upload rows in a few numbers, which move
  /// when either does. Three aggregate queries, no rows read out.
  Future<String> bucketStamp() async {
    final db = await _open();
    final o = (await db.rawQuery(
      'SELECT COUNT(*) AS c, TOTAL(size) AS s, MAX(last_modified) AS m, '
      'TOTAL(length(key)) AS k FROM $_bucketObjectTable',
    )).first;
    final d = (await db.rawQuery(
      'SELECT COUNT(*) AS c, TOTAL(length(destination_key)) AS k '
      'FROM $_derivativeTargetTable',
    )).first;
    return '${o['c']}|${o['s']}|${o['m']}|${o['k']}|${d['c']}|${d['k']}';
  }

  /// Every remote key some record points at - the "known" set a bucket
  /// object is held against.
  Future<Set<String>> referencedKeys() async {
    final db = await _open();
    final keys = <String>{};
    for (final row in await db.query(
      _derivativeTargetTable,
      columns: ['destination_key'],
    )) {
      keys.add(row['destination_key'] as String);
    }
    for (final record in await listAll()) {
      for (final kind in DerivativeKind.values) {
        final key = record.stateOf(kind).destinationKey;
        if (key != null) keys.add(key);
      }
    }
    return keys;
  }

  static const _createDerivativeTargetTableSql =
      '''
    CREATE TABLE $_derivativeTargetTable (
      local_id TEXT NOT NULL,
      kind TEXT NOT NULL,
      target_id TEXT NOT NULL,
      destination_key TEXT NOT NULL,
      source_hash TEXT,
      uploaded_at INTEGER NOT NULL,
      PRIMARY KEY (local_id, kind, target_id)
    )
  ''';

  /// Credits every derivative already marked uploaded to every target
  /// configured right now.
  ///
  /// A guess, and deliberately the optimistic one. The truth is unknowable
  /// — the old row recorded that *a* target took it and not which — so the
  /// choice is between believing what the app has believed all along, or
  /// re-uploading every library on earth to find out. Nothing gets worse
  /// than it is today, and every upload from here on is recorded properly.
  ///
  /// Targets are read from the row's own `destination_key`, which carries
  /// the prefix of the target it was written for, so a single-target
  /// install — the common case, and the one where the aggregate was never
  /// wrong — is credited exactly right.
  static Future<void> _adoptExistingUploads(Database db) async {
    final rows = await db.query(_table);
    final now = DateTime.now().millisecondsSinceEpoch;
    final batch = db.batch();
    for (final row in rows) {
      for (final kind in DerivativeKind.values) {
        final prefix = _columnPrefix(kind);
        if (row['${prefix}_status'] != UploadStatus.uploaded.name) continue;
        final key = row['${prefix}_key'] as String?;
        if (key == null || key.isEmpty) continue;
        batch.insert(_derivativeTargetTable, {
          'local_id': row['local_id'],
          'kind': kind.name,
          // Empty means "whichever target this key was written for" — the
          // only honest answer for a row written before this table existed.
          'target_id': '',
          'destination_key': key,
          'source_hash': row['${prefix}_hash'],
          'uploaded_at': now,
        }, conflictAlgorithm: sqflite.ConflictAlgorithm.ignore);
      }
    }
    await batch.commit(noResult: true);
  }

  /// Notes kept in a hidden album, sealed with the album's key. A row says
  /// only which album (a keyed tag, not the passcode hash) and when — what
  /// a note says is in `payload`. See `../vault/hidden_notes.dart`.
  static const _hiddenNoteTable = 'hidden_note';

  static const _createHiddenNoteTableSql =
      '''
    CREATE TABLE $_hiddenNoteTable (
      id TEXT PRIMARY KEY,
      album_tag TEXT NOT NULL,
      payload TEXT NOT NULL,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL
    )
  ''';

  /// Rows for [albumTag], newest first.
  Future<List<Map<String, Object?>>> hiddenNoteRows(String albumTag) async {
    final db = await _open();
    return db.query(
      _hiddenNoteTable,
      where: 'album_tag = ?',
      whereArgs: [albumTag],
      orderBy: 'created_at DESC',
    );
  }

  Future<void> putHiddenNote({
    required String id,
    required String albumTag,
    required String payload,
    required DateTime createdAt,
    required DateTime updatedAt,
  }) async {
    final db = await _open();
    await db.insert(_hiddenNoteTable, {
      'id': id,
      'album_tag': albumTag,
      'payload': payload,
      'created_at': createdAt.millisecondsSinceEpoch,
      'updated_at': updatedAt.millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> removeHiddenNote(String id) async {
    final db = await _open();
    await db.delete(_hiddenNoteTable, where: 'id = ?', whereArgs: [id]);
  }

  /// A hide or un-hide under way, one row per photo, so a kill part-way
  /// is finished on the next launch rather than left half done. See
  /// `../vault/hidden_transition.dart`.
  static const _transitionTable = 'hidden_transition';

  static const _createTransitionTableSql =
      '''
    CREATE TABLE IF NOT EXISTS $_transitionTable (
      local_id TEXT PRIMARY KEY,
      kind TEXT NOT NULL,
      step INTEGER NOT NULL,
      payload TEXT NOT NULL DEFAULT '',
      started_at INTEGER NOT NULL
    )
  ''';

  Future<List<TransitionRow>> openTransitions() async {
    final db = await _open();
    return [
      for (final row in await db.query(_transitionTable))
        TransitionRow(
          localId: row['local_id'] as String,
          kind: row['kind'] as String,
          step: row['step'] as int,
          payload: row['payload'] as String,
        ),
    ];
  }

  /// Opens (or restarts) [localId]'s journal entry at step 0. With
  /// [passcodeHash] the record is hidden in the same write.
  Future<void> openTransition(
    String localId,
    String kind, {
    String payload = '',
    String? passcodeHash,
  }) async {
    final db = await _open();
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.transaction((txn) async {
      if (passcodeHash != null) {
        await txn.update(
          _table,
          {'passcode_hash': passcodeHash, 'updated_at': now},
          where: 'local_id = ?',
          whereArgs: [localId],
        );
      }
      await txn.insert(_transitionTable, {
        'local_id': localId,
        'kind': kind,
        'step': 0,
        'payload': payload,
        'started_at': now,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }

  /// Forgets every upload of [localId] and moves its journal entry to
  /// [step], in one write: a kill can't leave the keys half reset. With
  /// [unhide] the passcode hash is cleared in the same write, so no
  /// upload ever sees the photo plain while it still names its carrier;
  /// with [moveTo] it becomes that album's, so its new album never
  /// claims the old one's carriers as its own.
  Future<void> retractUploads(
    String localId, {
    required int step,
    String? payload,
    bool unhide = false,
    String? moveTo,
  }) async {
    final db = await _open();
    await db.transaction((txn) async {
      await txn.delete(
        _derivativeTargetTable,
        where: 'local_id = ?',
        whereArgs: [localId],
      );
      await txn.update(
        _table,
        {
          for (final kind in DerivativeKind.values) ...{
            '${_columnPrefix(kind)}_status': UploadStatus.pending.name,
            '${_columnPrefix(kind)}_key': null,
            '${_columnPrefix(kind)}_hash': null,
          },
          'original_source': null,
          'has_edit': 0,
          if (unhide) 'passcode_hash': null else 'passcode_hash': ?moveTo,
          'updated_at': DateTime.now().millisecondsSinceEpoch,
        },
        where: 'local_id = ?',
        whereArgs: [localId],
      );
      await txn.update(
        _transitionTable,
        {'step': step, 'payload': ?payload},
        where: 'local_id = ?',
        whereArgs: [localId],
      );
    });
  }

  /// Ends [localId]'s journal entry. With [unhide] the passcode hash goes
  /// in the same write: a hide that didn't take.
  Future<void> closeTransition(String localId, {bool unhide = false}) async {
    final db = await _open();
    await db.transaction((txn) async {
      if (unhide) {
        await txn.update(
          _table,
          {
            'passcode_hash': null,
            'updated_at': DateTime.now().millisecondsSinceEpoch,
          },
          where: 'local_id = ?',
          whereArgs: [localId],
        );
      }
      await txn.delete(
        _transitionTable,
        where: 'local_id = ?',
        whereArgs: [localId],
      );
    });
  }

  /// Files [swap]; one per record. False when one is filed already.
  Future<bool> fileSwap(PendingSwap swap) async {
    final db = await _open();
    return db.transaction((txn) async {
      final filed = await txn.query(
        _pendingSwapTable,
        columns: ['local_id'],
        where: 'local_id = ?',
        whereArgs: [swap.localId],
      );
      if (filed.isNotEmpty) return false;
      await txn.insert(_pendingSwapTable, {
        'local_id': swap.localId,
        'old_asset': swap.oldAsset,
        'new_asset': swap.newAsset,
        'keeper_id': swap.keeperId,
        'flag': swap.flag,
        'keep_new': swap.keepNew ? 1 : 0,
        'width': swap.width,
        'height': swap.height,
        'old_bytes': swap.oldBytes,
        'new_bytes': swap.newBytes,
        'filed_at': DateTime.now().millisecondsSinceEpoch,
      });
      return true;
    });
  }

  Future<List<PendingSwap>> pendingSwaps() async {
    final db = await _open();
    return [
      for (final row in await db.query(_pendingSwapTable, orderBy: 'filed_at'))
        PendingSwap(
          localId: row['local_id'] as String,
          oldAsset: row['old_asset'] as String,
          newAsset: row['new_asset'] as String?,
          keeperId: row['keeper_id'] as String?,
          flag: row['flag'] as String?,
          keepNew: row['keep_new'] == 1,
          width: row['width'] as int?,
          height: row['height'] as int?,
          oldBytes: row['old_bytes'] as int,
          newBytes: row['new_bytes'] as int,
          provedAt: switch (row['proved_at']) {
            final int at => DateTime.fromMillisecondsSinceEpoch(at),
            _ => null,
          },
        ),
    ];
  }

  Future<int> pendingSwapCount() async {
    final db = await _open();
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS n FROM $_pendingSwapTable',
    );
    return rows.single['n'] as int;
  }

  Future<void> markSwapsProved(Iterable<String> localIds) async {
    final db = await _open();
    final at = DateTime.now().millisecondsSinceEpoch;
    final batch = db.batch();
    for (final id in localIds) {
      batch.update(
        _pendingSwapTable,
        {'proved_at': at},
        where: 'local_id = ?',
        whereArgs: [id],
      );
    }
    await batch.commit(noResult: true);
  }

  Future<void> dropSwaps(Iterable<String> localIds) async {
    final db = await _open();
    final batch = db.batch();
    for (final id in localIds) {
      batch.delete(_pendingSwapTable, where: 'local_id = ?', whereArgs: [id]);
    }
    await batch.commit(noResult: true);
  }

  /// A removal swap done: [localId] binned and its swap closed in one write.
  Future<void> binSwapped(String localId) async {
    final db = await _open();
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.transaction((txn) async {
      await txn.update(
        _table,
        {'deleted_at': now, 'binned_by': _binnedByUser, 'updated_at': now},
        where: 'local_id = ?',
        whereArgs: [localId],
      );
      await txn.delete(
        _pendingSwapTable,
        where: 'local_id = ?',
        whereArgs: [localId],
      );
    });
  }

  /// [localId] takes Photos asset [libraryId] over, in one write. A record
  /// already on that asset (a copy sync found first) gives its tags,
  /// caption, heart and place to [localId] and is dropped; its albums and
  /// people follow through [mergedInto]. With [closeSwap] the swap filed
  /// for [localId] closes in the same write.
  ///
  /// False, and nothing written, when [localId] is gone or the holder is
  /// hidden or locked.
  Future<bool> adoptAsset(
    String localId,
    String libraryId, {
    int? width,
    int? height,
    bool optimized = false,
    bool closeSwap = false,
  }) async {
    final db = await _open();
    final dropped = <String>[];
    final ok = await db.transaction((txn) async {
      final keeper = await txn.query(
        _table,
        where: 'local_id = ?',
        whereArgs: [localId],
      );
      if (keeper.isEmpty) return false;
      final holders = await txn.query(
        _table,
        where: 'library_id = ? AND local_id <> ?',
        whereArgs: [libraryId, localId],
      );
      if (holders.any(
        (h) => h['passcode_hash'] != null || h['is_locked'] == 1,
      )) {
        return false;
      }
      final k = keeper.single;
      final tags = <String>{
        for (final row in [k, ...holders])
          ...(jsonDecode(row['tags'] as String? ?? '[]') as List)
              .cast<String>(),
      };
      String? first(String column) => [k, ...holders]
          .map((r) => r[column])
          .whereType<String>()
          .where((v) => v.isNotEmpty)
          .firstOrNull;
      Object? any(String column) =>
          [k, ...holders].map((r) => r[column]).nonNulls.firstOrNull;
      final now = DateTime.now().millisecondsSinceEpoch;
      for (final h in holders) {
        final id = h['local_id'] as String;
        dropped.add(id);
        await txn.delete(_table, where: 'local_id = ?', whereArgs: [id]);
        await txn.delete(
          _derivativeTargetTable,
          where: 'local_id = ?',
          whereArgs: [id],
        );
        await txn.delete(
          _changeCheckTable,
          where: 'local_id = ?',
          whereArgs: [id],
        );
        await txn.insert(_appStateTable, {
          'key': '$_removedKeyPrefix$id',
          'value': localId,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await txn.update(
        _table,
        {
          'library_id': libraryId,
          if (optimized) 'local_optimized': 1,
          'width': ?width,
          'height': ?height,
          if (holders.isNotEmpty) ...{
            'tags': jsonEncode(tags.toList()),
            'description': first('description') ?? '',
            'location': first('location'),
            'latitude': any('latitude'),
            'longitude': any('longitude'),
            'is_favorite': [k, ...holders].any((r) => r['is_favorite'] == 1)
                ? 1
                : 0,
          },
          'updated_at': now,
        },
        where: 'local_id = ?',
        whereArgs: [localId],
      );
      if (closeSwap) {
        await txn.delete(
          _pendingSwapTable,
          where: 'local_id = ?',
          whereArgs: [localId],
        );
      }
      return true;
    });
    if (ok) _forgetCached(dropped);
    return ok;
  }

  static const _placeNameTable = 'place_name';

  static const _createPlaceNameTableSql =
      '''
    CREATE TABLE $_placeNameTable (
      cell TEXT PRIMARY KEY,
      name TEXT,
      updated_at INTEGER NOT NULL
    )
  ''';

  Future<void> close() async {
    await _db?.close();
    _db = null;
    _opening = null;
    _dropCache();
  }

  /// Empties this database, log and all.
  ///
  /// The log goes last and deliberately: the deletes above fire their
  /// triggers first, and each one writes the whole row it just removed
  /// into the log. Left there, "remove all app data" would keep a verbatim
  /// copy of every path, caption, tag and coordinate it claimed to erase.
  ///
  /// The cache has to be dropped by hand for the same reason [remove] says:
  /// a delete leaves no row behind for [listAll]'s incremental re-read to
  /// notice, so it would go on serving the library from before the wipe
  /// until the app was restarted.
  Future<void> clearAll() async {
    final db = await _open();
    final batch = db.batch()
      ..delete(_table)
      ..delete(_placeNameTable)
      ..delete(_appStateTable)
      ..delete(_derivativeTargetTable)
      ..delete(_hiddenNoteTable)
      ..delete(_transitionTable)
      ..delete(_pendingSwapTable)
      ..delete(_bucketObjectTable)
      ..delete(_bucketScanTable)
      ..delete(_bucketScanObjectTable)
      ..delete(_bucketEditTable)
      ..delete(_relinkTable)
      ..delete(_changeCheckTable)
      ..delete(changeLogTable);
    await batch.commit(noResult: true);
    _dropCache();
  }

  /// Marks restored [localId] as waiting for its asset on this phone.
  Future<void> markRelinkPending(String localId, DateTime createdAt) async {
    final db = await _open();
    await db.insert(_relinkTable, {
      'local_id': localId,
      'created_at': createdAt.millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> clearRelinkPending([String? localId]) async {
    final db = await _open();
    await db.delete(
      _relinkTable,
      where: localId == null ? null : 'local_id = ?',
      whereArgs: localId == null ? null : [localId],
    );
  }

  /// Whether any restored row is waiting for its asset.
  Future<bool> hasRelinkPending() async {
    final db = await _open();
    final rows = await db.rawQuery('SELECT 1 FROM $_relinkTable LIMIT 1');
    return rows.isNotEmpty;
  }

  /// The one restored row waiting for an asset taken at [createdAt] with
  /// this shape. Null when none, or when two could be it: a wrong merge is
  /// worse than a second record.
  Future<AssetRecord?> relinkCandidate({
    required DateTime createdAt,
    required bool isVideo,
    int? width,
    int? height,
  }) async {
    final db = await _open();
    final rows = await db.rawQuery(
      'SELECT a.* FROM $_relinkTable r JOIN $_table a '
      'ON a.local_id = r.local_id WHERE r.created_at = ?',
      [createdAt.millisecondsSinceEpoch],
    );
    final fits = [
      for (final row in rows)
        if (_sameShape(row, isVideo, width, height)) _fromRow(row),
    ];
    return fits.length == 1 ? fits.single : null;
  }

  /// The one scanned row (not restored, not [except]) on an asset taken at
  /// [createdAt] with this shape — what a restored row from another phone
  /// takes over.
  Future<AssetRecord?> scannedTwin({
    required DateTime createdAt,
    required bool isVideo,
    required String except,
    int? width,
    int? height,
  }) async {
    final db = await _open();
    final rows = await db.rawQuery(
      'SELECT * FROM $_table WHERE created_at = ? AND local_id <> ? '
      'AND library_id IS NOT NULL AND source_type = ? '
      'AND local_id NOT IN (SELECT local_id FROM $_relinkTable)',
      [
        createdAt.millisecondsSinceEpoch,
        except,
        AssetSourceType.photoManager.name,
      ],
    );
    final fits = [
      for (final row in rows)
        if (_sameShape(row, isVideo, width, height)) _fromRow(row),
    ];
    return fits.length == 1 ? fits.single : null;
  }

  /// Unknown sizes don't disagree; known ones must match.
  static bool _sameShape(
    Map<String, Object?> row,
    bool isVideo,
    int? width,
    int? height,
  ) {
    if ((row['is_video'] == 1) != isVideo) return false;
    final w = row['width'] as int?;
    final h = row['height'] as int?;
    return (w == null || width == null || w == width) &&
        (h == null || height == null || h == height);
  }

  /// Which targets already hold [kind] of [localId], as `targetId` →
  /// `destinationKey`.
  ///
  /// A legacy row from before this table existed comes back under the empty
  /// target id, meaning "some target, written for this key". [sourceHash]
  /// filters to targets holding *this* version of the file — a local edit
  /// since backup makes every target stale at once.
  Future<Map<String, String>> targetsHolding(
    String localId,
    DerivativeKind kind, {
    String? sourceHash,
  }) async {
    final db = await _open();
    final rows = await db.query(
      _derivativeTargetTable,
      where: 'local_id = ? AND kind = ?',
      whereArgs: [localId, kind.name],
    );
    return {
      for (final row in rows)
        if (sourceHash == null || row['source_hash'] == sourceHash)
          row['target_id'] as String: row['destination_key'] as String,
    };
  }

  /// Every per-bucket upload row, for the backup snapshot and for bulk
  /// deletes that would otherwise ask once per photo.
  /// Whether a photo other than [exceptLocalId] still names [key]: a file
  /// two photos share is not one photo's to delete.
  Future<bool> keyHeldByOthers(String key, String? exceptLocalId) async {
    final db = await _open();
    final except = exceptLocalId ?? '';
    final rows = await db.rawQuery(
      'SELECT 1 FROM $_derivativeTargetTable '
      'WHERE destination_key = ? AND local_id != ? '
      'UNION ALL SELECT 1 FROM $_table WHERE local_id != ? AND '
      '(original_key = ? OR thumbnail_key = ? OR medium_key = ? OR live_key = ? '
      'OR edited_key = ?) '
      'LIMIT 1',
      [key, except, except, key, key, key, key, key],
    );
    return rows.isNotEmpty;
  }

  Future<bool> isListed(String targetId, String key) async {
    final db = await _open();
    final rows = await db.rawQuery(
      'SELECT 1 FROM $_bucketObjectTable WHERE target_id = ? AND key = ? '
      'LIMIT 1',
      [targetId, key],
    );
    return rows.isNotEmpty;
  }

  /// Listed objects beside [key] under its name with another extension.
  Future<List<String>> listedSiblings(String targetId, String key) async {
    final stem = p.posix.withoutExtension(key);
    if (RegExp(r'[*?\[\]]').hasMatch(stem)) return const [];
    final db = await _open();
    final rows = await db.rawQuery(
      'SELECT key FROM $_bucketObjectTable '
      'WHERE target_id = ? AND key GLOB ? AND key != ?',
      [targetId, '$stem.*', key],
    );
    return [for (final row in rows) row['key'] as String];
  }

  /// Whether a record's original already has [stem] as its name, in any
  /// format: a replace keeps the name and changes only the extension.
  ///
  /// [prefixes] (the buckets' key prefixes) first try the protocol place,
  /// `<prefix>originals/<stem>.*`, on the key indexes. A miss there still
  /// scans every key: one under another prefix or folder must not be
  /// missed, as this keeps a second record off a held original.
  Future<bool> originalStemHeld(
    String stem, {
    Iterable<String> prefixes = const [],
  }) async {
    if (RegExp(r'[*?\[\]]').hasMatch(stem)) return false;
    final db = await _open();
    for (final prefix in prefixes.toSet()) {
      final dir = prefix.isEmpty || prefix.endsWith('/') ? prefix : '$prefix/';
      // '/' follows '.' in byte order: the range is every '<stem>.<ext>'.
      final at = '${dir}originals/$stem.';
      final end = '${dir}originals/$stem/';
      final rows = await db.rawQuery(
        'SELECT 1 FROM $_derivativeTargetTable '
        "WHERE destination_key >= ? AND destination_key < ? AND kind = 'original' "
        'UNION ALL SELECT 1 FROM $_table '
        'WHERE original_key >= ? AND original_key < ? '
        'LIMIT 1',
        [at, end, at, end],
      );
      if (rows.isNotEmpty) return true;
    }
    final pattern = '*/$stem.*';
    final rows = await db.rawQuery(
      'SELECT 1 FROM $_derivativeTargetTable '
      "WHERE kind = 'original' AND destination_key GLOB ? "
      'UNION ALL SELECT 1 FROM $_table WHERE original_key GLOB ? '
      'LIMIT 1',
      [pattern, pattern],
    );
    return rows.isNotEmpty;
  }

  Future<List<Map<String, Object?>>> uploadRows() async {
    final db = await _open();
    return db.query(_derivativeTargetTable);
  }

  Future<void> recordUpload({
    required String localId,
    required DerivativeKind kind,
    required String targetId,
    required String destinationKey,
    String? sourceHash,
  }) async {
    final db = await _open();
    final batch = db.batch()
      ..insert(_derivativeTargetTable, {
        'local_id': localId,
        'kind': kind.name,
        'target_id': targetId,
        'destination_key': destinationKey,
        'source_hash': sourceHash,
        'uploaded_at': DateTime.now().millisecondsSinceEpoch,
      }, conflictAlgorithm: sqflite.ConflictAlgorithm.replace)
      // Uploaded again under a key forgotten earlier: the scan's word
      // stands for it, not the forget.
      ..delete(
        _bucketEditTable,
        where: 'target_id = ? AND key = ? AND size IS NULL',
        whereArgs: [targetId, destinationKey],
      );
    await batch.commit(noResult: true);
  }

  /// Points an existing upload row at a new key, leaving its hash and time
  /// alone - a rename is not a new upload, and must not read as an edit.
  Future<void> renameUploadKey({
    required String localId,
    required DerivativeKind kind,
    required String targetId,
    required String destinationKey,
  }) async {
    final db = await _open();
    await db.update(
      _derivativeTargetTable,
      {'destination_key': destinationKey},
      where: 'local_id = ? AND kind = ? AND target_id = ?',
      whereArgs: [localId, kind.name, targetId],
    );
  }

  /// Every upload row at once, `localId` → kind → `targetId` →
  /// `destinationKey`: one query for a pass over the library, not one per
  /// photo.
  Future<Map<String, Map<DerivativeKind, Map<String, String>>>>
  allHoldings() async {
    final db = await _open();
    final rows = await db.query(_derivativeTargetTable);
    final out = <String, Map<DerivativeKind, Map<String, String>>>{};
    for (final row in rows) {
      final kind = DerivativeKind.values.asNameMap()[row['kind']];
      if (kind == null) continue;
      ((out[row['local_id'] as String] ??= {})[kind] ??= {})[row['target_id']
              as String] =
          row['destination_key'] as String;
    }
    return out;
  }

  /// Forgets that one target holds [kind] of [localId] — the object is gone
  /// from it, so the next sync uploads it there again.
  Future<void> forgetTargetUpload(
    String localId,
    DerivativeKind kind,
    String targetId,
  ) async {
    final db = await _open();
    await db.delete(
      _derivativeTargetTable,
      where: 'local_id = ? AND kind = ? AND target_id = ?',
      whereArgs: [localId, kind.name, targetId],
    );
  }

  /// Forgets where a photo's derivatives went — what hiding one does, so
  /// the next sync treats it as never uploaded.
  Future<void> forgetUploads(String localId) async {
    final db = await _open();
    await db.delete(
      _derivativeTargetTable,
      where: 'local_id = ?',
      whereArgs: [localId],
    );
  }

  /// How far this database's change log has got. See `change_log.dart`.
  Future<int> changeMark() async => changeLogMark(await _open());

  /// The tail of this database's change log, for the copy in the backup.
  /// [decode] false: `before`/`after` as JSON text.
  Future<List<Map<String, Object?>>> changeLogRows({bool decode = true}) async {
    final db = await _open();
    // Before the first copy leaves, not after the first frame.
    await _purgePrivateLog(db);
    return changeLogTail(db, decode: decode);
  }

  /// Inserts a new record if `localId` isn't tracked yet. If one already
  /// exists, refreshes `sourcePath` when it's changed (e.g. demo/manual
  /// files re-copied to a new app container path after a reinstall) —
  /// otherwise a stale path could never heal.
  /// [addedAt] is for a restore, which carries the original arrival time.
  /// [createdAt] backdates a freshly-inserted record (used by
  /// `DemoAssetsService` to spread demo assets across days/years so the
  /// day-grouped grid isn't just one giant "Today" section); ignored for an
  /// already-tracked `localId`, and defaults to now.
  /// [passcodeHash] and [isHidden] likewise only on insert: a copy of a
  /// hidden photo is hidden from its first write.
  Future<AssetRecord> upsert({
    required String localId,
    required String contentHash,
    required String platform,
    AssetSourceType sourceType = AssetSourceType.photoManager,
    String? sourcePath,
    bool isVideo = false,
    bool isLivePhoto = false,
    bool isGif = false,
    DateTime? createdAt,
    DateTime? addedAt,
    double? latitude,
    double? longitude,
    int? width,
    int? height,
    String? libraryId,
    String? passcodeHash,
    bool isHidden = false,
    bool isArchived = false,
    bool peopleOnly = false,
    bool keepOnLibraryConflict = false,
  }) async {
    final db = await _open();
    final existing = await getByLocalId(localId);
    if (existing != null) {
      if (sourcePath == null || sourcePath == existing.sourcePath) {
        return existing;
      }
      final now = DateTime.now();
      await db.update(
        _table,
        {'source_path': sourcePath, 'updated_at': now.millisecondsSinceEpoch},
        where: 'local_id = ?',
        whereArgs: [localId],
      );
      return existing.withSourcePath(sourcePath, now);
    }

    final added = addedAt ?? DateTime.now();
    final now = createdAt ?? added;
    // One record per asset (the unique index): a scan that finds the asset
    // already held gets the holder back. A restore keeps its row, unlinked,
    // rather than lose the metadata written after it.
    if (libraryId != null) {
      final holder = await db.query(
        _table,
        columns: ['local_id'],
        where: 'library_id = ?',
        whereArgs: [libraryId],
        limit: 1,
      );
      if (holder.isNotEmpty) {
        if (!keepOnLibraryConflict) {
          final held = await getByLocalId(holder.single['local_id'] as String);
          if (held != null) return held;
        }
        libraryId = null;
      }
    }
    final row = {
      'local_id': localId,
      'content_hash': contentHash,
      'platform': platform,
      'source_type': sourceType.name,
      'source_path': sourcePath,
      'is_video': isVideo ? 1 : 0,
      'is_live_photo': isLivePhoto ? 1 : 0,
      'is_gif': isGif ? 1 : 0,
      'library_id': libraryId,
      'latitude': latitude,
      'longitude': longitude,
      'width': width,
      'height': height,
      'passcode_hash': passcodeHash,
      'is_hidden': isHidden ? 1 : 0,
      'is_archived': isArchived ? 1 : 0,
      'people_only': peopleOnly ? 1 : 0,
      'created_at': now.millisecondsSinceEpoch,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
      'added_at': added.millisecondsSinceEpoch,
    };
    try {
      await db.insert(_table, row);
    } on sqflite.DatabaseException catch (e) {
      // Raced by another insert of the same photo: that one stands.
      if (!e.isUniqueConstraintError()) rethrow;
      final raced =
          await getByLocalId(localId) ??
          (libraryId == null ? null : await getByLibraryId(libraryId));
      if (raced == null) rethrow;
      return raced;
    }
    return AssetRecord(
      localId: localId,
      contentHash: contentHash,
      platform: platform,
      sourceType: sourceType,
      sourcePath: sourcePath,
      isVideo: isVideo,
      isLivePhoto: isLivePhoto,
      isGif: isGif,
      libraryId: libraryId,
      latitude: latitude,
      longitude: longitude,
      width: width,
      height: height,
      passcodeHash: passcodeHash,
      isHidden: isHidden,
      isArchived: isArchived,
      peopleOnly: peopleOnly,
      createdAt: now,
      updatedAt: now,
      addedAt: added,
    );
  }

  Future<AssetRecord?> getByLocalId(String localId) async {
    final db = await _open();
    final rows = await db.query(
      _table,
      where: 'local_id = ?',
      whereArgs: [localId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _healed(_fromRow(rows.single));
  }

  /// Repairs a record whose `sourcePath` no longer exists by re-resolving
  /// its filename under the current app-support directory. A no-op (and no
  /// `path_provider` call) when the path already resolves.
  ///
  /// Any record holding a file of this app's own, not just a manually-added
  /// one. A hidden photo is a camera-roll record that owns a copy — the
  /// app took it out of Photos and holds the only one — and leaving it out
  /// of the healing meant that after a reinstall moved the container, its
  /// path pointed nowhere and its backup failed with "path not found"
  /// forever. The paths are absolute and the container's UUID isn't stable
  /// across installs, which is exactly the case this exists for.
  Future<AssetRecord> _healed(AssetRecord record) async {
    final path = record.sourcePath;
    if (path == null || await File(path).exists()) return record;
    // Looked up once and kept: asking the platform for the same directory
    // again per record is a channel round-trip for an answer that cannot
    // change. Failure means no platform to ask (a pure-Dart test) — the
    // record is handed back as it is rather than taking the read down.
    Directory dir;
    try {
      dir = _appSupport ??= await _appSupportDirectory();
    } catch (_) {
      return record;
    }
    final healedPath = await _rehomed(path, dir.path);
    if (healedPath == null) return record;

    final now = DateTime.now();
    final db = await _open();
    await db.update(
      _table,
      {'source_path': healedPath, 'updated_at': now.millisecondsSinceEpoch},
      where: 'local_id = ?',
      whereArgs: [record.localId],
    );
    return record.withSourcePath(healedPath, now);
  }

  Future<void> updateDerivative(
    String localId,
    DerivativeKind kind,
    DerivativeState state,
  ) async {
    final db = await _open();
    final column = _columnPrefix(kind);
    await db.update(
      _table,
      {
        '${column}_status': state.status.name,
        '${column}_key': state.destinationKey,
        '${column}_hash': state.backedUpHash,
        if (kind == DerivativeKind.original)
          'original_source': state.fromResource ? _resourceSource : null,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'local_id = ?',
      whereArgs: [localId],
    );
  }

  /// Points a record at a local file it didn't have before — how
  /// `OriginalRestore` hands a re-downloaded original back to a record,
  /// including a `photoManager` one whose OS library entry is gone for
  /// good (resolution checks `sourcePath` before the library either way).
  Future<void> setSourcePath(String localId, String value) async {
    final db = await _open();
    await db.update(
      _table,
      {
        'source_path': value,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'local_id = ?',
      whereArgs: [localId],
    );
  }

  Future<void> setLivePhoto(String localId, bool value) async {
    final db = await _open();
    await db.update(
      _table,
      {
        'is_live_photo': value ? 1 : 0,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'local_id = ?',
      whereArgs: [localId],
    );
  }

  /// See [AssetRecord.hasEdit].
  Future<void> setHasEdit(String localId, bool value) async {
    final db = await _open();
    await db.update(
      _table,
      {
        'has_edit': value ? 1 : 0,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'local_id = ?',
      whereArgs: [localId],
    );
  }

  /// Null clears it — what a hidden record wants, since it keeps no
  /// picture of itself on this device.
  Future<void> setThumbnailPath(String localId, String? value) async {
    final db = await _open();
    await db.update(
      _table,
      {
        'thumbnail_path': value,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'local_id = ?',
      whereArgs: [localId],
    );
  }

  /// Flips the "full-resolution local copy is gone, cloud copy isn't" state
  /// — see [AssetRecord.localDeleted]. Clearing it is what re-downloading
  /// the original from the bucket does.
  Future<void> setLocalDeleted(String localId, bool value) async {
    final db = await _open();
    await db.update(
      _table,
      {
        'local_deleted': value ? 1 : 0,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'local_id = ?',
      whereArgs: [localId],
    );
  }

  Future<void> setFavorite(String localId, bool value) async {
    final db = await _open();
    await db.update(
      _table,
      {
        'is_favorite': value ? 1 : 0,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'local_id = ?',
      whereArgs: [localId],
    );
  }

  Future<void> setLocked(String localId, bool value) async {
    final db = await _open();
    await db.update(
      _table,
      {
        'is_locked': value ? 1 : 0,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'local_id = ?',
      whereArgs: [localId],
    );
  }

  /// Marks archived photos as their people's only (see
  /// [AssetRecord.peopleOnly]); one not archived is left alone.
  Future<void> setPeopleOnly(Iterable<String> localIds, bool value) async {
    final ids = localIds.toList();
    if (ids.isEmpty) return;
    final db = await _open();
    await db.transaction((txn) async {
      final now = DateTime.now().millisecondsSinceEpoch;
      for (var i = 0; i < ids.length; i += 500) {
        final chunk = ids.sublist(i, min(i + 500, ids.length));
        await txn.update(
          _table,
          {'people_only': value ? 1 : 0, 'updated_at': now},
          where:
              'is_archived = 1 AND people_only != ? AND local_id IN '
              '(${List.filled(chunk.length, '?').join(',')})',
          whereArgs: [value ? 1 : 0, ...chunk],
        );
      }
    });
  }

  /// One statement for any number of photos: archiving a trip is one tap.
  Future<void> setArchived(Iterable<String> localIds, bool value) async {
    final ids = localIds.toList();
    if (ids.isEmpty) return;
    final db = await _open();
    await db.transaction((txn) async {
      final now = DateTime.now().millisecondsSinceEpoch;
      for (var i = 0; i < ids.length; i += 500) {
        final chunk = ids.sublist(i, min(i + 500, ids.length));
        await txn.update(
          _table,
          {
            'is_archived': value ? 1 : 0,
            // Out of Archive is into the library, people-only or not.
            if (!value) 'people_only': 0,
            'updated_at': now,
          },
          where: 'local_id IN (${List.filled(chunk.length, '?').join(',')})',
          whereArgs: chunk,
        );
      }
    });
  }

  Future<void> setLocalOptimized(String localId, bool value) async {
    final db = await _open();
    await db.update(
      _table,
      {
        'local_optimized': value ? 1 : 0,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'local_id = ?',
      whereArgs: [localId],
    );
  }

  Future<void> setCreatedAt(String localId, DateTime value) async {
    final db = await _open();
    await db.update(
      _table,
      {
        'created_at': value.millisecondsSinceEpoch,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'local_id = ?',
      whereArgs: [localId],
    );
  }

  Future<void> setDescription(String localId, String value) async {
    final db = await _open();
    await db.update(
      _table,
      {
        'description': value,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'local_id = ?',
      whereArgs: [localId],
    );
  }

  Future<void> setTags(String localId, List<String> value) async {
    final db = await _open();
    await db.update(
      _table,
      {
        'tags': jsonEncode(value),
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'local_id = ?',
      whereArgs: [localId],
    );
  }

  Future<void> setLocation(String localId, String? value) async {
    final db = await _open();
    await db.update(
      _table,
      {'location': value, 'updated_at': DateTime.now().millisecondsSinceEpoch},
      where: 'local_id = ?',
      whereArgs: [localId],
    );
  }

  /// [names] by local id, in one transaction, each only where no location
  /// is set (one typed meanwhile wins). How many were written.
  Future<int> fillLocations(Map<String, String> names) async {
    if (names.isEmpty) return 0;
    final db = await _open();
    final now = DateTime.now().millisecondsSinceEpoch;
    return db.transaction((txn) async {
      var written = 0;
      for (final MapEntry(key: id, value: name) in names.entries) {
        written += await txn.rawUpdate(
          'UPDATE $_table SET location = ?, updated_at = ? '
          "WHERE local_id = ? AND (location IS NULL OR location = '')",
          [name, now, id],
        );
      }
      return written;
    });
  }

  Future<String?> getAppState(String key) async {
    final db = await _open();
    final rows = await db.query(
      _appStateTable,
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.single['value'] as String?;
  }

  Future<void> setAppState(String key, String value) async {
    final db = await _open();
    await db.insert(_appStateTable, {
      'key': key,
      'value': value,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Which photo-library asset this record is the record of. Set to null
  /// when the photo leaves the library (hidden), and to the new asset's id
  /// when it's handed back — see `LibraryCustody`.
  Future<void> setLibraryId(String localId, String? value) async {
    final db = await _open();
    await db.update(
      _table,
      {
        'library_id': value,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'local_id = ?',
      whereArgs: [localId],
    );
  }

  /// The record for a photo-library asset, whatever this app calls it —
  /// how the scan recognises a photo it already tracks.
  /// [getByLocalId] for many at once, a query per 900, keyed by local id.
  Future<Map<String, AssetRecord>> getByLocalIds(
    Iterable<String> localIds,
  ) async {
    final ids = localIds.toSet().toList();
    final out = <String, AssetRecord>{};
    if (ids.isEmpty) return out;
    final db = await _open();
    for (var i = 0; i < ids.length; i += 900) {
      final chunk = ids.skip(i).take(900).toList();
      final rows = await db.query(
        _table,
        where: 'local_id IN (${List.filled(chunk.length, '?').join(',')})',
        whereArgs: chunk,
      );
      for (final row in rows) {
        final record = await _healed(_fromRow(row));
        out[record.localId] = record;
      }
    }
    return out;
  }

  /// [getByLibraryId] for a page of assets in one query, keyed by library
  /// id.
  Future<Map<String, AssetRecord>> getByLibraryIds(
    Iterable<String> libraryIds,
  ) async {
    final ids = libraryIds.toSet().toList();
    final out = <String, AssetRecord>{};
    if (ids.isEmpty) return out;
    final db = await _open();
    // Two parameters per id, under SQLite's 999.
    for (var i = 0; i < ids.length; i += 400) {
      final chunk = ids.skip(i).take(400).toList();
      final marks = List.filled(chunk.length, '?').join(',');
      final rows = await db.query(
        _table,
        where:
            'library_id IN ($marks) '
            'OR (library_id IS NULL AND local_id IN ($marks))',
        whereArgs: [...chunk, for (final id in chunk) 'photo:$id'],
        orderBy: 'library_id IS NULL',
      );
      for (final row in rows) {
        final id =
            row['library_id'] as String? ??
            (row['local_id'] as String).substring('photo:'.length);
        if (out.containsKey(id)) continue;
        out[id] = await _healed(_fromRow(row));
      }
    }
    return out;
  }

  Future<AssetRecord?> getByLibraryId(String libraryId) async {
    final db = await _open();
    final rows = await db.query(
      _table,
      // The second clause is for rows written before `library_id` existed,
      // which carry the library's id inside their own and may not have
      // been re-scanned since the migration that lifts it out.
      where: 'library_id = ? OR (library_id IS NULL AND local_id = ?)',
      whereArgs: [libraryId, 'photo:$libraryId'],
      // The real link before the old-row fallback.
      orderBy: 'library_id IS NULL',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _healed(_fromRow(rows.single));
  }

  /// What the photo library itself knows about a photo — where it was
  /// taken, how big it is. Fills blanks only: a null argument means "the
  /// library didn't say", and leaves whatever's stored alone.
  Future<void> setLibraryMetadata(
    String localId, {
    double? latitude,
    double? longitude,
    int? width,
    int? height,
  }) async {
    final values = <String, Object?>{
      'latitude': ?latitude,
      'longitude': ?longitude,
      'width': ?width,
      'height': ?height,
    };
    if (values.isEmpty) return;
    final db = await _open();
    await db.update(
      _table,
      {...values, 'updated_at': DateTime.now().millisecondsSinceEpoch},
      where: 'local_id = ?',
      whereArgs: [localId],
    );
  }

  /// A scan page's new assets in one transaction, as [upsert] would add
  /// each: a `local_id` or `library_id` already taken leaves the row out
  /// (one record per asset). Returns, by library id, the record now on
  /// each asset; one left out for its `local_id` is missing from it.
  Future<Map<String, AssetRecord>> insertScanned(
    List<ScannedAsset> assets,
  ) async {
    if (assets.isEmpty) return {};
    final db = await _open();
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final a in assets) {
        batch.insert(_table, {
          'local_id': a.localId,
          'content_hash': a.libraryId,
          'platform': a.platform,
          'source_type': AssetSourceType.photoManager.name,
          'is_video': a.isVideo ? 1 : 0,
          'is_live_photo': a.isLivePhoto ? 1 : 0,
          'is_gif': a.isGif ? 1 : 0,
          'is_favorite': a.isFavorite ? 1 : 0,
          'library_id': a.libraryId,
          'latitude': a.latitude,
          'longitude': a.longitude,
          'width': a.width,
          'height': a.height,
          'is_hidden': 0,
          'created_at': a.createdAt.millisecondsSinceEpoch,
          'updated_at': now,
          'added_at': now,
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
      }
      await batch.commit(noResult: true);
    });
    return getByLibraryIds(assets.map((a) => a.libraryId));
  }

  /// A scan page's favourite and [setLibraryMetadata] writes, in one
  /// transaction.
  Future<void> applyScanUpdates({
    Map<String, bool> favorites = const {},
    Map<String, LibraryMetadata> metadata = const {},
  }) async {
    if (favorites.isEmpty && metadata.isEmpty) return;
    final db = await _open();
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final MapEntry(key: localId, value: on) in favorites.entries) {
        batch.update(
          _table,
          {'is_favorite': on ? 1 : 0, 'updated_at': now},
          where: 'local_id = ?',
          whereArgs: [localId],
        );
      }
      for (final MapEntry(key: localId, value: m) in metadata.entries) {
        final values = <String, Object?>{
          'latitude': ?m.latitude,
          'longitude': ?m.longitude,
          'width': ?m.width,
          'height': ?m.height,
        };
        if (values.isEmpty) continue;
        batch.update(
          _table,
          {...values, 'updated_at': now},
          where: 'local_id = ?',
          whereArgs: [localId],
        );
      }
      await batch.commit(noResult: true);
    });
  }

  /// The modification dates a scan just listed, `localId` → seconds. Only
  /// a date that moved is written.
  Future<void> noteModified(Map<String, int> seen) async {
    if (seen.isEmpty) return;
    final db = await _open();
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final MapEntry(key: localId, value: at) in seen.entries) {
        batch.rawInsert(
          'INSERT INTO $_changeCheckTable (local_id, seen) VALUES (?, ?) '
          'ON CONFLICT (local_id) DO UPDATE SET seen = excluded.seen '
          'WHERE seen IS NOT excluded.seen',
          [localId, at],
        );
      }
      await batch.commit(noResult: true);
    });
  }

  /// Cloud-only, backed-up photos, the longest since a spot check first
  /// (never before ever), then oldest. Loose on purpose (the original
  /// up, not every part): the caller applies the exact test, so a rule
  /// that drifts here can only offer more, never hide one.
  Future<List<String>> spotCheckOrder({
    required int limit,
    int offset = 0,
  }) async {
    final db = await _open();
    final rows = await db.rawQuery(
      'SELECT r.local_id FROM $_table r '
      'LEFT JOIN $_changeCheckTable c ON c.local_id = r.local_id '
      'WHERE r.local_deleted = 1 AND r.deleted_at IS NULL '
      "AND r.passcode_hash IS NULL AND r.original_status = 'uploaded' "
      'ORDER BY COALESCE(c.spot_checked, 0), r.created_at, r.local_id '
      'LIMIT ? OFFSET ?',
      [limit, offset],
    );
    return [for (final r in rows) r['local_id'] as String];
  }

  /// The spot check had the bucket's answer for these, `localId` → ms.
  Future<void> markSpotChecked(Map<String, int> at) async {
    if (at.isEmpty) return;
    final db = await _open();
    final batch = db.batch();
    for (final MapEntry(key: localId, value: ms) in at.entries) {
      batch.rawInsert(
        'INSERT INTO $_changeCheckTable (local_id, spot_checked) '
        'VALUES (?, ?) ON CONFLICT (local_id) DO UPDATE SET '
        'spot_checked = excluded.spot_checked',
        [localId, ms],
      );
    }
    await batch.commit(noResult: true);
  }

  /// [localId] matched its backup as of [modified]: no check is owed until
  /// the date moves again.
  Future<void> markChecked(String localId, int modified) async {
    final db = await _open();
    await db.rawInsert(
      'INSERT INTO $_changeCheckTable (local_id, seen, checked) '
      'VALUES (?, ?, ?) ON CONFLICT (local_id) DO UPDATE SET '
      'seen = excluded.seen, checked = excluded.checked',
      [localId, modified, modified],
    );
  }

  /// The date [localId] last matched its backup as of, or null if never.
  Future<int?> checkedModified(String localId) async {
    final db = await _open();
    final rows = await db.rawQuery(
      'SELECT checked FROM $_changeCheckTable WHERE local_id = ?',
      [localId],
    );
    return rows.firstOrNull?['checked'] as int?;
  }

  /// Backed-up photos still on this phone owed a change check: never
  /// checked, or a scan saw a date other than the one they were checked
  /// at. Held files have no scan to stamp them; see [fileCheckBaselines].
  Future<Set<String>> changeChecksDue() async {
    final db = await _open();
    final rows = await db.rawQuery(
      'SELECT r.local_id FROM $_table r '
      'LEFT JOIN $_changeCheckTable c ON c.local_id = r.local_id '
      "WHERE r.original_status = 'uploaded' AND r.local_deleted = 0 "
      'AND r.passcode_hash IS NULL '
      'AND (c.checked IS NULL OR c.seen IS NOT c.checked)',
    );
    return {for (final r in rows) r['local_id'] as String};
  }

  /// `checked` for backed-up records read from a file here, which the
  /// caller compares against the file's own date.
  Future<Map<String, int>> fileCheckBaselines() async {
    final db = await _open();
    final rows = await db.rawQuery(
      'SELECT c.local_id, c.checked FROM $_changeCheckTable c '
      'JOIN $_table r ON r.local_id = c.local_id '
      "WHERE r.source_path IS NOT NULL AND r.original_status = 'uploaded' "
      'AND c.checked IS NOT NULL',
    );
    return {for (final r in rows) r['local_id'] as String: r['checked'] as int};
  }

  /// How long a put may finish after its file was read: an upload row's
  /// time is when the transfer ended, not when the bytes were taken.
  static const uploadReadSlack = Duration(hours: 24);

  /// A legacy camera-roll backup (a render's hash, `original_source` NULL)
  /// known current without reading the photo: the asset was last modified
  /// at least [uploadReadSlack] before a per-bucket upload of exactly the
  /// recorded version. Rows adopted from before per-bucket state
  /// (`target_id` '') carry the adoption time, not the upload's, and never
  /// count. Shared by [rebaselineChangeChecks] and [backupPredates].
  static const _legacyUploadedAtSql =
      'SELECT MAX(t.uploaded_at) FROM $_derivativeTargetTable t '
      'JOIN $_table r ON r.local_id = t.local_id '
      "WHERE t.local_id = {id} AND t.kind = 'original' AND t.target_id != '' "
      'AND t.source_hash IS NOT NULL AND t.source_hash = r.original_hash '
      "AND r.original_status = 'uploaded' AND r.original_source IS NULL "
      'AND r.source_path IS NULL AND r.passcode_hash IS NULL '
      "AND r.local_deleted = 0 AND r.source_type = 'photoManager'";

  /// PW3b's one-time re-baseline, without a render: every legacy backup a
  /// scan's date shows unmodified since it went up is marked checked at
  /// that date, so its change check reads no file. Idempotent; the rest
  /// wait for their check. Returns how many it settled.
  Future<int> rebaselineChangeChecks() async {
    final db = await _open();
    return db.rawUpdate(
      'UPDATE $_changeCheckTable SET checked = seen '
      'WHERE seen IS NOT NULL AND checked IS NOT seen '
      'AND seen * 1000 <= '
      '(${_legacyUploadedAtSql.replaceAll('{id}', '$_changeCheckTable.local_id')}) - ?',
      [uploadReadSlack.inMilliseconds],
    );
  }

  /// [rebaselineChangeChecks] for one photo, against its live date
  /// (seconds).
  Future<bool> backupPredates(String localId, int modified) async {
    final db = await _open();
    final rows = await db.rawQuery(
      'SELECT (${_legacyUploadedAtSql.replaceAll('{id}', '?')}) AS at',
      [localId],
    );
    final at = rows.firstOrNull?['at'] as int?;
    return at != null && modified * 1000 <= at - uploadReadSlack.inMilliseconds;
  }

  /// Photos carrying a GPS tag that nobody — neither the user nor the
  /// geocoder — has put a name to yet, newest first. Photos in a cell the
  /// geocoder recently said is empty are left out, so they can't fill the
  /// page and hide everything older (05#8).
  Future<List<AssetRecord>> listAwaitingPlaceName({int limit = 200}) async {
    final db = await _open();
    final rows = await db.rawQuery(
      'SELECT * FROM $_table WHERE $_awaitingPlaceSql '
      'AND ${_cellSql('latitude')} || \':\' || ${_cellSql('longitude')} '
      'NOT IN (SELECT cell FROM $_placeNameTable '
      'WHERE name IS NULL AND updated_at > ?) '
      'ORDER BY created_at DESC LIMIT ?',
      [_emptyCellSince(), limit],
    );
    return rows.map(_fromRow).toList();
  }

  /// `PhotoLocationService.cellFor` in SQL: floor(v / 0.05).
  static String _cellSql(String column) =>
      '(CAST($column / 0.05 AS INTEGER) - '
      '($column / 0.05 < CAST($column / 0.05 AS INTEGER)))';

  /// How long a geocoder's "nothing there" is believed before it is asked
  /// again.
  static const emptyCellLifetime = Duration(days: 30);

  static int _emptyCellSince() =>
      DateTime.now().subtract(emptyCellLifetime).millisecondsSinceEpoch;

  /// The name already worked out for a patch of the world, or `null` if
  /// that patch has never been looked up (or its "nothing there" is older
  /// than [emptyCellLifetime]). The record it returns can itself hold a
  /// null [PlaceNameEntry.name] — a remembered "nothing there".
  Future<PlaceNameEntry?> cachedPlaceName(String cell) async {
    final db = await _open();
    final rows = await db.query(
      _placeNameTable,
      where: 'cell = ?',
      whereArgs: [cell],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final name = rows.single['name'] as String?;
    final at = (rows.single['updated_at'] as num?)?.toInt() ?? 0;
    if (name == null && at <= _emptyCellSince()) return null;
    return PlaceNameEntry(name);
  }

  Future<void> cachePlaceName(String cell, String? name) async {
    final db = await _open();
    await db.insert(_placeNameTable, {
      'cell': cell,
      'name': name,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Every distinct location already used across all photos — the
  /// searchable-picker's "select if exists" list for the detail screen's
  /// Location field.
  Future<Set<String>> allLocations() async {
    final db = await _open();
    final at = await _pickerStamp(db);
    if (_locations case (final stamp, final cached) when stamp == at) {
      return {...cached};
    }
    final rows = await db.query(
      _table,
      columns: ['location'],
      distinct: true,
      where: "location IS NOT NULL AND location != ''",
    );
    final found = rows.map((r) => r['location'] as String).toSet();
    _locations = (at, found);
    return {...found};
  }

  (String, Set<String>)? _locations;
  (String, Set<String>)? _tags;

  /// What the picker lists are memoised on: [revision] moves with every
  /// row write, the count with a delete.
  Future<String> _pickerStamp(Database db) async {
    final rows = await db.rawQuery(
      'SELECT (SELECT n FROM $_revTable WHERE id = 0) AS n, '
      '(SELECT COUNT(*) FROM $_table) AS c',
    );
    return '${rows.first['n']}:${rows.first['c']}';
  }

  /// Every distinct tag already used across all photos — same "select if
  /// exists" role as [allLocations], for the Tags field.
  Future<Set<String>> allTags() async {
    final db = await _open();
    final at = await _pickerStamp(db);
    if (_tags case (final stamp, final cached) when stamp == at) {
      return {...cached};
    }
    final rows = await db.query(
      _table,
      columns: ['tags'],
      where: "tags != '[]'",
    );
    final result = <String>{};
    for (final row in rows) {
      final tags = jsonDecode(row['tags'] as String? ?? '[]') as List<dynamic>;
      result.addAll(tags.cast<String>());
    }
    _tags = (at, result);
    return {...result};
  }

  Future<void> setPasscodeHash(String localId, String? value) async {
    final db = await _open();
    await db.update(
      _table,
      {
        'passcode_hash': value,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'local_id = ?',
      whereArgs: [localId],
    );
  }

  /// Every asset currently sharing this passcode hash — the "private
  /// album" *is* this live query, not a stored entity (see
  /// [AssetRecord.passcodeHash]). Empty when nothing's ever been added to
  /// it, or everything since has been taken back out.
  Future<List<AssetRecord>> forPasscodeHash(String hash) async {
    final db = await _open();
    final rows = await db.query(
      _table,
      where: 'passcode_hash = ?',
      whereArgs: [hash],
      orderBy: 'created_at ASC',
    );
    return rows.map(_fromRow).toList();
  }

  /// Every passcode hash any row carries, binned rows included: each is a
  /// hidden album that still holds something.
  Future<Set<String>> passcodeHashes() async {
    final db = await _open();
    final rows = await db.query(
      _table,
      columns: ['passcode_hash'],
      distinct: true,
      where: 'passcode_hash IS NOT NULL',
    );
    return {for (final r in rows) r['passcode_hash'] as String};
  }

  /// Moves every row tagged [from] to [to] — a passcode tag upgraded.
  Future<int> retag(String from, String to) async {
    final db = await _open();
    return db.update(
      _table,
      {
        'passcode_hash': to,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'passcode_hash = ?',
      whereArgs: [from],
    );
  }

  /// Every row behind a passcode.
  Future<List<AssetRecord>> hiddenRecords() async {
    final db = await _open();
    final rows = await db.query(_table, where: 'passcode_hash IS NOT NULL');
    return rows.map(_fromRow).toList();
  }

  /// Points [localId] at its file's new home. [heldName] is the name it had
  /// before hiding, kept for the way back; [clearHeld] forgets it.
  Future<void> moveSourcePath(
    String localId,
    String path, {
    String? heldName,
    bool clearHeld = false,
  }) async {
    final db = await _open();
    await db.update(
      _table,
      {
        'source_path': path,
        if (heldName != null || clearHeld) 'held_name': heldName,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'local_id = ?',
      whereArgs: [localId],
    );
  }

  Future<String?> heldNameOf(String localId) async {
    final db = await _open();
    final rows = await db.query(
      _table,
      columns: ['held_name'],
      where: 'local_id = ?',
      whereArgs: [localId],
    );
    return rows.isEmpty ? null : rows.first['held_name'] as String?;
  }

  /// Un-hidden rows whose file is still under [dir].
  Future<List<String>> plainIdsUnder(String dir) async {
    final db = await _open();
    final rows = await db.query(
      _table,
      columns: ['local_id'],
      // A range on the path index; `+` keeps the planner off the
      // passcode one, which `IS NULL` matches for nearly every row.
      where: '+passcode_hash IS NULL AND source_path >= ? AND source_path < ?',
      whereArgs: ['$dir/', '${dir}0'],
    );
    return [for (final r in rows) r['local_id'] as String];
  }

  /// Whether a row other than [localId] points at [path].
  Future<bool> sourcePathShared(String path, String localId) async {
    final db = await _open();
    final rows = await db.query(
      _table,
      columns: ['local_id'],
      where: 'source_path = ? AND local_id != ?',
      whereArgs: [path, localId],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  /// Every hidden-album note row, sealed as stored — for the export.
  Future<List<Map<String, Object?>>> allHiddenNoteRows() async {
    final db = await _open();
    return db.query(_hiddenNoteTable);
  }

  /// A note row from an export, unless one with its id is here already.
  Future<void> restoreHiddenNote(Map<String, Object?> row) async {
    final id = row['id'];
    final tag = row['album_tag'];
    final payload = row['payload'];
    if (id is! String || tag is! String || payload is! String) return;
    final db = await _open();
    await db.insert(_hiddenNoteTable, {
      'id': id,
      'album_tag': tag,
      'payload': payload,
      'created_at': row['created_at'] as int? ?? 0,
      'updated_at': row['updated_at'] as int? ?? 0,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  /// A compact copy of this database at [dest], with nothing behind a
  /// passcode in it: see `../backup/database_copy.dart`. [slim] (the daily
  /// copy): the log down to what the zip ships, and no bucket listing, a
  /// cache the flag scan lists again when it finds none. A zip restore
  /// starts the same way.
  Future<bool> copyTo(String dest, {bool slim = false}) async => copyDatabase(
    await _open(),
    _databaseFactory,
    dest,
    scrub: [
      "DELETE FROM $changeLogTable WHERE table_name = '$_table' AND ("
          "json_extract(before, '\$.passcode_hash') IS NOT NULL OR "
          "json_extract(after, '\$.passcode_hash') IS NOT NULL OR "
          'row_key IN (SELECT local_id FROM $_table '
          'WHERE passcode_hash IS NOT NULL))',
      'DELETE FROM $_derivativeTargetTable WHERE local_id IN '
          '(SELECT local_id FROM $_table WHERE passcode_hash IS NOT NULL)',
      'DELETE FROM $_changeCheckTable WHERE local_id IN '
          '(SELECT local_id FROM $_table WHERE passcode_hash IS NOT NULL)',
      'DELETE FROM $_table WHERE passcode_hash IS NOT NULL',
      'DELETE FROM $_transitionTable',
      // About this phone's Photos; a copy restored elsewhere names nothing.
      'DELETE FROM $_pendingSwapTable',
      // A cache of adopted ids; pending deletes stay, they are obligations.
      "DELETE FROM $_appStateTable WHERE key = 'hidden_motion_checked_v1'",
      if (slim) ...[
        changeLogTailScrub,
        for (final table in [
          _bucketObjectTable,
          _bucketScanTable,
          _bucketScanObjectTable,
          _bucketEditTable,
        ])
          'DELETE FROM $table',
      ],
    ],
  );

  /// Ids of rows behind a passcode — what other databases' copies drop.
  Future<Set<String>> hiddenIds() async {
    final db = await _open();
    final rows = await db.query(
      _table,
      columns: ['local_id'],
      where: 'passcode_hash IS NOT NULL',
    );
    return {for (final r in rows) r['local_id'] as String};
  }

  Future<void> setHidden(String localId, bool value) async {
    final db = await _open();
    await db.update(
      _table,
      {
        'is_hidden': value ? 1 : 0,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'local_id = ?',
      whereArgs: [localId],
    );
  }

  /// Moves a record to "Recently Deleted" — `remove` is the separate,
  /// permanent delete. [byLibrary]: the scan binned it, not the user.
  Future<void> softDelete(String localId, {bool byLibrary = false}) async {
    final db = await _open();
    await db.update(
      _table,
      {
        'deleted_at': DateTime.now().millisecondsSinceEpoch,
        'binned_by': byLibrary ? _binnedByLibrary : _binnedByUser,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'local_id = ?',
      whereArgs: [localId],
    );
  }

  static const _binnedByLibrary = 'library';
  static const _binnedByUser = 'user';

  Future<void> restore(String localId) async {
    final db = await _open();
    await db.update(
      _table,
      {
        'deleted_at': null,
        'binned_by': null,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'local_id = ?',
      whereArgs: [localId],
    );
  }

  /// Out of the bin because Photos lists the asset again: an entry the scan
  /// made, or one from before `binned_by` (04#1). The user's own stays.
  /// Never a hidden row.
  Future<bool> unbinListed(String localId) async {
    final db = await _open();
    final changed = await db.update(
      _table,
      {
        'deleted_at': null,
        'binned_by': null,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where:
          'local_id = ? AND deleted_at IS NOT NULL AND passcode_hash IS NULL '
          "AND (binned_by IS NULL OR binned_by = '$_binnedByLibrary')",
      whereArgs: [localId],
    );
    return changed > 0;
  }

  /// Every record, oldest first (ties by id).
  ///
  /// Incremental, because the library screen reloads on every camera-roll
  /// page, every change iOS reports and every background round, and a
  /// full read is not cheap: twenty thousand rows of thirty columns come
  /// back over the platform channel as twenty thousand maps, which is a
  /// third of a second of the UI isolate on a phone. Every write stamps a
  /// fresh `rev` (see [_addRevisions]), so after the first read only rows
  /// above the last one seen are fetched — whatever their dates, whatever
  /// the clock says. Only those are rebuilt; the order is patched, not
  /// re-sorted. Deletes leave through [remove]/[removeMany]; one made by
  /// another instance shows as a row count that doesn't add up.
  ///
  /// **Nothing changed means the same list instance back.** Callers lean
  /// on that: `identical` is how the library screen skips recomputing
  /// what it derives from this, and how the grid skips re-laying itself
  /// out. Treat the result as read-only. [libraryDelta] says what moved
  /// between two of them.
  ///
  /// No per-record path repair either — that is [_rehomePaths], once per
  /// container, for the same reason.
  Future<List<AssetRecord>> listAll() async {
    final db = await _open();
    var fresh = false;
    if (_order == null) {
      await (_reading ??= _readAll(db).whenComplete(() => _reading = null));
      // Dropped while it read (a wipe, a close): read again.
      if (_order == null) return listAll();
      fresh = true;
    }
    final rows = await db.query(
      _table,
      columns: _recordColumns,
      where: 'rev > ?',
      whereArgs: [_rev],
    );
    _rev = _maxRev(rows, _rev);
    var shape = fresh;
    var visibility = fresh;
    var outcome = fresh;
    final moved = <AssetRecord>[];
    final changes = <String, RecordChange>{
      for (final MapEntry(:key, :value) in _gone.entries)
        key: (before: value, after: null),
    };
    for (final row in rows) {
      final record = _fromRow(row);
      final held = _records[record.localId];
      if (held != null && _sameRecord(held, record)) continue;
      moved.add(record);
      changes[record.localId] = (
        before: changes[record.localId]?.before ?? held,
        after: record,
      );
      if (held == null || !_sameRecord(held, record, status: false)) {
        shape = true;
      }
      if (held != null && _visibilityMoved(held, record)) visibility = true;
      if (held != null && !_sameOutcome(held, record)) outcome = true;
    }
    _noteChanges(changes);
    if (fresh) _pending = null;
    if (_gone.isNotEmpty) {
      final gone = _gone.keys.toSet();
      _gone.clear();
      _order!.removeWhere((r) => gone.contains(r.localId));
      shape = visibility = true;
    }
    if (moved.isNotEmpty) _apply(moved);
    if (await _lostRows(db)) shape = visibility = true;
    if (!shape && !visibility && moved.isEmpty && _published != null) {
      return _published!;
    }
    return _publish(
      shape: shape,
      visibility: visibility,
      flags: shape || outcome,
    );
  }

  /// Changes applied to [_order] since the last publish, or null when it
  /// was rebuilt (a fresh read, rows lost under it). Kept on the store, not
  /// per call: a [listAll] that publishes while another is between its
  /// [_apply] and its publish hands out that one's changes too.
  Map<String, RecordChange>? _pending = {};

  void _noteChanges(Map<String, RecordChange> changes) {
    final pending = _pending;
    if (pending == null) return;
    for (final MapEntry(:key, :value) in changes.entries) {
      final prior = pending[key];
      pending[key] = prior == null
          ? value
          : (before: prior.before, after: value.after);
    }
  }

  /// What changed between two of [listAll]'s lists, one entry per record
  /// (`before` null: added; `after` null: removed), or null when this
  /// store can't say: lists from another store, [listNewest], a fresh
  /// read, or more than [_changeLogLimit] changes ago.
  List<RecordChange>? changesBetween(
    List<AssetRecord> before,
    List<AssetRecord> after,
  ) {
    if (identical(before, after)) return const [];
    final a = _generations[before];
    final b = _generations[after];
    if (a == null || b == null || a.store != _id || b.store != _id) {
      return null;
    }
    if (a.publish >= b.publish || _changeLog.isEmpty) return null;
    if (_changeLog.first.publish > a.publish + 1) return null;
    if (_changeLog.last.publish < b.publish) return null;
    final merged = <String, RecordChange>{};
    for (final entry in _changeLog) {
      if (entry.publish <= a.publish || entry.publish > b.publish) continue;
      for (final MapEntry(:key, :value) in entry.changes.entries) {
        final prior = merged[key];
        merged[key] = prior == null
            ? value
            : (before: prior.before, after: value.after);
      }
    }
    return [
      for (final c in merged.values)
        if (c.before != null || c.after != null) c,
    ];
  }

  /// Visible records by id, read live from the cache [listAll] keeps (so
  /// at least as new as its last list). For lookups: no copy per list.
  late final Map<String, AssetRecord> visibleById = _VisibleById(this);

  /// Each publish's changes, oldest first, contiguous: a publish with no
  /// diff empties it.
  final _changeLog = <({int publish, Map<String, RecordChange> changes})>[];
  int _loggedChanges = 0;
  int _publishGen = 0;
  static const _changeLogLimit = 4096;

  /// The records for [localIds] in grid order, from [listAll]'s cache: no
  /// row read. Ids with no record are left out.
  Future<List<AssetRecord>> listOf(Iterable<String> localIds) async {
    final all = await listAll();
    final ids = localIds.toSet();
    // Most of the library: one ordered pass beats a sort.
    if (ids.length * 8 > all.length) {
      return [
        for (final r in all)
          if (ids.contains(r.localId)) r,
      ];
    }
    final records = _records;
    return [for (final id in ids) ?records[id]]..sort(_byDate);
  }

  /// The newest [limit] records, oldest first — what the grid draws while
  /// the first [listAll] is still reading. Not the library: no
  /// [libraryDelta] generation, so nothing takes it for one.
  Future<List<AssetRecord>> listNewest(int limit) async {
    final order = _order;
    if (order != null) {
      return List.unmodifiable(order.sublist(max(0, order.length - limit)));
    }
    final db = await _open();
    final rows = await db.query(
      _table,
      columns: _recordColumns,
      orderBy: 'created_at DESC, local_id DESC',
      limit: limit,
    );
    final newest = [for (final row in rows.reversed) _fromRow(row)]
      ..sort(_byDate);
    return List.unmodifiable(newest);
  }

  /// The first full read, in pages on `(created_at, local_id)`, so no one
  /// platform message holds the UI isolate for the whole library. Rows
  /// written meanwhile are above the counter read first, and the [listAll]
  /// pass after this one picks them up; one deleted meanwhile shows as a
  /// count that doesn't add up ([_lostRows]).
  Future<void> _readAll(Database db) async {
    final epoch = _epoch;
    final start =
        sqflite.Sqflite.firstIntValue(
          await db.rawQuery('SELECT n FROM $_revTable WHERE id = 0'),
        ) ??
        0;
    final records = <String, AssetRecord>{};
    var order = <AssetRecord>[];
    var repeated = false;
    List<Object?>? after;
    while (true) {
      final rows = await db.query(
        _table,
        columns: _recordColumns,
        where: after == null
            ? null
            : 'created_at > ? OR (created_at = ? AND local_id > ?)',
        whereArgs: after,
        orderBy: 'created_at, local_id',
        limit: _readPage,
      );
      for (final row in rows) {
        final record = _fromRow(row);
        // Re-dated between two pages: met again further on.
        if (records[record.localId] != null) repeated = true;
        records[record.localId] = record;
        order.add(record);
      }
      if (rows.length < _readPage) break;
      final last = rows.last;
      after = [last['created_at'], last['created_at'], last['local_id']];
    }
    if (epoch != _epoch) return;
    // SQLite orders text by bytes, Dart by UTF-16 units; the same for any
    // id this app writes, but [_indexOf] must agree with the list.
    if (repeated || !_inOrder(order)) {
      order = records.values.toList()..sort(_byDate);
    }
    _records = records;
    _order = order;
    _rev = start;
  }

  static const _readPage = 2000;

  Future<void>? _reading;

  /// Bumped by [_dropCache], so a read already under way can't put back
  /// what was dropped.
  int _epoch = 0;

  static bool _inOrder(List<AssetRecord> order) {
    for (var i = 1; i < order.length; i++) {
      if (_byDate(order[i - 1], order[i]) > 0) return false;
    }
    return true;
  }

  /// Every column [_fromRow] reads, and `rev`.
  static const _recordColumns = [
    'local_id',
    'content_hash',
    'platform',
    'source_type',
    'source_path',
    'thumbnail_path',
    'local_deleted',
    'is_video',
    'is_live_photo',
    'is_gif',
    'has_edit',
    ..._uploadColumns,
    'is_favorite',
    'is_hidden',
    'is_locked',
    'is_archived',
    'people_only',
    'local_optimized',
    'deleted_at',
    'binned_by',
    'description',
    'tags',
    'location',
    'passcode_hash',
    'library_id',
    'latitude',
    'longitude',
    'width',
    'height',
    'created_at',
    'updated_at',
    'added_at',
    'rev',
  ];

  /// The records built from the rows as last read, by `local_id`. An
  /// unchanged row keeps its record (what the grid's day keys are
  /// memoised on); no raw row is kept beside it.
  Map<String, AssetRecord> _records = {};

  /// [_records] in [_byDate] order.
  List<AssetRecord>? _order;
  List<AssetRecord>? _published;
  int _rev = 0;

  /// Removed since the last [listAll], with the record as last listed;
  /// taken out of [_order] in one pass.
  final _gone = <String, AssetRecord>{};

  int _shapeGen = 0;
  int _visibilityGen = 0;
  int _flagsGen = 0;

  static int _byDate(AssetRecord a, AssetRecord b) {
    final byDate = a.createdAt.millisecondsSinceEpoch.compareTo(
      b.createdAt.millisecondsSinceEpoch,
    );
    return byDate != 0 ? byDate : a.localId.compareTo(b.localId);
  }

  List<AssetRecord> _publish({
    required bool shape,
    required bool visibility,
    required bool flags,
  }) {
    if (shape) _shapeGen++;
    if (visibility) _visibilityGen++;
    if (flags) _flagsGen++;
    _publishGen++;
    final changes = _pending;
    _pending = {};
    if (changes == null) {
      _changeLog.clear();
      _loggedChanges = 0;
    } else {
      _changeLog.add((publish: _publishGen, changes: changes));
      _loggedChanges += changes.length;
      while (_loggedChanges > _changeLogLimit && _changeLog.length > 1) {
        _loggedChanges -= _changeLog.removeAt(0).changes.length;
      }
    }
    final published = List<AssetRecord>.unmodifiable(_order!);
    _generations[published] = (
      store: _id,
      shape: _shapeGen,
      visibility: _visibilityGen,
      flags: _flagsGen,
      publish: _publishGen,
    );
    return _published = published;
  }

  /// Patches [_order] for [moved]: in place when the date held, else out
  /// and back in at its new place. A big batch (a first scan's pages) is
  /// cheaper as one merge of the sorted batch into the rest.
  void _apply(List<AssetRecord> moved) {
    final order = _order!;
    if (moved.length > 256) {
      final ids = <String>{};
      for (final record in moved) {
        _records[record.localId] = record;
        ids.add(record.localId);
      }
      _order = _merged([
        for (final r in order)
          if (!ids.contains(r.localId)) r,
      ], [...moved]..sort(_byDate));
      return;
    }
    for (final record in moved) {
      final old = _records[record.localId];
      _records[record.localId] = record;
      if (old != null) {
        final at = _indexOf(order, old);
        if (at != -1 && old.createdAt == record.createdAt) {
          order[at] = record;
          continue;
        }
        if (at != -1) order.removeAt(at);
      }
      order.insert(_insertionPoint(order, record), record);
    }
  }

  static List<AssetRecord> _merged(List<AssetRecord> a, List<AssetRecord> b) {
    final out = <AssetRecord>[];
    var i = 0;
    var j = 0;
    while (i < a.length && j < b.length) {
      out.add(_byDate(a[i], b[j]) <= 0 ? a[i++] : b[j++]);
    }
    out
      ..addAll(a.skip(i))
      ..addAll(b.skip(j));
    return out;
  }

  static int _insertionPoint(List<AssetRecord> order, AssetRecord record) {
    var lo = 0;
    var hi = order.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_byDate(order[mid], record) < 0) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  static int _indexOf(List<AssetRecord> order, AssetRecord record) {
    final at = _insertionPoint(order, record);
    if (at < order.length && identical(order[at], record)) return at;
    return order.indexOf(record);
  }

  /// Rows deleted under this cache by someone else: dropped. One count,
  /// and a read of ids only when it is off.
  Future<bool> _lostRows(Database db) async {
    final count = sqflite.Sqflite.firstIntValue(
      await db.rawQuery('SELECT COUNT(*) FROM $_table'),
    );
    if (count == null || count == _records.length) return false;
    final ids = {
      for (final row in await db.query(_table, columns: ['local_id']))
        row['local_id'] as String,
    };
    final lost = _records.keys.where((id) => !ids.contains(id)).toSet();
    if (lost.isEmpty) return false;
    for (final id in lost) {
      _records.remove(id);
    }
    _order!.removeWhere((r) => lost.contains(r.localId));
    _pending = null;
    return true;
  }

  static int _maxRev(List<Map<String, Object?>> rows, int start) {
    var high = start;
    for (final row in rows) {
      final at = row['rev'] as int? ?? 0;
      if (at > high) high = at;
    }
    return high;
  }

  /// Field by field, as the row's columns were compared before: a field
  /// added to [AssetRecord] belongs here too. Without [status], upload
  /// state and `updatedAt` don't count — only they moved, tiles redraw and
  /// nothing else does.
  static bool _sameRecord(AssetRecord a, AssetRecord b, {bool status = true}) {
    if (status) {
      if (a.updatedAt != b.updatedAt) return false;
      for (final kind in DerivativeKind.values) {
        final x = a.stateOf(kind);
        final y = b.stateOf(kind);
        if (x.status != y.status ||
            x.destinationKey != y.destinationKey ||
            x.backedUpHash != y.backedUpHash ||
            x.fromResource != y.fromResource) {
          return false;
        }
      }
    }
    return a.localId == b.localId &&
        a.contentHash == b.contentHash &&
        a.platform == b.platform &&
        a.sourceType == b.sourceType &&
        a.sourcePath == b.sourcePath &&
        a.thumbnailPath == b.thumbnailPath &&
        a.localDeleted == b.localDeleted &&
        a.isVideo == b.isVideo &&
        a.isLivePhoto == b.isLivePhoto &&
        a.hasEdit == b.hasEdit &&
        a.isGif == b.isGif &&
        a.createdAt == b.createdAt &&
        a.addedAt == b.addedAt &&
        a.isFavorite == b.isFavorite &&
        a.isLocked == b.isLocked &&
        a.isArchived == b.isArchived &&
        a.peopleOnly == b.peopleOnly &&
        a.localOptimized == b.localOptimized &&
        a.isHidden == b.isHidden &&
        a.deletedAt == b.deletedAt &&
        a.binnedByLibrary == b.binnedByLibrary &&
        a.description == b.description &&
        _sameTags(a.tags, b.tags) &&
        a.location == b.location &&
        a.passcodeHash == b.passcodeHash &&
        a.libraryId == b.libraryId &&
        a.latitude == b.latitude &&
        a.longitude == b.longitude &&
        a.width == b.width &&
        a.height == b.height;
  }

  static bool _sameTags(List<String> a, List<String> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Upload state as a detector reads it: a status other than between
  /// pending and uploading (both "on its way"), or a key, hash or source.
  /// `updatedAt` never.
  static bool _sameOutcome(AssetRecord a, AssetRecord b) {
    bool onItsWay(UploadStatus s) =>
        s == UploadStatus.pending || s == UploadStatus.uploading;
    for (final kind in DerivativeKind.values) {
      final x = a.stateOf(kind);
      final y = b.stateOf(kind);
      if ((x.status != y.status &&
              !(onItsWay(x.status) && onItsWay(y.status))) ||
          x.destinationKey != y.destinationKey ||
          x.backedUpHash != y.backedUpHash ||
          x.fromResource != y.fromResource) {
        return false;
      }
    }
    return true;
  }

  static bool _visibilityMoved(AssetRecord a, AssetRecord b) =>
      a.passcodeHash != b.passcodeHash ||
      a.isHidden != b.isHidden ||
      a.deletedAt != b.deletedAt ||
      a.localDeleted != b.localDeleted;

  /// Whatever the cache holds is now a guess — the next [listAll] reads
  /// the library again from scratch.
  void _dropCache() {
    _epoch++;
    _records = {};
    _order = null;
    _published = null;
    _gone.clear();
    _pending = null;
    _rev = 0;
  }

  void _forgetCached(Iterable<String> localIds) {
    if (_order == null) return;
    for (final id in localIds) {
      final held = _records.remove(id);
      if (held == null) continue;
      _gone[id] ??= held;
      _published = null;
    }
  }

  /// Permanently deletes — used for real deletion from "Recently Deleted",
  /// or (today) the Library's own delete action until that also routes
  /// through the trash.
  Future<void> remove(String localId) => removeMany([localId]);

  /// [remove] for many in one transaction; the cache patched once.
  Future<void> removeMany(Iterable<String> localIds) async {
    final ids = localIds.toSet();
    if (ids.isEmpty) return;
    final db = await _open();
    final batch = db.batch();
    for (final localId in ids) {
      batch
        ..delete(_table, where: 'local_id = ?', whereArgs: [localId])
        ..delete(
          _derivativeTargetTable,
          where: 'local_id = ?',
          whereArgs: [localId],
        )
        ..delete(_changeCheckTable, where: 'local_id = ?', whereArgs: [localId])
        // Albums and people live in other databases; see [removedIds].
        ..insert(_appStateTable, {
          'key': '$_removedKeyPrefix$localId',
          'value': '1',
        }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
    // A delete leaves no row to notice.
    _forgetCached(ids);
  }

  static const _removedKeyPrefix = 'removed:';

  /// Records [remove]d since the last [forgetRemoved] — for dropping their
  /// album and people memberships, which this database can't reach.
  Future<Set<String>> removedIds() async {
    final db = await _open();
    final rows = await db.query(
      _appStateTable,
      columns: ['key'],
      where: 'substr(key, 1, ?) = ?',
      whereArgs: [_removedKeyPrefix.length, _removedKeyPrefix],
    );
    return {
      for (final row in rows)
        (row['key'] as String).substring(_removedKeyPrefix.length),
    };
  }

  /// Of [removedIds], those merged into another record by [adoptAsset]:
  /// their albums and people move there rather than go.
  Future<Map<String, String>> mergedInto() async {
    final db = await _open();
    final rows = await db.query(
      _appStateTable,
      where: "substr(key, 1, ?) = ? AND value <> '1'",
      whereArgs: [_removedKeyPrefix.length, _removedKeyPrefix],
    );
    return {
      for (final row in rows)
        (row['key'] as String).substring(_removedKeyPrefix.length):
            row['value'] as String,
    };
  }

  Future<void> forgetRemoved(Iterable<String> localIds) async {
    final db = await _open();
    final batch = db.batch();
    for (final id in localIds) {
      batch.delete(
        _appStateTable,
        where: 'key = ?',
        whereArgs: ['$_removedKeyPrefix$id'],
      );
    }
    await batch.commit(noResult: true);
  }

  static String _columnPrefix(DerivativeKind kind) => switch (kind) {
    DerivativeKind.thumbnail => 'thumbnail',
    DerivativeKind.medium => 'medium',
    DerivativeKind.original => 'original',
    DerivativeKind.livePhoto => 'live',
    DerivativeKind.edited => 'edited',
  };

  /// `Enum.values.byName` walks the values and builds a map of them on
  /// every call, and this runs five times per row — twenty thousand rows
  /// in, that alone is a visible part of reading the library.
  static const _uploadStatuses = {
    'pending': UploadStatus.pending,
    'uploading': UploadStatus.uploading,
    'uploaded': UploadStatus.uploaded,
    'failed': UploadStatus.failed,
  };

  static const _sourceTypes = {
    'photoManager': AssetSourceType.photoManager,
    'manualFile': AssetSourceType.manualFile,
  };

  static AssetRecord _fromRow(Map<String, Object?> row) {
    DerivativeState stateFor(DerivativeKind kind) {
      final column = _columnPrefix(kind);
      return DerivativeState(
        status:
            _uploadStatuses[row['${column}_status'] as String] ??
            UploadStatus.pending,
        destinationKey: row['${column}_key'] as String?,
        backedUpHash: row['${column}_hash'] as String?,
        fromResource:
            kind == DerivativeKind.original &&
            row['original_source'] == _resourceSource,
      );
    }

    final deletedAtMillis = row['deleted_at'] as int?;
    // Almost every photo has no tags, and parsing "[]" twenty thousand
    // times to learn that is work for nothing.
    final tagsText = row['tags'] as String? ?? '[]';
    final tags = tagsText == '[]'
        ? const <String>[]
        : (jsonDecode(tagsText) as List<dynamic>).cast<String>();

    return AssetRecord(
      localId: row['local_id'] as String,
      contentHash: row['content_hash'] as String,
      platform: row['platform'] as String,
      sourceType:
          _sourceTypes[row['source_type'] as String] ??
          AssetSourceType.photoManager,
      sourcePath: rebaseContainerPath(row['source_path'] as String?),
      thumbnailPath: rebaseContainerPath(row['thumbnail_path'] as String?),
      localDeleted: (row['local_deleted'] as int? ?? 0) != 0,
      isVideo: (row['is_video'] as int? ?? 0) != 0,
      isLivePhoto: (row['is_live_photo'] as int? ?? 0) != 0,
      hasEdit: (row['has_edit'] as int? ?? 0) != 0,
      isGif: (row['is_gif'] as int? ?? 0) != 0,
      createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(row['updated_at'] as int),
      addedAt: switch (row['added_at']) {
        final int at => DateTime.fromMillisecondsSinceEpoch(at),
        _ => null,
      },
      derivatives: {
        for (final kind in DerivativeKind.values) kind: stateFor(kind),
      },
      isFavorite: (row['is_favorite'] as int? ?? 0) != 0,
      isLocked: (row['is_locked'] as int? ?? 0) != 0,
      isArchived: (row['is_archived'] as int? ?? 0) != 0,
      peopleOnly: (row['people_only'] as int? ?? 0) != 0,
      localOptimized: (row['local_optimized'] as int? ?? 0) != 0,
      isHidden: (row['is_hidden'] as int? ?? 0) != 0,
      deletedAt: deletedAtMillis == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(deletedAtMillis),
      binnedByLibrary: row['binned_by'] == _binnedByLibrary,
      description: row['description'] as String? ?? '',
      tags: tags,
      location: row['location'] as String?,
      passcodeHash: row['passcode_hash'] as String?,
      libraryId: row['library_id'] as String?,
      latitude: row['latitude'] as double?,
      longitude: row['longitude'] as double?,
      width: row['width'] as int?,
      height: row['height'] as int?,
    );
  }
}

/// Reads filtered by [AssetRecord.isVisibleInLibrary], for screens outside
/// the private gate.
extension VisibleRecords on AssetRecordStore {
  /// [getByLocalIds], keeping only what may be shown.
  Future<Map<String, AssetRecord>> getVisibleByLocalIds(
    Iterable<String> localIds,
  ) async => {
    for (final entry in (await getByLocalIds(localIds)).entries)
      if (entry.value.isVisibleInLibrary) entry.key: entry.value,
  };

  /// Ids of every visible record. One pass per change of the library:
  /// memoised on the [listAll] instance, which is the same while nothing
  /// moved.
  Future<Set<String>> visibleLocalIds() async => visibleIdsOf(await listAll());
}

/// What moved between two [AssetRecordStore.listAll] results: [shape] is
/// anything but upload state (rows in or out, dates, flags, places);
/// [visibility] is a row hidden, binned or removed; [flags] is [shape] or
/// an upload outcome (anything but pending to uploading and back), what
/// Flagged Items is worked out from. All for lists this can't vouch for.
({bool shape, bool visibility, bool flags}) libraryDelta(
  List<AssetRecord>? before,
  List<AssetRecord> after,
) {
  if (identical(before, after)) {
    return (shape: false, visibility: false, flags: false);
  }
  final a = before == null ? null : _generations[before];
  final b = _generations[after];
  if (a == null || b == null || a.store != b.store) {
    return (shape: true, visibility: true, flags: true);
  }
  return (
    shape: a.shape != b.shape,
    visibility: a.visibility != b.visibility,
    flags: a.flags != b.flags,
  );
}

final _generations =
    Expando<({int store, int shape, int visibility, int flags, int publish})>();

/// One record between two [AssetRecordStore.listAll] lists: [before] null
/// is an add, [after] null a removal.
typedef RecordChange = ({AssetRecord? before, AssetRecord? after});

/// [AssetRecordStore.listAll]'s order: capture time, then id.
int recordOrder(AssetRecord a, AssetRecord b) => AssetRecordStore._byDate(a, b);

/// Where [record] goes in [sorted] (in [recordOrder]): the first index
/// not before it.
int insertionPointOf(List<AssetRecord> sorted, AssetRecord record) =>
    AssetRecordStore._insertionPoint(sorted, record);

/// The index of the entry for [record]'s id in [sorted], found by its date,
/// or -1.
int indexInOrder(List<AssetRecord> sorted, AssetRecord record) {
  final at = AssetRecordStore._insertionPoint(sorted, record);
  return at < sorted.length && sorted[at].localId == record.localId ? at : -1;
}

final _visibleIds = Expando<Set<String>>();

/// Ids in [records] that may be shown, memoised per list instance.
Set<String> visibleIdsOf(List<AssetRecord> records) =>
    _visibleIds[records] ??= {
      for (final r in records)
        if (r.isVisibleInLibrary) r.localId,
    };

final _visibleRecords = Expando<Map<String, AssetRecord>>();

/// [visibleIdsOf], by id to the record — what avatars resolve from
/// instead of a query each.
Map<String, AssetRecord> visibleRecordsOf(List<AssetRecord> records) =>
    _visibleRecords[records] ??= {
      for (final r in records)
        if (r.isVisibleInLibrary) r.localId: r,
    };

class _VisibleById extends MapBase<String, AssetRecord> {
  _VisibleById(this._store);

  final AssetRecordStore _store;

  @override
  AssetRecord? operator [](Object? key) {
    final record = _store._records[key];
    return record != null && record.isVisibleInLibrary ? record : null;
  }

  @override
  Iterable<String> get keys => [
    for (final r in _store._records.values)
      if (r.isVisibleInLibrary) r.localId,
  ];

  @override
  void operator []=(String key, AssetRecord value) =>
      throw UnsupportedError('read-only');

  @override
  AssetRecord? remove(Object? key) => throw UnsupportedError('read-only');

  @override
  void clear() => throw UnsupportedError('read-only');
}
