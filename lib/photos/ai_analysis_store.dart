import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite/sqflite.dart'
    show Database, DatabaseFactory, OpenDatabaseOptions;

import 'ai_analysis.dart';

/// Local `sqflite` cache of per-asset AI analysis results, keyed by
/// `AssetRecord.localId` — avoids re-billing OpenAI for a photo already
/// analyzed. See IMPLEMENTATION_PLAN.md T4.4.
class AiAnalysisStore {
  AiAnalysisStore({DatabaseFactory? databaseFactory, String? path})
    : this._(databaseFactory, path);

  AiAnalysisStore._(this._databaseFactory, this._path);

  /// Resolved on first use rather than in the constructor: the global
  /// factory throws where there's no `sqflite` (a widget test), and merely
  /// *having* an analysis store is not the same as asking it anything.
  final DatabaseFactory? _databaseFactory;

  DatabaseFactory get _factory => _databaseFactory ?? sqflite.databaseFactory;
  final String? _path;

  Database? _db;

  static const _table = 'ai_analysis';

  Future<Database> _open() async {
    final existing = _db;
    if (existing != null) return existing;
    final path =
        _path ?? p.join(await _factory.getDatabasesPath(), 'ai_analysis.db');
    final db = await _factory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 2,
        onCreate: (db, version) => db.execute('''
          CREATE TABLE $_table (
            local_id TEXT PRIMARY KEY,
            people_count INTEGER NOT NULL,
            event_label TEXT NOT NULL,
            analyzed_at INTEGER NOT NULL,
            tags TEXT NOT NULL DEFAULT '',
            description TEXT NOT NULL DEFAULT '',
            reviewed INTEGER NOT NULL DEFAULT 0
          )
        '''),
        // v2 added the columns a suggestion waits in. Added rather than
        // rebuilt: the face counts already in here cost a pass over the
        // whole library to work out again.
        onUpgrade: (db, from, to) async {
          if (from >= 2) return;
          await db.execute(
            "ALTER TABLE $_table ADD COLUMN tags TEXT NOT NULL DEFAULT ''",
          );
          await db.execute(
            'ALTER TABLE $_table '
            "ADD COLUMN description TEXT NOT NULL DEFAULT ''",
          );
          await db.execute(
            'ALTER TABLE $_table '
            'ADD COLUMN reviewed INTEGER NOT NULL DEFAULT 0',
          );
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

  Future<void> save(AiPhotoAnalysis analysis) async {
    final db = await _open();
    await db.insert(_table, {
      'local_id': analysis.localId,
      'people_count': analysis.peopleCount,
      'event_label': analysis.eventLabel,
      'analyzed_at': analysis.analyzedAt.millisecondsSinceEpoch,
      'tags': jsonEncode(analysis.tags),
      'description': analysis.description,
      'reviewed': analysis.reviewed ? 1 : 0,
    }, conflictAlgorithm: sqflite.ConflictAlgorithm.replace);
  }

  /// Records what the on-device pass found and nothing else. A whole-row
  /// replace here would wipe a suggestion the user hasn't looked at yet —
  /// the two halves are written by different passes and neither knows what
  /// the other has put there.
  Future<void> saveFaceCount({
    required String localId,
    required int peopleCount,
    required DateTime analyzedAt,
  }) async {
    final db = await _open();
    final updated = await db.update(
      _table,
      {
        'people_count': peopleCount,
        'analyzed_at': analyzedAt.millisecondsSinceEpoch,
      },
      where: 'local_id = ?',
      whereArgs: [localId],
    );
    if (updated > 0) return;
    await db.insert(_table, {
      'local_id': localId,
      'people_count': peopleCount,
      'event_label': '',
      'analyzed_at': analyzedAt.millisecondsSinceEpoch,
      'tags': jsonEncode(const <String>[]),
      'description': '',
      'reviewed': 0,
    }, conflictAlgorithm: sqflite.ConflictAlgorithm.replace);
  }

  /// The other half: what a vendor call came back with, waiting to be
  /// accepted or thrown away. Leaves the face count alone.
  Future<void> saveSuggestion(AiPhotoAnalysis analysis) async {
    final db = await _open();
    final row = {
      'event_label': analysis.eventLabel,
      'tags': jsonEncode(analysis.tags),
      'description': analysis.description,
      'reviewed': 0,
      'analyzed_at': analysis.analyzedAt.millisecondsSinceEpoch,
    };
    final updated = await db.update(
      _table,
      row,
      where: 'local_id = ?',
      whereArgs: [analysis.localId],
    );
    if (updated > 0) return;
    await db.insert(_table, {
      'local_id': analysis.localId,
      'people_count': analysis.peopleCount,
      ...row,
    }, conflictAlgorithm: sqflite.ConflictAlgorithm.replace);
  }

  /// Answered — kept rather than deleted so the same photo isn't offered
  /// again on the next pass.
  Future<void> markReviewed(String localId) async {
    final db = await _open();
    await db.update(
      _table,
      {'reviewed': 1},
      where: 'local_id = ?',
      whereArgs: [localId],
    );
  }

  /// Suggestions nobody has looked at yet, oldest first — the review list.
  Future<List<AiPhotoAnalysis>> unreviewed() async {
    final db = await _open();
    final rows = await db.query(
      _table,
      where: 'reviewed = 0',
      orderBy: 'analyzed_at ASC',
    );
    return [
      for (final row in rows)
        if (_fromRow(row).hasSuggestions) _fromRow(row),
    ];
  }

  /// One photo's row, or `null` if it has never been looked at.
  Future<AiPhotoAnalysis?> get(String localId) async {
    final db = await _open();
    final rows = await db.query(
      _table,
      where: 'local_id = ?',
      whereArgs: [localId],
      limit: 1,
    );
    return rows.isEmpty ? null : _fromRow(rows.first);
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
    tags: _tags(row['tags']),
    description: row['description'] as String? ?? '',
    reviewed: (row['reviewed'] as int? ?? 0) == 1,
  );

  static List<String> _tags(Object? raw) {
    if (raw is! String || raw.isEmpty) return const [];
    try {
      return (jsonDecode(raw) as List<dynamic>).whereType<String>().toList();
    } catch (_) {
      return const [];
    }
  }
}
