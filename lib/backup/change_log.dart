import 'dart:convert';

import 'package:sqflite/sqflite.dart' show Database;

/// Every write to a user-authored row, kept in order and never edited.
///
/// It buys two things. A snapshot can be taken once a day instead of on
/// every keystroke, because nothing between snapshots is unrecoverable —
/// the log still has the old value. And it answers "has anything changed
/// since the last upload?", which is what stops the off-device copies from
/// re-uploading an unchanged library every day.
///
/// Written by SQLite triggers rather than by hand at every call site.
/// There are forty-odd of those across the three databases, and a log
/// missing the one write nobody remembered to record is worse than no log,
/// because it looks complete. Triggers are rebuilt from `PRAGMA table_info`
/// on every open, so a migration that adds a column can't leave them
/// describing the old shape.
///
/// Local only. It travels *inside* the backup zip so the record outlives
/// the phone, but a restore never replays it: the ids in it were remapped
/// on the way in and mean nothing on the other side.
const changeLogTable = 'change_log';

/// Creates the log and (re)builds one trigger per operation on each of
/// [tables]. Call after opening and migrating, not from `onCreate` — the
/// trigger has to match the schema the app just finished upgrading to.
///
/// Only user-authored tables belong here. Bookkeeping (`app_state`) and
/// caches (`place_name`) are deliberately left out: logging the row that
/// records "backed up at 3pm" would move the high-water mark every time a
/// backup finished, and the gate would never see an unchanged library.
Future<void> installChangeLog(Database db, List<String> tables) async {
  await db.execute('''
    CREATE TABLE IF NOT EXISTS $changeLogTable (
      seq INTEGER PRIMARY KEY AUTOINCREMENT,
      table_name TEXT NOT NULL,
      row_key TEXT NOT NULL,
      op TEXT NOT NULL,
      before TEXT,
      after TEXT,
      at TEXT NOT NULL
    )
  ''');
  for (final table in tables) {
    final columns = await db.rawQuery('PRAGMA table_info($table)');
    if (columns.isEmpty) continue;
    final names = [for (final column in columns) column['name'] as String];
    final keys =
        columns.where((column) => (column['pk'] as int? ?? 0) > 0).toList()
          ..sort((a, b) => (a['pk'] as int).compareTo(b['pk'] as int));
    final keyNames = [for (final column in keys) column['name'] as String];

    String rowKey(String row) => keyNames.isEmpty
        ? 'CAST($row.rowid AS TEXT)'
        : keyNames
              .map((name) => "COALESCE(CAST($row.$name AS TEXT), '')")
              .join(" || '/' || ");
    String rowJson(String row) =>
        'json_object(${names.map((name) => "'$name', $row.$name").join(', ')})';

    for (final op in const ['insert', 'update', 'delete']) {
      final name = '${changeLogTable}_${table}_$op';
      final on = switch (op) {
        'insert' => 'AFTER INSERT',
        'update' => 'AFTER UPDATE',
        _ => 'AFTER DELETE',
      };
      final subject = op == 'delete' ? 'OLD' : 'NEW';
      final before = op == 'insert' ? 'NULL' : rowJson('OLD');
      final after = op == 'delete' ? 'NULL' : rowJson('NEW');
      await db.execute('DROP TRIGGER IF EXISTS $name');
      await db.execute('''
        CREATE TRIGGER $name $on ON $table
        BEGIN
          INSERT INTO $changeLogTable
            (table_name, row_key, op, before, after, at)
          VALUES (
            '$table',
            ${rowKey(subject)},
            '$op',
            $before,
            $after,
            strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
          );
        END
      ''');
    }
  }
}

/// How far the log has got. Comparing this against the number stored for a
/// destination is the whole "only if something changed" gate — no diffing,
/// no timestamps to trust.
Future<int> changeLogMark(Database db) async {
  try {
    final rows = await db.rawQuery(
      'SELECT MAX(seq) AS mark FROM $changeLogTable',
    );
    return (rows.first['mark'] as int?) ?? 0;
  } catch (_) {
    // No log yet — an install from before this existed, or a database
    // opened read-only. Nothing has changed that we can prove.
    return 0;
  }
}

/// The tail of the log, newest last, for the copy that travels in the zip.
///
/// Capped rather than complete: the whole point of the log is the recent
/// past, and a library edited for years would otherwise put megabytes of
/// history into a file that exists to be a few hundred kilobytes.
Future<List<Map<String, Object?>>> changeLogTail(
  Database db, {
  int limit = 5000,
}) async {
  try {
    final rows = await db.rawQuery(
      'SELECT * FROM $changeLogTable ORDER BY seq DESC LIMIT ?',
      [limit],
    );
    return rows.reversed.map(_decodeRow).toList();
  } catch (_) {
    return const [];
  }
}

/// `before`/`after` come out of SQLite as JSON text. Decoding them here
/// means the zip holds one document rather than JSON quoted inside JSON.
Map<String, Object?> _decodeRow(Map<String, Object?> row) => {
  ...row,
  'before': _decode(row['before']),
  'after': _decode(row['after']),
};

Object? _decode(Object? value) {
  if (value is! String) return value;
  try {
    return jsonDecode(value);
  } catch (_) {
    return value;
  }
}
