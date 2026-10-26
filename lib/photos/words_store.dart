import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite/sqflite.dart'
    show ConflictAlgorithm, Database, DatabaseFactory, OpenDatabaseOptions;

import '../backup/database_copy.dart';
import 'words_file.dart';

/// Where imported pictures and videos of writings live: Application
/// Support, beside the databases, out of the Files app.
Future<String> wordsMediaRoot() async =>
    p.join((await getApplicationSupportDirectory()).path, 'words');

/// Local `sqflite` store of a person's writings, one row per piece, keyed
/// by [Writing.id] so a re-import replaces rather than adds.
class WordsStore {
  WordsStore({DatabaseFactory? databaseFactory, String? path})
    : this._(databaseFactory, path);

  WordsStore._(this._databaseFactory, this._path);

  final DatabaseFactory? _databaseFactory;
  DatabaseFactory get _factory => _databaseFactory ?? sqflite.databaseFactory;
  final String? _path;

  static const _table = 'writing';
  static const _chunk = 500;
  static const _excerptChars = 400;

  Database? _db;
  Future<Database>? _opening;

  Future<Database> _open() async {
    final existing = _db;
    if (existing != null) return existing;
    final opening = _opening ??= _openOnce();
    try {
      return await opening;
    } finally {
      _opening = null;
    }
  }

  Future<Database> _openOnce() async {
    final path = _path ?? p.join(await _factory.getDatabasesPath(), 'words.db');
    return _db = await _factory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE $_table (
              id TEXT PRIMARY KEY,
              person_id TEXT NOT NULL,
              kind TEXT NOT NULL,
              title TEXT NOT NULL,
              at INTEGER,
              text TEXT NOT NULL,
              source TEXT NOT NULL,
              origin TEXT NOT NULL,
              chars INTEGER NOT NULL,
              has_media INTEGER NOT NULL
            )
          ''');
          await db.execute(
            'CREATE INDEX writing_person_at ON $_table (person_id, at)',
          );
        },
      ),
    );
  }

  Future<void> close() async {
    final db = _db;
    _db = null;
    await db?.close();
  }

  /// Puts [writings] on [personId], replacing any with the same id.
  Future<void> insert(
    String personId,
    List<Writing> writings, {
    void Function(int done)? onProgress,
  }) async {
    final db = await _open();
    for (var i = 0; i < writings.length; i += _chunk) {
      final end = i + _chunk > writings.length ? writings.length : i + _chunk;
      await db.transaction((txn) async {
        final batch = txn.batch();
        for (final w in writings.sublist(i, end)) {
          batch.insert(_table, {
            'id': w.id,
            'person_id': personId,
            'kind': w.kind.name,
            'title': w.title,
            'at': w.at?.millisecondsSinceEpoch,
            'text': w.text,
            'source': w.source,
            'origin': w.origin,
            'chars': w.text.length,
            'has_media': hasMediaRef(w.text) ? 1 : 0,
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
        await batch.commit(noResult: true);
      });
      onProgress?.call(end);
    }
  }

  /// Writings per person, in one query.
  Future<Map<String, int>> countsByPerson() async {
    final db = await _open();
    final rows = await db.rawQuery(
      'SELECT person_id, COUNT(*) AS n FROM $_table GROUP BY person_id',
    );
    return {for (final r in rows) r['person_id'] as String: r['n'] as int};
  }

  Future<int> countFor(String personId) async {
    final db = await _open();
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS n FROM $_table WHERE person_id = ?',
      [personId],
    );
    return rows.first['n'] as int;
  }

  Future<Map<WritingKind, int>> countsByKind(String personId) async {
    final db = await _open();
    final rows = await db.rawQuery(
      'SELECT kind, COUNT(*) AS n FROM $_table WHERE person_id = ? GROUP BY kind',
      [personId],
    );
    final counts = <WritingKind, int>{};
    for (final r in rows) {
      final kind = WritingKind.of(r['kind']);
      counts[kind] = (counts[kind] ?? 0) + (r['n'] as int);
    }
    return counts;
  }

  /// Newest first, undated last. [query] matches title or text.
  Future<List<WritingSummary>> page(
    String personId, {
    WritingKind? kind,
    String? query,
    int offset = 0,
    int limit = 100,
  }) async {
    final db = await _open();
    final where = StringBuffer('person_id = ?');
    final args = <Object?>[personId];
    if (kind != null) {
      where.write(' AND kind = ?');
      args.add(kind.name);
    }
    final q = query?.trim() ?? '';
    if (q.isNotEmpty) {
      where.write(" AND (title LIKE ? ESCAPE '\\' OR text LIKE ? ESCAPE '\\')");
      final like =
          '%${q.replaceAllMapped(RegExp(r'[%_\\]'), (m) => '\\${m[0]}')}%';
      args.addAll([like, like]);
    }
    final rows = await db.rawQuery(
      'SELECT id, kind, title, at, source, chars, has_media, '
      'substr(text, 1, $_excerptChars) AS head FROM $_table '
      'WHERE $where ORDER BY at IS NULL, at DESC, title '
      'LIMIT ? OFFSET ?',
      [...args, limit, offset],
    );
    return [
      for (final r in rows)
        WritingSummary(
          id: r['id'] as String,
          kind: WritingKind.of(r['kind']),
          title: r['title'] as String,
          excerpt: plainExcerpt(r['head'] as String),
          chars: r['chars'] as int,
          hasMedia: r['has_media'] == 1,
          at: r['at'] == null
              ? null
              : DateTime.fromMillisecondsSinceEpoch(r['at'] as int),
          source: r['source'] as String,
        ),
    ];
  }

  Future<Writing?> get(String id) async {
    final db = await _open();
    final rows = await db.query(_table, where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    final r = rows.first;
    return Writing(
      id: r['id'] as String,
      kind: WritingKind.of(r['kind']),
      title: r['title'] as String,
      text: r['text'] as String,
      at: r['at'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(r['at'] as int),
      source: r['source'] as String,
      origin: r['origin'] as String,
    );
  }

  /// A consistent copy at [dest], for the backup.
  Future<bool> copyTo(String dest) async =>
      copyDatabase(await _open(), _factory, dest);

  /// Rows of a backed-up copy at [path] added here.
  Future<int> mergeFrom(String path) async =>
      mergeDatabase(await _open(), path);

  /// Moves on an import (a replaced writing gets a new rowid), a merge or a
  /// delete.
  Future<int> dataMark() async =>
      tablesMark(await _open(), [_table], extra: {_table: 'chars'});

  /// Two people merged into one.
  Future<void> movePerson(String from, String to) async {
    final db = await _open();
    await db.update(
      _table,
      {'person_id': to},
      where: 'person_id = ?',
      whereArgs: [from],
    );
  }

  /// A person deleted takes their writings, and the media only those
  /// writings showed, with them.
  Future<void> forgetPerson(String personId, {String? mediaRoot}) async {
    final db = await _open();
    final ids = [
      for (final r in await db.query(
        _table,
        columns: ['id'],
        where: 'person_id = ? AND has_media = 1',
        whereArgs: [personId],
      ))
        r['id'] as String,
    ];
    await db.delete(_table, where: 'person_id = ?', whereArgs: [personId]);
    if (ids.isEmpty) return;
    final root = mediaRoot ?? await wordsMediaRoot();
    for (final id in ids) {
      final dir = Directory(p.join(root, 'media', id));
      if (await dir.exists()) await dir.delete(recursive: true);
    }
  }
}

/// Best-effort, own handle — as [forgetPersonFaces] does.
Future<void> moveWords(String from, String to, {WordsStore? store}) async {
  try {
    await (store ?? WordsStore()).movePerson(from, to);
  } catch (_) {
    // No words database — nothing to move.
  }
}

Future<void> forgetWords(String personId, {WordsStore? store}) async {
  try {
    await (store ?? WordsStore()).forgetPerson(personId);
  } catch (_) {
    // No words database — nothing to forget.
  }
}
