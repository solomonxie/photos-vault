import 'dart:io';

import 'package:sqflite/sqflite.dart' show Database, DatabaseFactory;

/// A rollback copy of [db] at [dest]: `VACUUM INTO` (consistent, and no free
/// pages carrying deleted rows), then [scrub] run on the copy, then vacuumed
/// again so what it removed is gone from the file too. `drop_ids`, a temp
/// table of [dropIds], is there for [scrub] to join against.
///
/// Written beside [dest] and renamed over it, so a kill leaves the previous
/// copy rather than half of this one. False when it couldn't be made.
Future<bool> copyDatabase(
  Database db,
  DatabaseFactory factory,
  String dest, {
  List<String> scrub = const [],
  Set<String> dropIds = const {},
}) async {
  final temp = '$dest.part';
  try {
    final stale = File(temp);
    if (await stale.exists()) await stale.delete();
    await db.execute('VACUUM INTO ?', [temp]);
    if (scrub.isNotEmpty) {
      final copy = await factory.openDatabase(temp);
      try {
        // The scrub is not a change to log; the app puts them back on open.
        for (final t in await copy.rawQuery(
          "SELECT name FROM sqlite_master WHERE type = 'trigger'",
        )) {
          await copy.execute('DROP TRIGGER IF EXISTS "${t['name']}"');
        }
        await copy.execute('CREATE TEMP TABLE drop_ids (id TEXT PRIMARY KEY)');
        final batch = copy.batch();
        for (final id in dropIds) {
          batch.insert('drop_ids', {'id': id});
        }
        await batch.commit(noResult: true);
        for (final sql in scrub) {
          await copy.execute(sql);
        }
        await copy.execute('DROP TABLE drop_ids');
        await copy.execute('VACUUM');
      } finally {
        await copy.close();
      }
    }
    await File(temp).rename(dest);
    return true;
  } catch (_) {
    try {
      await File(temp).delete();
    } catch (_) {
      // Never written.
    }
    return false;
  }
}

/// Adds every row of the database file at [path] to [live], table by table,
/// over the columns both sides have — a backup written by an older build may
/// lack a column, and a newer one may carry one this build never heard of.
/// `INSERT OR IGNORE`: a row already here keeps what it has, so running it
/// twice adds nothing. Never replaces the live file. Returns rows added.
Future<int> mergeDatabase(Database live, String path) async {
  await live.execute('ATTACH DATABASE ? AS src', [path]);
  try {
    final theirs = {
      for (final r in await live.rawQuery(
        "SELECT name FROM src.sqlite_master WHERE type = 'table' "
        "AND name NOT LIKE 'sqlite_%' AND name != 'android_metadata'",
      ))
        r['name'] as String,
    };
    final ours = {
      for (final r in await live.rawQuery(
        "SELECT name FROM main.sqlite_master WHERE type = 'table'",
      ))
        r['name'] as String,
    };
    var added = 0;
    for (final table in theirs.intersection(ours)) {
      Future<Set<String>> columns(String schema) async => {
        for (final r in await live.rawQuery(
          'PRAGMA $schema.table_info("$table")',
        ))
          r['name'] as String,
      };
      final shared = (await columns('main')).intersection(await columns('src'));
      if (shared.isEmpty) continue;
      final list = shared.map((c) => '"$c"').join(', ');
      await live.execute(
        'INSERT OR IGNORE INTO main."$table" ($list) '
        'SELECT $list FROM src."$table"',
      );
      final changed = await live.rawQuery('SELECT changes() AS n');
      added += changed.first['n'] as int? ?? 0;
    }
    return added;
  } finally {
    await live.execute('DETACH DATABASE src');
  }
}

/// A number that moves when any of [tables] gains, loses or rewrites a row:
/// count plus the largest rowid. Cheap — no scan of the rows themselves.
/// What makes an import into a store outside the change log still owe the
/// next daily backup. [extra] adds a per-table expression summed over rows
/// (e.g. `length(thumb)`), for changes that touch neither.
Future<int> tablesMark(
  Database db,
  List<String> tables, {
  Map<String, String> extra = const {},
}) async {
  var mark = 0;
  for (final table in tables) {
    final more = extra[table];
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS n, IFNULL(MAX(rowid), 0) AS top'
      '${more == null ? '' : ', IFNULL(SUM($more), 0) AS more'} '
      'FROM "$table"',
    );
    final r = rows.first;
    mark +=
        (r['n'] as int? ?? 0) * 1000003 +
        (r['top'] as int? ?? 0) +
        ((r['more'] as num?)?.toInt() ?? 0);
  }
  return mark;
}
