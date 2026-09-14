import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite/sqflite.dart' show Database, DatabaseFactory, OpenDatabaseOptions;

import 'passcode_hash.dart';
import 'private_album.dart';

/// Local `sqflite` store for private albums and their membership — same
/// shape as `album_store.dart` (a join table, no ownership of `asset_record`
/// rows), plus a `moved` flag per membership row: `true` means the asset was
/// *moved* in (hidden from the main library via `AssetRecordStore.setHidden`
/// — the caller's job, not this store's), `false` means *copied* in (stays
/// visible in the library too). See DESIGN.md's "Private Albums" section.
class PrivateAlbumStore {
  PrivateAlbumStore({DatabaseFactory? databaseFactory, this._path})
    : _databaseFactory = databaseFactory ?? sqflite.databaseFactory;

  final DatabaseFactory _databaseFactory;
  final String? _path;

  Database? _db;

  static const _albumTable = 'private_album';
  static const _memberTable = 'private_album_asset';

  Future<Database> _open() async {
    final existing = _db;
    if (existing != null) return existing;
    final path = _path ?? p.join(await _databaseFactory.getDatabasesPath(), 'private_albums.db');
    final db = await _databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE $_albumTable (
              id TEXT PRIMARY KEY,
              created_at INTEGER NOT NULL
            )
          ''');
          await db.execute('''
            CREATE TABLE $_memberTable (
              album_id TEXT NOT NULL,
              local_id TEXT NOT NULL,
              moved INTEGER NOT NULL DEFAULT 0,
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

  static String hashOf(String passcode) => hashPasscode(passcode);

  /// Looks up an album by its raw passcode — `null` if none has ever been
  /// created for it (the caller decides whether that means "show an empty
  /// album" or "prompt to create one").
  Future<PrivateAlbum?> find(String passcode) => findById(hashOf(passcode));

  Future<PrivateAlbum?> findById(String id) async {
    final db = await _open();
    final rows = await db.query(_albumTable, where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) return null;
    return _fromRow(rows.single);
  }

  /// Creates the album for this passcode if it doesn't exist yet; returns
  /// the existing one otherwise. Used by "Create New" up front, and lazily
  /// by "Enter" the first time an asset is actually moved/copied in.
  Future<PrivateAlbum> ensure(String passcode) => ensureById(hashOf(passcode));

  Future<PrivateAlbum> ensureById(String id) async {
    final existing = await findById(id);
    if (existing != null) return existing;
    final db = await _open();
    final now = DateTime.now();
    await db.insert(_albumTable, {'id': id, 'created_at': now.millisecondsSinceEpoch});
    return PrivateAlbum(id: id, createdAt: now);
  }

  Future<void> addAssets(String albumId, Iterable<String> localIds, {required bool moved}) async {
    final db = await _open();
    final now = DateTime.now().millisecondsSinceEpoch;
    final batch = db.batch();
    for (final localId in localIds) {
      batch.insert(_memberTable, {
        'album_id': albumId,
        'local_id': localId,
        'moved': moved ? 1 : 0,
        'added_at': now,
      }, conflictAlgorithm: sqflite.ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  Future<void> removeAsset(String albumId, String localId) async {
    final db = await _open();
    await db.delete(_memberTable, where: 'album_id = ? AND local_id = ?', whereArgs: [albumId, localId]);
  }

  Future<List<String>> localIdsIn(String albumId) async {
    final db = await _open();
    final rows = await db.query(_memberTable, columns: ['local_id'], where: 'album_id = ?', whereArgs: [albumId]);
    return rows.map((r) => r['local_id'] as String).toList();
  }

  /// `local_id`s that were *moved* in (as opposed to copied) — these are the
  /// ones a deleted album must hand back to the library by un-hiding.
  Future<List<String>> movedLocalIdsIn(String albumId) async {
    final db = await _open();
    final rows = await db.query(
      _memberTable,
      columns: ['local_id'],
      where: 'album_id = ? AND moved = 1',
      whereArgs: [albumId],
    );
    return rows.map((r) => r['local_id'] as String).toList();
  }

  /// Deletes the album and its membership rows — mirrors `AlbumStore.remove`:
  /// the assets themselves are untouched here. The caller (`PrivateAlbumScreen`)
  /// un-hides any `moved`-in assets first, via `movedLocalIdsIn`.
  Future<void> remove(String albumId) async {
    final db = await _open();
    await db.delete(_memberTable, where: 'album_id = ?', whereArgs: [albumId]);
    await db.delete(_albumTable, where: 'id = ?', whereArgs: [albumId]);
  }

  static PrivateAlbum _fromRow(Map<String, Object?> row) =>
      PrivateAlbum(id: row['id'] as String, createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int));
}
