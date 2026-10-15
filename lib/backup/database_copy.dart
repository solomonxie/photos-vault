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
