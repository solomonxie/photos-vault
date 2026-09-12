import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite/sqflite.dart' show Database, DatabaseFactory, OpenDatabaseOptions;

import 'asset_record.dart';

/// Local `sqflite` store for per-asset backup state — the single source of
/// truth for what's been uploaded, so a restart or a killed background task
/// resumes without re-scanning derivatives from scratch.
class AssetRecordStore {
  AssetRecordStore({DatabaseFactory? databaseFactory, this._path})
    : _databaseFactory = databaseFactory ?? sqflite.databaseFactory;

  final DatabaseFactory _databaseFactory;
  final String? _path;

  Database? _db;

  static const _table = 'asset_record';

  Future<Database> _open() async {
    final existing = _db;
    if (existing != null) return existing;
    final path = _path ?? p.join(await _databaseFactory.getDatabasesPath(), 'back_your_own_photos.db');
    final db = await _databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(version: 1, onCreate: (db, version) => db.execute(_createTableSql)),
    );
    _db = db;
    return db;
  }

  static const _createTableSql = '''
    CREATE TABLE $_table (
      local_id TEXT PRIMARY KEY,
      content_hash TEXT NOT NULL,
      platform TEXT NOT NULL,
      source_type TEXT NOT NULL DEFAULT 'photoManager',
      source_path TEXT,
      thumbnail_status TEXT NOT NULL DEFAULT 'pending',
      thumbnail_key TEXT,
      medium_status TEXT NOT NULL DEFAULT 'pending',
      medium_key TEXT,
      original_status TEXT NOT NULL DEFAULT 'pending',
      original_key TEXT,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL
    )
  ''';

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }

  /// Inserts a new record if `localId` isn't tracked yet; no-op otherwise.
  Future<AssetRecord> upsert({
    required String localId,
    required String contentHash,
    required String platform,
    AssetSourceType sourceType = AssetSourceType.photoManager,
    String? sourcePath,
  }) async {
    final db = await _open();
    final existing = await getByLocalId(localId);
    if (existing != null) return existing;

    final now = DateTime.now();
    await db.insert(_table, {
      'local_id': localId,
      'content_hash': contentHash,
      'platform': platform,
      'source_type': sourceType.name,
      'source_path': sourcePath,
      'created_at': now.millisecondsSinceEpoch,
      'updated_at': now.millisecondsSinceEpoch,
    });
    return AssetRecord(
      localId: localId,
      contentHash: contentHash,
      platform: platform,
      sourceType: sourceType,
      sourcePath: sourcePath,
      createdAt: now,
      updatedAt: now,
    );
  }

  Future<AssetRecord?> getByLocalId(String localId) async {
    final db = await _open();
    final rows = await db.query(_table, where: 'local_id = ?', whereArgs: [localId], limit: 1);
    if (rows.isEmpty) return null;
    return _fromRow(rows.single);
  }

  Future<void> updateDerivative(String localId, DerivativeKind kind, DerivativeState state) async {
    final db = await _open();
    final column = _columnPrefix(kind);
    await db.update(
      _table,
      {
        '${column}_status': state.status.name,
        '${column}_key': state.destinationKey,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'local_id = ?',
      whereArgs: [localId],
    );
  }

  Future<List<AssetRecord>> listAll() async {
    final db = await _open();
    final rows = await db.query(_table, orderBy: 'created_at ASC');
    return rows.map(_fromRow).toList();
  }

  Future<void> remove(String localId) async {
    final db = await _open();
    await db.delete(_table, where: 'local_id = ?', whereArgs: [localId]);
  }

  static String _columnPrefix(DerivativeKind kind) => switch (kind) {
    DerivativeKind.thumbnail => 'thumbnail',
    DerivativeKind.medium => 'medium',
    DerivativeKind.original => 'original',
  };

  static AssetRecord _fromRow(Map<String, Object?> row) {
    DerivativeState stateFor(DerivativeKind kind) {
      final column = _columnPrefix(kind);
      final status = UploadStatus.values.byName(row['${column}_status'] as String);
      return DerivativeState(status: status, destinationKey: row['${column}_key'] as String?);
    }

    return AssetRecord(
      localId: row['local_id'] as String,
      contentHash: row['content_hash'] as String,
      platform: row['platform'] as String,
      sourceType: AssetSourceType.values.byName(row['source_type'] as String),
      sourcePath: row['source_path'] as String?,
      createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(row['updated_at'] as int),
      derivatives: {for (final kind in DerivativeKind.values) kind: stateFor(kind)},
    );
  }
}
