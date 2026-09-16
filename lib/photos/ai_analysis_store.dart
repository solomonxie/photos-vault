import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite/sqflite.dart'
    show Database, DatabaseFactory, OpenDatabaseOptions;

import 'ai_analysis.dart';

/// Local `sqflite` cache of per-asset AI analysis results, keyed by
/// `AssetRecord.localId` — avoids re-billing OpenAI for a photo already
/// analyzed. See IMPLEMENTATION_PLAN.md T4.4.
class AiAnalysisStore {
  AiAnalysisStore({DatabaseFactory? databaseFactory, this._path})
    : _databaseFactory = databaseFactory ?? sqflite.databaseFactory;

  final DatabaseFactory _databaseFactory;
  final String? _path;

  Database? _db;

  static const _table = 'ai_analysis';

  Future<Database> _open() async {
    final existing = _db;
    if (existing != null) return existing;
    final path =
        _path ??
        p.join(await _databaseFactory.getDatabasesPath(), 'ai_analysis.db');
    final db = await _databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, version) => db.execute('''
          CREATE TABLE $_table (
            local_id TEXT PRIMARY KEY,
            people_count INTEGER NOT NULL,
            event_label TEXT NOT NULL,
            analyzed_at INTEGER NOT NULL
          )
        '''),
      ),
    );
    _db = db;
    return db;
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }

  Future<void> save(AiPhotoAnalysis analysis) async {
    final db = await _open();
    await db.insert(_table, {
      'local_id': analysis.localId,
      'people_count': analysis.peopleCount,
      'event_label': analysis.eventLabel,
      'analyzed_at': analysis.analyzedAt.millisecondsSinceEpoch,
    }, conflictAlgorithm: sqflite.ConflictAlgorithm.replace);
  }

  Future<Map<String, AiPhotoAnalysis>> listAll() async {
    final db = await _open();
    final rows = await db.query(_table);
    return {for (final row in rows) row['local_id'] as String: _fromRow(row)};
  }

  static AiPhotoAnalysis _fromRow(Map<String, Object?> row) => AiPhotoAnalysis(
    localId: row['local_id'] as String,
    peopleCount: row['people_count'] as int,
    eventLabel: row['event_label'] as String,
    analyzedAt: DateTime.fromMillisecondsSinceEpoch(row['analyzed_at'] as int),
  );
}
