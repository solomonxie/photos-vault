import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite/sqflite.dart'
    show Database, DatabaseFactory, OpenDatabaseOptions;

import 'album.dart';

/// Local `sqflite` store for albums and their asset membership. Kept in its
/// own db file (separate from `asset_record_store.dart`) — the two are
/// joined only in application code, by `AssetRecord.localId`.
class AlbumStore {
  AlbumStore({DatabaseFactory? databaseFactory, this._path})
    : _databaseFactory = databaseFactory ?? sqflite.databaseFactory;

  final DatabaseFactory _databaseFactory;
  final String? _path;

  Database? _db;

  static const _albumTable = 'album';
  static const _memberTable = 'album_asset';

  Future<Database> _open() async {
    final existing = _db;
    if (existing != null) return existing;
    final path =
        _path ??
        p.join(await _databaseFactory.getDatabasesPath(), 'photo_albums.db');
    final db = await _databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE $_albumTable (
              id TEXT PRIMARY KEY,
              name TEXT NOT NULL,
              is_demo INTEGER NOT NULL DEFAULT 0,
              created_at INTEGER NOT NULL
            )
          ''');
          await db.execute('''
            CREATE TABLE $_memberTable (
              album_id TEXT NOT NULL,
              local_id TEXT NOT NULL,
              added_at INTEGER NOT NULL,
              PRIMARY KEY (album_id, local_id)
            )
          ''');
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

  /// Inserts an album under [id] if it isn't tracked yet; no-op otherwise —
  /// so re-seeding a demo album after it's deleted, or re-adding one already
  /// present, never duplicates it.
  Future<Album> upsert({
    required String id,
    required String name,
    bool isDemo = false,
  }) async {
    final db = await _open();
    final existing = await getById(id);
    if (existing != null) return existing;

    final now = DateTime.now();
    await db.insert(_albumTable, {
      'id': id,
      'name': name,
      'is_demo': isDemo ? 1 : 0,
      'created_at': now.millisecondsSinceEpoch,
    });
    return Album(id: id, name: name, createdAt: now, isDemo: isDemo);
  }

  Future<Album?> getById(String id) async {
    final db = await _open();
    final rows = await db.query(
      _albumTable,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _fromRow(rows.single);
  }

  Future<List<Album>> listAll() async {
    final db = await _open();
    final rows = await db.query(_albumTable, orderBy: 'created_at ASC');
    return rows.map(_fromRow).toList();
  }

  /// Adds [localIds] to [albumId] — already-present ones are left alone.
  Future<void> addAssets(String albumId, Iterable<String> localIds) async {
    final db = await _open();
    final now = DateTime.now().millisecondsSinceEpoch;
    final batch = db.batch();
    for (final localId in localIds) {
      batch.insert(_memberTable, {
        'album_id': albumId,
        'local_id': localId,
        'added_at': now,
      }, conflictAlgorithm: sqflite.ConflictAlgorithm.ignore);
    }
    await batch.commit(noResult: true);
  }

  Future<void> removeAsset(String albumId, String localId) async {
    final db = await _open();
    await db.delete(
      _memberTable,
      where: 'album_id = ? AND local_id = ?',
      whereArgs: [albumId, localId],
    );
  }

  Future<List<String>> localIdsIn(String albumId) async {
    final db = await _open();
    final rows = await db.query(
      _memberTable,
      columns: ['local_id'],
      where: 'album_id = ?',
      whereArgs: [albumId],
    );
    return rows.map((r) => r['local_id'] as String).toList();
  }

  /// Deletes the album itself and its membership rows — the assets it
  /// contained are untouched (they live in `asset_record`, not here).
  Future<void> remove(String albumId) async {
    final db = await _open();
    await db.delete(_memberTable, where: 'album_id = ?', whereArgs: [albumId]);
    await db.delete(_albumTable, where: 'id = ?', whereArgs: [albumId]);
  }

  static Album _fromRow(Map<String, Object?> row) => Album(
    id: row['id'] as String,
    name: row['name'] as String,
    createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int),
    isDemo: (row['is_demo'] as int? ?? 0) != 0,
  );
}
