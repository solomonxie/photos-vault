import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as sqflite;

/// Where the databases live: Application Support, out of the Files app.
/// Documents is what Files shows, and it's kept to what the user hands in
/// or takes out — imports and backups.
class DatabaseHome {
  static const folder = 'databases';

  static const names = [
    'photos_vault.db',
    'people.db',
    'ai_analysis.db',
    'photo_albums.db',
    'sync_jobs.db',
    'conversations.db',
  ];

  static const _sidecars = ['', '-wal', '-shm', '-journal'];

  /// Before any store opens, and before demo mode reads the path: moves
  /// databases left in Documents (sqflite's default on iOS) and points
  /// sqflite here. A rename on one volume, so nothing is copied twice.
  static Future<void> prepare() async {
    try {
      final from = await sqflite.databaseFactory.getDatabasesPath();
      final to = p.join((await getApplicationSupportDirectory()).path, folder);
      await move(Directory(from), Directory(to));
      await sqflite.databaseFactory.setDatabasesPath(to);
    } catch (_) {
      // Left where they were: sqflite still opens them there.
    }
  }

  /// Moves [names] (with their journals) from [from] to [to], and the demo
  /// library's from `from/demo` to `to/demo`. Never over a file already
  /// at [to]: that one is newer, and the old is left where it was.
  static Future<void> move(Directory from, Directory to) async {
    if (p.equals(from.path, to.path)) return;
    await to.create(recursive: true);
    for (final sub in ['', 'demo']) {
      final src = Directory(p.join(from.path, sub));
      final dst = Directory(p.join(to.path, sub));
      if (!await src.exists()) continue;
      for (final name in names) {
        if (await File(p.join(dst.path, name)).exists()) continue;
        if (!await File(p.join(src.path, name)).exists()) continue;
        await dst.create(recursive: true);
        for (final suffix in _sidecars) {
          final file = File(p.join(src.path, '$name$suffix'));
          if (await file.exists()) {
            await file.rename(p.join(dst.path, '$name$suffix'));
          }
        }
      }
    }
    // Litter an older build left in the Files app.
    try {
      final trace = File(p.join(from.path, 'zz_trace.txt'));
      if (await trace.exists()) await trace.delete();
      final demo = Directory(p.join(from.path, 'demo'));
      if (await demo.exists() && await demo.list().isEmpty) {
        await demo.delete();
      }
    } catch (_) {}
  }
}
