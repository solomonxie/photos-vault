import 'dart:convert';

import 'package:sqflite/sqflite.dart' show Database, DatabaseExecutor;

/// Every write to a user-authored row, kept in order.
/// An insert or delete carries the whole row; an update, the columns it
/// changed, old and new.
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
/// because it looks complete. Triggers are checked against `PRAGMA
/// table_info` on every open and rebuilt when they differ, so a migration
/// that adds a column can't leave them describing the old shape.
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
///
/// [private] maps a table to the SQL test (on `{row}`) for a row behind a
/// passcode. A write touching one logs nothing of it: the row's earlier
/// entries go, and only the mark moves (see [changeLogMark]), so a backup
/// still notices that something changed.
///
/// [quiet] columns are bookkeeping a backup still carries (upload state):
/// an update touching only those moves the mark and logs no row. [silent]
/// ones (a cache path, a revision) do neither.
Future<void> installChangeLog(
  Database db,
  List<String> tables, {
  Map<String, String> private = const {},
  Map<String, Set<String>> quiet = const {},
  Map<String, Set<String>> silent = const {},
}) =>
    // One transaction: two stores opening the same file at once would
    // otherwise interleave their DROP and CREATE, and the loser throws
    // "trigger already exists" out of `open` — and the library never loads.
    db.transaction(
      (txn) => _installChangeLog(txn, tables, private, quiet, silent),
    );

Future<void> _installChangeLog(
  DatabaseExecutor db,
  List<String> tables,
  Map<String, String> private,
  Map<String, Set<String>> quiet,
  Map<String, Set<String>> silent,
) async {
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
  if (private.isNotEmpty) {
    await db.execute(
      'CREATE INDEX IF NOT EXISTS ${changeLogTable}_row '
      'ON $changeLogTable (table_name, row_key)',
    );
  }
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

    final test = private[table];
    final quietSet = quiet[table] ?? const {};
    final silentSet = silent[table] ?? const {};
    // An update keeps only the columns it changed, minus [silent] ones: a
    // whole row twice was ~3 KB an entry. `$."-"` names no column.
    final diffed = names.where((c) => !silentSet.contains(c)).toList();
    String diffJson(String row) => diffed.isEmpty
        ? "'{}'"
        : 'json_remove(json_object(${diffed.map((c) => "'$c', $row.$c").join(', ')}), '
              '${diffed.map((c) => "CASE WHEN OLD.$c IS NEW.$c THEN '\$.$c' ELSE '\$.\"-\"' END").join(', ')})';

    String? changed(bool Function(String) counts) {
      final cols = names.where(counts).toList();
      if (cols.isEmpty) return null;
      return cols.map((c) => 'OLD.$c IS NOT NEW.$c').join(' OR ');
    }

    // Null: no filter, every update counts.
    final userChanged = quietSet.isEmpty && silentSet.isEmpty
        ? null
        : changed((c) => !quietSet.contains(c) && !silentSet.contains(c));
    final anyChanged = silentSet.isEmpty
        ? null
        : changed((c) => !silentSet.contains(c));
    final quietChanged = quietSet.isEmpty ? null : changed(quietSet.contains);
    final drops = <String>[];
    final creates = <String, String>{};
    for (final op in const ['insert', 'update', 'delete']) {
      final name = '${changeLogTable}_${table}_$op';
      final on = switch (op) {
        'insert' => 'AFTER INSERT',
        'update' => 'AFTER UPDATE',
        _ => 'AFTER DELETE',
      };
      final subject = op == 'delete' ? 'OLD' : 'NEW';
      final before = switch (op) {
        'insert' => 'NULL',
        'update' => diffJson('OLD'),
        _ => rowJson('OLD'),
      };
      final after = switch (op) {
        'delete' => 'NULL',
        'update' => diffJson('NEW'),
        _ => rowJson('NEW'),
      };
      final rows = [if (op != 'insert') 'OLD', if (op != 'delete') 'NEW'];
      final isPrivate = test == null
          ? null
          : rows.map((r) => '(${test.replaceAll('{row}', r)})').join(' OR ');
      final isUpdate = op == 'update';
      String when(List<String?> parts) {
        final all = parts.nonNulls.toList();
        return all.isEmpty
            ? ''
            : 'WHEN ${all.map((p) => '($p)').join(' AND ')}';
      }

      drops.addAll([name, '${name}_private', '${name}_quiet']);
      if (isPrivate != null) {
        creates['${name}_private'] =
            '''
          CREATE TRIGGER ${name}_private $on ON $table
          ${when([isPrivate, if (isUpdate) anyChanged])}
          BEGIN
            DELETE FROM $changeLogTable
              WHERE table_name = '$table' AND row_key IN (
                ${rows.map(rowKey).join(', ')});
            INSERT INTO $changeLogTable (table_name, row_key, op, at)
              VALUES ('$table', '', '$_privateOp', '');
            DELETE FROM $changeLogTable WHERE seq = last_insert_rowid();
          END
        ''';
      }
      if (isUpdate && quietChanged != null) {
        creates['${name}_quiet'] =
            '''
          CREATE TRIGGER ${name}_quiet $on ON $table
          ${when([if (isPrivate != null) 'NOT ($isPrivate)', 'NOT (${userChanged ?? '0'})', quietChanged])}
          BEGIN
            INSERT INTO $changeLogTable (table_name, row_key, op, at)
              VALUES ('$table', '', '$_quietOp', '');
            DELETE FROM $changeLogTable WHERE seq = last_insert_rowid();
          END
        ''';
      }
      creates[name] =
          '''
        CREATE TRIGGER $name $on ON $table
        ${when([if (isPrivate != null) 'NOT ($isPrivate)', if (isUpdate) userChanged ?? anyChanged])}
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
      ''';
    }
    // Rebuilt only when they differ: each DDL is a schema write, on every
    // open.
    if (await _installed(db, table, drops.toSet(), creates)) continue;
    for (final name in drops) {
      await db.execute('DROP TRIGGER IF EXISTS $name');
    }
    for (final sql in creates.values) {
      await db.execute(sql);
    }
  }
}

/// Whether [table]'s log triggers among [names] are exactly [creates].
Future<bool> _installed(
  DatabaseExecutor db,
  String table,
  Set<String> names,
  Map<String, String> creates,
) async {
  final rows = await db.rawQuery(
    "SELECT name, sql FROM sqlite_master WHERE type = 'trigger' "
    'AND tbl_name = ?',
    [table],
  );
  final found = {
    for (final row in rows)
      if (names.contains(row['name'])) row['name'] as String: row['sql'],
  };
  if (found.length != creates.length) return false;
  for (final MapEntry(:key, :value) in creates.entries) {
    final sql = found[key];
    if (sql is! String || _squashed(sql) != _squashed(value)) return false;
  }
  return true;
}

String _squashed(String sql) => sql.replaceAll(RegExp(r'\s+'), ' ').trim();

const _privateOp = 'private';
const _quietOp = 'quiet';

/// Entries a build before [installChangeLog]'s `private` wrote about rows
/// behind a passcode, and the earlier history of rows behind one now. Once.
Future<void> purgePrivateEntries(
  Database db,
  String table,
  String privateTest, {
  String? rowKeySql,
}) async {
  final inTable = privateTest.replaceAll('{row}.', '');
  String fromJson(String side) => privateTest.replaceAllMapped(
    RegExp(r'\{row\}\.(\w+)'),
    (m) => "json_extract($side, '\$.${m[1]}')",
  );
  await db.execute(
    'DELETE FROM $changeLogTable WHERE table_name = ? AND ('
    '(before IS NOT NULL AND (${fromJson('before')})) OR '
    '(after IS NOT NULL AND (${fromJson('after')}))'
    '${rowKeySql == null ? '' : ' OR row_key IN '
              '(SELECT $rowKeySql FROM $table WHERE $inTable)'})',
    [table],
  );
}

/// Entries kept: what the zip ships ([changeLogTail]), so the phone holds
/// no history no backup carries.
const changeLogKeep = 5000;

/// Drops all but the newest [keep] entries. The mark is the table's
/// sequence, which this leaves alone.
///
/// In slices, so a first trim of a huge log never holds the connection long
/// enough to stall the grid's own queries behind it. [fast]: freed pages
/// are not zeroed (`secure_delete = FAST`), for a log whose entries are
/// never about a private row. Each slice sets it and puts it back inside
/// one transaction, so no other write on the connection runs under it.
Future<void> pruneChangeLog(
  Database db, {
  int keep = changeLogKeep,
  bool fast = false,
}) async {
  try {
    while (true) {
      final deleted = await db.transaction((txn) async {
        final was = fast ? await _secureDelete(txn) : null;
        if (was != null) await txn.rawQuery('PRAGMA secure_delete = FAST');
        try {
          return await txn.rawDelete(
            'DELETE FROM $changeLogTable WHERE seq IN ('
            'SELECT seq FROM $changeLogTable WHERE seq <= '
            '(SELECT MAX(seq) FROM $changeLogTable) - ? '
            'ORDER BY seq LIMIT 2000)',
            [keep],
          );
        } finally {
          if (was != null) await txn.rawQuery('PRAGMA secure_delete = $was');
        }
      });
      if (deleted == 0) return;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  } catch (_) {
    // A log that can't be trimmed is only a bigger file.
  }
}

/// Returns a row: `execute` fails on iOS.
Future<int?> _secureDelete(DatabaseExecutor db) async =>
    (await db.rawQuery('PRAGMA secure_delete')).first.values.first as int?;

/// Run on a database copy: the log down to what the zip ships.
const changeLogTailScrub =
    'DELETE FROM $changeLogTable WHERE seq <= '
    '(SELECT MAX(seq) FROM $changeLogTable) - $changeLogKeep';

/// Rewrites [table]'s update entries below [below] (written as whole rows
/// before diffs) to the columns that changed, minus [silent]: what the
/// trigger now writes. Inserts and deletes keep their whole row. Every
/// changed value stays on both sides, so nothing a reader could rebuild is
/// lost. Idempotent, in slices of [slice] by `seq`. False if it stopped.
Future<bool> slimChangeLog(
  Database db,
  String table, {
  required int below,
  Set<String> silent = const {},
  int slice = 500,
}) async {
  try {
    final first = await db.rawQuery(
      'SELECT MIN(seq) AS s FROM $changeLogTable WHERE table_name = ?',
      [table],
    );
    var from = first.first['s'] as int? ?? below;
    final quiet = silent.isEmpty
        ? ''
        : "AND x.key NOT IN (${silent.map((c) => "'$c'").join(', ')}) ";
    String side(String self, String other) =>
        '(SELECT json_group_object(x.key, x.value) '
        'FROM json_each($changeLogTable.$self) x WHERE 1 $quiet'
        "AND (json_type($changeLogTable.$other, '\$.' || x.key) IS NULL OR "
        "json_extract($changeLogTable.$other, '\$.' || x.key) IS NOT x.value))";
    while (from < below) {
      final to = from + slice < below ? from + slice : below;
      await db.rawUpdate(
        'UPDATE $changeLogTable SET before = ${side('before', 'after')}, '
        "after = ${side('after', 'before')} WHERE table_name = ? AND op = 'update' "
        'AND seq >= ? AND seq < ? AND json_valid(before) AND json_valid(after)',
        [table, from, to],
      );
      from = to;
      if (from < below) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }
    return true;
  } catch (_) {
    return false;
  }
}

/// How far the log has got. Comparing this against the number stored for a
/// destination is the whole "only if something changed" gate — no diffing,
/// no timestamps to trust.
///
/// The table's sequence rather than its highest row: a private write leaves
/// no row, only a step in the sequence.
Future<int> changeLogMark(Database db) async {
  try {
    final rows = await db.rawQuery(
      'SELECT MAX(COALESCE((SELECT seq FROM sqlite_sequence WHERE name = ?), '
      '0), COALESCE((SELECT MAX(seq) FROM $changeLogTable), 0)) AS mark',
      [changeLogTable],
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
///
/// [decode] false leaves `before`/`after` as JSON text, for a caller that
/// decodes off the UI isolate ([decodeChangeLogRow]).
Future<List<Map<String, Object?>>> changeLogTail(
  Database db, {
  int limit = changeLogKeep,
  bool decode = true,
}) async {
  try {
    final rows = await db.rawQuery(
      'SELECT * FROM $changeLogTable ORDER BY seq DESC LIMIT ?',
      [limit],
    );
    final ordered = rows.reversed;
    return decode
        ? ordered.map(decodeChangeLogRow).toList()
        : [
            for (final row in ordered) {...row},
          ];
  } catch (_) {
    return const [];
  }
}

/// `before`/`after` come out of SQLite as JSON text. Decoding them here
/// means the zip holds one document rather than JSON quoted inside JSON.
Map<String, Object?> decodeChangeLogRow(Map<String, Object?> row) => {
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
