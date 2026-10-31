import 'dart:convert';

import 'package:sqflite/sqflite.dart' show Database, DatabaseExecutor;

/// One table whose writes cloud sync picks up: [columns] are recorded before
/// and after, [key] is the SQL naming the row (on `{row}`).
class CaptureSpec {
  const CaptureSpec(this.table, this.key, this.columns, {this.private});
  final String table;
  final String key;
  final List<String> columns;

  /// SQL on `{row}` for a row behind a passcode. A write that is private
  /// before and after records nothing; a row turning private or back is
  /// recorded, so the cloud can drop or regain it.
  final String? private;
}

const syncOutboxTable = 'sync_outbox';
const _flagTable = 'sync_flag';

/// A write, as the triggers recorded it; `translate.dart` turns it into ops.
class CapturedRow {
  const CapturedRow(
    this.n,
    this.table,
    this.key,
    this.kind,
    this.before,
    this.after,
  );
  final int n;
  final String table;
  final String key;

  /// `insert`, `update` or `delete`.
  final String kind;
  final Map<String, Object?>? before;
  final Map<String, Object?>? after;
}

/// Triggers that copy every write to [specs] into `sync_outbox`, in the
/// writer's own transaction, so a write and its record of it land together.
///
/// Not the backup `change_log`: that one is trimmed to the newest few
/// thousand entries, skips upload-state updates and says nothing when a row
/// turns private — the three things sync must see. Idle until [setCapture]
/// turns it on; silent while pulled ops are applied (`applying`), so they
/// aren't sent back.
///
/// Rebuilt on every open, after migrations, like `installChangeLog`.
Future<void> installSyncCapture(
  Database db,
  List<CaptureSpec> specs,
) => db.transaction((txn) async {
  await txn.execute('''
        CREATE TABLE IF NOT EXISTS $syncOutboxTable (
          n INTEGER PRIMARY KEY AUTOINCREMENT,
          tbl TEXT NOT NULL,
          row_key TEXT NOT NULL,
          kind TEXT NOT NULL,
          before TEXT,
          after TEXT
        )
      ''');
  await txn.execute('''
        CREATE TABLE IF NOT EXISTS $_flagTable (
          id INTEGER PRIMARY KEY CHECK (id = 1),
          enabled INTEGER NOT NULL DEFAULT 0,
          applying INTEGER NOT NULL DEFAULT 0
        )
      ''');
  await txn.execute(
    'INSERT OR IGNORE INTO $_flagTable (id, enabled, applying) VALUES (1, 0, 0)',
  );
  // A crash mid-apply must not leave capture switched off for good.
  await txn.execute('UPDATE $_flagTable SET applying = 0');
  for (final spec in specs) {
    final columns = await txn.rawQuery('PRAGMA table_info(${spec.table})');
    final have = {for (final c in columns) c['name'] as String};
    final cols = spec.columns.where(have.contains).toList();
    final priv = spec.private;
    String isPrivate(String row) => '(${priv!.replaceAll('{row}', row)})';
    String json(String row) =>
        'json_object(${[for (final c in cols) "'$c', $row.$c", if (priv != null) "'_private', ${isPrivate(row)}"].join(', ')})';
    final changed = cols.map((c) => 'OLD.$c IS NOT NEW.$c').join(' OR ');
    final flipped = priv == null
        ? ''
        : ' OR ${isPrivate('OLD')} IS NOT ${isPrivate('NEW')}';
    const live =
        '(SELECT enabled = 1 AND applying = 0 FROM $_flagTable WHERE id = 1)';
    for (final kind in const ['insert', 'update', 'delete']) {
      final name = '${syncOutboxTable}_${spec.table}_$kind';
      await txn.execute('DROP TRIGGER IF EXISTS $name');
      final row = kind == 'delete' ? 'OLD' : 'NEW';
      final when = [
        live,
        if (priv != null)
          switch (kind) {
            'insert' => 'NOT ${isPrivate('NEW')}',
            'delete' => 'NOT ${isPrivate('OLD')}',
            _ => 'NOT (${isPrivate('OLD')} AND ${isPrivate('NEW')})',
          },
        if (kind == 'update') '($changed$flipped)',
      ].join(' AND ');
      await txn.execute('''
            CREATE TRIGGER $name AFTER ${kind.toUpperCase()} ON ${spec.table}
            WHEN $when
            BEGIN
              INSERT INTO $syncOutboxTable (tbl, row_key, kind, before, after)
              VALUES (
                '${spec.table}',
                ${spec.key.replaceAll('{row}', row)},
                '$kind',
                ${kind == 'insert' ? 'NULL' : json('OLD')},
                ${kind == 'delete' ? 'NULL' : json('NEW')}
              );
            END
          ''');
    }
  }
});

Future<void> setCapture(Database db, {required bool enabled}) => db.rawUpdate(
  'UPDATE $_flagTable SET enabled = ? WHERE id = 1',
  [enabled ? 1 : 0],
);

/// Runs [body] with capture silenced, in one transaction: pulled ops land
/// without being recorded as local edits.
Future<T> applyingRemote<T>(
  Database db,
  Future<T> Function(DatabaseExecutor txn) body,
) => db.transaction((txn) async {
  await txn.rawUpdate('UPDATE $_flagTable SET applying = 1 WHERE id = 1');
  try {
    return await body(txn);
  } finally {
    await txn.rawUpdate('UPDATE $_flagTable SET applying = 0 WHERE id = 1');
  }
});

/// Up to [limit] captured rows, oldest first.
Future<List<CapturedRow>> readCaptured(Database db, {int limit = 500}) async =>
    [
      for (final r in await db.rawQuery(
        'SELECT n, tbl, row_key, kind, before, after FROM $syncOutboxTable '
        'ORDER BY n LIMIT ?',
        [limit],
      ))
        CapturedRow(
          r['n'] as int,
          r['tbl'] as String,
          r['row_key'] as String,
          r['kind'] as String,
          _decode(r['before']),
          _decode(r['after']),
        ),
    ];

/// Drops rows up to [n], once they are safely in `sync.db`.
Future<void> dropCaptured(Database db, int n) =>
    db.delete(syncOutboxTable, where: 'n <= ?', whereArgs: [n]);

Map<String, Object?>? _decode(Object? raw) =>
    raw is String ? (jsonDecode(raw) as Map).cast<String, Object?>() : null;
