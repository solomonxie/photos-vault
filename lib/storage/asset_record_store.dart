import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite/sqflite.dart'
    show ConflictAlgorithm, Database, DatabaseFactory, OpenDatabaseOptions;

import '../backup/change_log.dart';
import 'asset_record.dart';

/// Local `sqflite` store for per-asset backup state — the single source of
/// truth for what's been uploaded, so a restart or a killed background task
/// resumes without re-scanning derivatives from scratch.
class AssetRecordStore {
  AssetRecordStore({
    DatabaseFactory? databaseFactory,
    this._path,
    Future<Directory> Function()? appSupportDirectory,
  }) : _databaseFactory = databaseFactory ?? sqflite.databaseFactory,
       _appSupportDirectory =
           appSupportDirectory ?? getApplicationSupportDirectory;

  final DatabaseFactory _databaseFactory;
  final String? _path;

  /// Where `ManualAddService`/`DemoAssetsService` copy owned files into —
  /// used to re-resolve a `manualFile` record's `sourcePath` by filename
  /// when its stored absolute path goes stale (the app container's UUID
  /// isn't stable across reinstalls, even though the files inside it move
  /// together).
  final Future<Directory> Function() _appSupportDirectory;

  Database? _db;
  Directory? _appSupport;

  static const _table = 'asset_record';

  Future<Database> _open() async {
    final existing = _db;
    if (existing != null) return existing;
    final path =
        _path ??
        p.join(await _databaseFactory.getDatabasesPath(), 'photos_vault.db');
    final db = await _databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 14,
        onCreate: (db, version) async {
          await db.execute(_createTableSql);
          await db.execute(_createPlaceNameTableSql);
          await db.execute(_createAppStateTableSql);
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
          if (oldVersion < 7) {
            await db.execute('ALTER TABLE $_table ADD COLUMN event TEXT');
          }
          if (oldVersion < 8) {
            await db.execute(
              'ALTER TABLE $_table ADD COLUMN is_live_photo INTEGER NOT NULL DEFAULT 0',
            );
          }
          if (oldVersion < 12) {
            await db.execute(_createAppStateTableSql);
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
          if (oldVersion < 10) {
            await db.execute('ALTER TABLE $_table ADD COLUMN latitude REAL');
            await db.execute('ALTER TABLE $_table ADD COLUMN longitude REAL');
            await db.execute('ALTER TABLE $_table ADD COLUMN width INTEGER');
            await db.execute('ALTER TABLE $_table ADD COLUMN height INTEGER');
            await db.execute(_createPlaceNameTableSql);
          }
        },
      ),
    );
    // After the migrations, never inside them: a trigger has to describe
    // the schema the app just finished upgrading to.
    await installChangeLog(db, const [_table]);
    _db = db;
    return db;
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
      is_favorite INTEGER NOT NULL DEFAULT 0,
      is_hidden INTEGER NOT NULL DEFAULT 0,
      deleted_at INTEGER,
      description TEXT NOT NULL DEFAULT '',
      tags TEXT NOT NULL DEFAULT '[]',
      location TEXT,
      event TEXT,
      passcode_hash TEXT,
      library_id TEXT,
      latitude REAL,
      longitude REAL,
      width INTEGER,
      height INTEGER,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL
    )
  ''';

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
  }

  /// This store's database file, with the write-ahead log folded back in
  /// first — a copy taken without the checkpoint is missing the newest
  /// writes, which are still sitting in the `-wal` sidecar.
  ///
  /// `null` for an in-memory database, which has no file to copy.
  Future<File?> checkpointedFile() async {
    final db = await _open();
    try {
      await db.execute('PRAGMA wal_checkpoint(FULL)');
    } catch (_) {
      // Not in WAL mode, or a factory that doesn't support the pragma.
    }
    final file = File(db.path);
    return file.existsSync() ? file : null;
  }

  /// How far this database's change log has got. See `change_log.dart`.
  Future<int> changeMark() async => changeLogMark(await _open());

  /// The tail of this database's change log, for the copy in the backup.
  Future<List<Map<String, Object?>>> changeLogRows() async =>
      changeLogTail(await _open());

  /// Inserts a new record if `localId` isn't tracked yet. If one already
  /// exists, refreshes `sourcePath` when it's changed (e.g. demo/manual
  /// files re-copied to a new app container path after a reinstall) —
  /// otherwise a stale path could never heal.
  /// [createdAt] backdates a freshly-inserted record (used by
  /// `DemoAssetsService` to spread demo assets across days/years so the
  /// day-grouped grid isn't just one giant "Today" section); ignored for an
  /// already-tracked `localId`, and defaults to now.
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
    double? latitude,
    double? longitude,
    int? width,
    int? height,
    String? libraryId,
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

    final now = createdAt ?? DateTime.now();
    await db.insert(_table, {
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
      'created_at': now.millisecondsSinceEpoch,
      'updated_at': now.millisecondsSinceEpoch,
    });
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
      createdAt: now,
      updatedAt: now,
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
    if (path == null || File(path).existsSync()) return record;
    // Looked up once and kept: healing runs per row, and asking the
    // platform for the same directory a thousand times during one library
    // read is a thousand channel round-trips for one answer. Failure means
    // no platform to ask (a pure-Dart test) — the record is handed back as
    // it is rather than taking the whole read down with it.
    Directory dir;
    try {
      dir = _appSupport ??= await _appSupportDirectory();
    } catch (_) {
      return record;
    }
    final healedPath = p.join(dir.path, p.basename(path));
    if (healedPath == path || !File(healedPath).existsSync()) return record;

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
  Future<AssetRecord?> getByLibraryId(String libraryId) async {
    final db = await _open();
    final rows = await db.query(
      _table,
      // The second clause is for rows written before `library_id` existed,
      // which carry the library's id inside their own and may not have
      // been re-scanned since the migration that lifts it out.
      where: 'library_id = ? OR (library_id IS NULL AND local_id = ?)',
      whereArgs: [libraryId, 'photo:$libraryId'],
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

  /// Photos carrying a GPS tag that nobody — neither the user nor the
  /// geocoder — has put a name to yet. Oldest-scanned first so a run picks
  /// up where the last one stopped.
  Future<List<AssetRecord>> listAwaitingPlaceName({int limit = 200}) async {
    final db = await _open();
    final rows = await db.query(
      _table,
      where:
          "latitude IS NOT NULL AND longitude IS NOT NULL "
          "AND (location IS NULL OR location = '') AND deleted_at IS NULL",
      orderBy: 'created_at DESC',
      limit: limit,
    );
    return rows.map(_fromRow).toList();
  }

  /// The name already worked out for a patch of the world, or `null` if
  /// that patch has never been looked up. The record it returns can itself
  /// hold a null [PlaceNameEntry.name] — a remembered "nothing there".
  Future<PlaceNameEntry?> cachedPlaceName(String cell) async {
    final db = await _open();
    final rows = await db.query(
      _placeNameTable,
      where: 'cell = ?',
      whereArgs: [cell],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return PlaceNameEntry(rows.single['name'] as String?);
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
    final rows = await db.query(
      _table,
      columns: ['location'],
      distinct: true,
      where: "location IS NOT NULL AND location != ''",
    );
    return rows.map((r) => r['location'] as String).toSet();
  }

  Future<void> setEvent(String localId, String? value) async {
    final db = await _open();
    await db.update(
      _table,
      {'event': value, 'updated_at': DateTime.now().millisecondsSinceEpoch},
      where: 'local_id = ?',
      whereArgs: [localId],
    );
  }

  /// Same role as [allLocations], for the Event field and the Events
  /// collection.
  Future<Set<String>> allEvents() async {
    final db = await _open();
    final rows = await db.query(
      _table,
      columns: ['event'],
      distinct: true,
      where: "event IS NOT NULL AND event != ''",
    );
    return rows.map((r) => r['event'] as String).toSet();
  }

  /// Every distinct tag already used across all photos — same "select if
  /// exists" role as [allLocations], for the Tags field.
  Future<Set<String>> allTags() async {
    final db = await _open();
    final rows = await db.query(_table, columns: ['tags']);
    final result = <String>{};
    for (final row in rows) {
      final tags = jsonDecode(row['tags'] as String? ?? '[]') as List<dynamic>;
      result.addAll(tags.cast<String>());
    }
    return result;
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
    return Future.wait(rows.map(_fromRow).map(_healed));
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
  /// permanent delete.
  Future<void> softDelete(String localId) async {
    final db = await _open();
    await db.update(
      _table,
      {
        'deleted_at': DateTime.now().millisecondsSinceEpoch,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'local_id = ?',
      whereArgs: [localId],
    );
  }

  Future<void> restore(String localId) async {
    final db = await _open();
    await db.update(
      _table,
      {'deleted_at': null, 'updated_at': DateTime.now().millisecondsSinceEpoch},
      where: 'local_id = ?',
      whereArgs: [localId],
    );
  }

  Future<List<AssetRecord>> listAll() async {
    final db = await _open();
    final rows = await db.query(_table, orderBy: 'created_at ASC');
    return Future.wait(rows.map(_fromRow).map(_healed));
  }

  /// Permanently deletes — used for real deletion from "Recently Deleted",
  /// or (today) the Library's own delete action until that also routes
  /// through the trash.
  Future<void> remove(String localId) async {
    final db = await _open();
    await db.delete(_table, where: 'local_id = ?', whereArgs: [localId]);
  }

  static String _columnPrefix(DerivativeKind kind) => switch (kind) {
    DerivativeKind.thumbnail => 'thumbnail',
    DerivativeKind.medium => 'medium',
    DerivativeKind.original => 'original',
    DerivativeKind.livePhoto => 'live',
  };

  static AssetRecord _fromRow(Map<String, Object?> row) {
    DerivativeState stateFor(DerivativeKind kind) {
      final column = _columnPrefix(kind);
      final status = UploadStatus.values.byName(
        row['${column}_status'] as String,
      );
      return DerivativeState(
        status: status,
        destinationKey: row['${column}_key'] as String?,
        backedUpHash: row['${column}_hash'] as String?,
      );
    }

    final deletedAtMillis = row['deleted_at'] as int?;
    final tagsJson =
        jsonDecode(row['tags'] as String? ?? '[]') as List<dynamic>;

    return AssetRecord(
      localId: row['local_id'] as String,
      contentHash: row['content_hash'] as String,
      platform: row['platform'] as String,
      sourceType: AssetSourceType.values.byName(row['source_type'] as String),
      sourcePath: row['source_path'] as String?,
      thumbnailPath: row['thumbnail_path'] as String?,
      localDeleted: (row['local_deleted'] as int? ?? 0) != 0,
      isVideo: (row['is_video'] as int? ?? 0) != 0,
      isLivePhoto: (row['is_live_photo'] as int? ?? 0) != 0,
      isGif: (row['is_gif'] as int? ?? 0) != 0,
      createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(row['updated_at'] as int),
      derivatives: {
        for (final kind in DerivativeKind.values) kind: stateFor(kind),
      },
      isFavorite: (row['is_favorite'] as int? ?? 0) != 0,
      isHidden: (row['is_hidden'] as int? ?? 0) != 0,
      deletedAt: deletedAtMillis == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(deletedAtMillis),
      description: row['description'] as String? ?? '',
      tags: tagsJson.cast<String>(),
      location: row['location'] as String?,
      event: row['event'] as String?,
      passcodeHash: row['passcode_hash'] as String?,
      libraryId: row['library_id'] as String?,
      latitude: row['latitude'] as double?,
      longitude: row['longitude'] as double?,
      width: row['width'] as int?,
      height: row['height'] as int?,
    );
  }
}
