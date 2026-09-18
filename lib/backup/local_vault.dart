import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../storage/asset_record_store.dart';
import 'app_snapshot.dart';
import 'backup_schedule.dart';
import 'snapshot_archive.dart';

/// The copy that lives in the app's own container — the first tier, and the
/// one that actually gets used.
///
/// It does not survive deleting the app, and that isn't a weakness: it's a
/// different job. Most real data loss is not a lost phone, it's an
/// operation that did exactly what it was asked on data the user didn't
/// mean. This is the only copy that is instant, offline, and taken *before*
/// the operation that ruins the day. iCloud Drive and the bucket answer the
/// lost phone; see `ICloudBackup` and `BucketBackup`.
///
/// Three things live here, each answering something the others can't:
///
/// - **Raw database copies**, not zips. They restore by a file swap, and
///   they're the only copy that survives a *schema* problem, which no
///   row-level undo can fix.
/// - **The change log**, written by triggers and carried inside every zip
///   so the record outlives the phone. See `change_log.dart`.
/// - **Backup zips in the Files-visible folder** — the same bytes iCloud
///   and the bucket get, so the user can drag one out to anywhere.
///
/// Deliberately *not* offered as a backup destination in Settings. It
/// shares the app's sandbox, so deleting the app takes it and the data
/// together; listing it beside iCloud and the bucket would promise
/// something it can't keep. The door it does have is the Files app, and
/// the export/import pills — see `snapshot_file.dart`.
class LocalVault {
  LocalVault({
    required this.snapshots,
    required this.settings,
    Future<Directory> Function()? documentsDirectory,
    Future<Directory> Function()? supportDirectory,
    DateTime Function()? now,
  }) : _documentsDirectory =
           documentsDirectory ?? getApplicationDocumentsDirectory,
       _supportDirectory = supportDirectory ?? getApplicationSupportDirectory,
       _now = now ?? DateTime.now;

  final AppSnapshotIo snapshots;

  /// Where the last copy's change mark and timestamp live — the database,
  /// beside the data they describe, not the keychain. A keychain flag
  /// outlives the app on iOS, so a reinstall would come up believing it had
  /// already taken today's copy of a library that is now empty.
  final AssetRecordStore settings;

  final Future<Directory> Function() _documentsDirectory;
  final Future<Directory> Function() _supportDirectory;
  final DateTime Function() _now;

  static const markKey = 'local_vault_mark';
  static const lastCopyKey = 'local_vault_at';

  /// The same gate the off-device tiers use — daily, only if the change log
  /// moved, recorded after the copy lands. This tier can't fail to reach a
  /// network, but it can fail to reach a full disk.
  late final BackupSchedule schedule = BackupSchedule(
    settings: settings,
    snapshots: snapshots,
    markKey: markKey,
    atKey: lastCopyKey,
    now: _now,
  );

  /// The rolling copy, overwritten in place. One name, so a week of
  /// backgrounding the app leaves one file in Files rather than seven.
  static const dailyFileName = 'bring-your-own-photos-daily.zip';

  /// Anything a large operation writes is named apart from the daily one,
  /// so the overwrite can't eat it and the user can tell at a glance what
  /// it is: `bring-your-own-photos-before-restore-20260918-143210.zip`.
  static const guardPrefix = 'bring-your-own-photos-before-';

  /// Raw database copies, out of the Files-visible folder: they're a
  /// mechanism for rollback, not something to hand anyone.
  static const databaseCopyDirectory = 'database-copies';

  /// **By age, not by count.** Once a large operation can add files, a
  /// count silently caps how many imports you get before losing yesterday.
  /// Age keeps the promise legible — anything from the last week.
  static const keepFor = Duration(days: 7);

  /// Today's copy, if it's owed: at most once a day, and only if the change
  /// log moved since the last one.
  ///
  /// Not on every change. Copying megabytes per keystroke to guard against
  /// a once-a-year event is the wrong trade, and the log already covers
  /// everything between two copies.
  Future<bool> keepDailyCopy() async =>
      await schedule.isDue() ? copyNow() : false;

  /// The copy, unconditionally — what the gate calls once it has decided,
  /// and what a test can call without arranging a date.
  Future<bool> copyNow() async {
    final wrote = await _writeZip(dailyFileName);
    if (!wrote) return false;
    await _copyDatabases();
    await prune();
    await schedule.recordSuccess();
    return true;
  }

  /// A copy named after what it precedes, taken *before* an import, a
  /// restore or a demo reseed — anything that rewrites many rows at once.
  ///
  /// This is the copy that gets used. The bad import is the failure people
  /// actually hit, and it happens minutes after the day's rolling backup
  /// already captured the good state — or hours after, having captured
  /// nothing at all.
  ///
  /// [operation] names it: `restore`, `import`, `demo-data`.
  Future<File?> guard(String operation) async {
    final at = _now();
    final stamp =
        '${at.year.toString().padLeft(4, '0')}'
        '${at.month.toString().padLeft(2, '0')}'
        '${at.day.toString().padLeft(2, '0')}-'
        '${at.hour.toString().padLeft(2, '0')}'
        '${at.minute.toString().padLeft(2, '0')}'
        '${at.second.toString().padLeft(2, '0')}';
    final name = '$guardPrefix$operation-$stamp.zip';
    if (!await _writeZip(name)) return null;
    await _copyDatabases(suffix: '$operation-$stamp');
    return File(p.join((await _documentsDirectory()).path, name));
  }

  /// One payload, written wherever tier 1 wants it. The same bytes iCloud
  /// and the bucket get — which is what makes a file dragged out of Files
  /// importable, and a file imported from anywhere restorable.
  Future<bool> _writeZip(String name) async {
    try {
      final bytes = zipSnapshot(
        await snapshots.export(),
        changeLog: await snapshots.changeLog(),
      );
      final directory = await _documentsDirectory();
      await directory.create(recursive: true);
      await File(p.join(directory.path, name)).writeAsBytes(bytes, flush: true);
      return true;
    } catch (_) {
      // A full disk or an unwritable container. Runs unattended; the other
      // tiers may still have it covered, and nothing here is worth
      // interrupting anyone with.
      return false;
    }
  }

  /// The raw files, checkpointed first so the copy isn't missing the writes
  /// still sitting in the `-wal` sidecar.
  Future<void> _copyDatabases({String? suffix}) async {
    try {
      final directory = Directory(
        p.join((await _supportDirectory()).path, databaseCopyDirectory),
      );
      await directory.create(recursive: true);
      final at = _now();
      final stamp =
          suffix ??
          '${at.year.toString().padLeft(4, '0')}'
              '${at.month.toString().padLeft(2, '0')}'
              '${at.day.toString().padLeft(2, '0')}';
      for (final file in await snapshots.databaseFiles()) {
        final base = p.basenameWithoutExtension(file.path);
        await file.copy(p.join(directory.path, '$base-$stamp.db'));
      }
    } catch (_) {
      // Same as the zip: unattended, and the zip already went out.
    }
  }

  /// Drops anything this app wrote that is older than [keepFor]. The daily
  /// zip is exempt — it's overwritten, not accumulated, so pruning it would
  /// just delete the most recent copy on a quiet week.
  Future<void> prune() async {
    final cutoff = _now().subtract(keepFor);
    await _pruneIn(
      await _documentsDirectory(),
      (name) => name.startsWith(guardPrefix) && name.endsWith('.zip'),
      cutoff,
    );
    await _pruneIn(
      Directory(
        p.join((await _supportDirectory()).path, databaseCopyDirectory),
      ),
      (name) => name.endsWith('.db'),
      cutoff,
    );
  }

  Future<void> _pruneIn(
    Directory directory,
    bool Function(String name) mine,
    DateTime cutoff,
  ) async {
    try {
      if (!directory.existsSync()) return;
      for (final entity in directory.listSync()) {
        if (entity is! File) continue;
        if (!mine(p.basename(entity.path))) continue;
        if (entity.statSync().modified.isAfter(cutoff)) continue;
        await entity.delete();
      }
    } catch (_) {
      // Nothing here is load-bearing; a file that won't delete today gets
      // another go tomorrow.
    }
  }

  /// What's in the Files-visible folder right now, newest first — for the
  /// restore picker's "on this iPhone" list.
  Future<List<File>> localCopies() async {
    try {
      final directory = await _documentsDirectory();
      if (!directory.existsSync()) return const [];
      final files =
          directory
              .listSync()
              .whereType<File>()
              .where(
                (file) =>
                    p.basename(file.path).startsWith('bring-your-own-photos-'),
              )
              .toList()
            ..sort(
              (a, b) => b.statSync().modified.compareTo(a.statSync().modified),
            );
      return files;
    } catch (_) {
      return const [];
    }
  }
}
