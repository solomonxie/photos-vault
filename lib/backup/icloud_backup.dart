import '../storage/asset_record_store.dart';
import 'app_snapshot.dart';
import 'backup_schedule.dart';
import 'icloud_drive.dart';
import 'snapshot_archive.dart';

/// Keeps a copy of everything that isn't a photo in the user's own iCloud
/// Drive, and puts it back after a reinstall.
///
/// It earns its place by being the only off-device destination with no
/// setup at all: no account to make, no key to paste, no bucket to
/// provision. It is a *backup*, not sync between devices — one file
/// written, one file read on a fresh install — and the section hint says so
/// rather than letting the word "iCloud" imply a merge.
///
/// One zip a day — `20260918.zip` — written only on a day something
/// actually changed, and never more than once. A single rolling file was
/// tried first and is the wrong shape for the job: the copy is there for
/// the day something goes wrong, and "something went wrong" is usually
/// noticed later, by which time one rolling file has already been
/// overwritten with the damage.
///
/// The folder keeps the **latest [keepCopies]** and prunes the rest. A
/// count rather than an age, because here the user pays for the storage
/// and a count is what bounds the bill — the opposite of `LocalVault`,
/// where age is what keeps the promise legible. Depth beyond ten days is
/// the bucket's job: it never deletes anything.
///
/// The restore reads the newest zip, and falls back to a `202609.zip` or
/// the `library.json` older builds wrote, so an upgrade never loses the
/// copy it already had.
class ICloudBackup {
  ICloudBackup({
    required this.snapshots,
    required this.settings,
    ICloudDrive? drive,
  }) : drive = drive ?? ICloudDrive();

  final AppSnapshotIo snapshots;
  final ICloudDrive drive;

  /// Where the toggle and the "already restored once" mark live — the
  /// database, not the keychain. A keychain flag outlives the app on iOS,
  /// so a reinstall would come up believing it had already restored, and
  /// stay empty.
  final AssetRecordStore settings;

  static const enabledKey = 'icloud_backup_enabled';
  static const restoredKey = 'icloud_backup_restored_at';
  static const markKey = 'icloud_backup_mark';
  static const lastBackupKey = 'icloud_backup_at';

  /// Ten days of undo. Past that the copy is the bucket's or nobody's.
  static const keepCopies = 10;

  late final BackupSchedule schedule = BackupSchedule(
    settings: settings,
    snapshots: snapshots,
    markKey: markKey,
    atKey: lastBackupKey,
  );

  Future<bool> isEnabled() async =>
      await settings.getAppState(enabledKey) == 'true';

  /// Turning it on backs up immediately: waiting for the next change could
  /// be days, and "did that work?" should be answered by flipping the
  /// switch, not by a Sync Now button next to it.
  Future<bool> setEnabled(bool value) async {
    await settings.setAppState(enabledKey, value ? 'true' : 'false');
    if (!value) return true;
    return backUpNow();
  }

  /// Writes today's snapshot. Silent about an unusable container: this runs
  /// unattended, and a destination that isn't configured is not an error to
  /// interrupt anyone with.
  Future<bool> backUpNow() async {
    if (await drive.status() != ICloudState.available) return false;
    final wrote = await drive.writeBytes(
      dailyArchiveName(DateTime.now()),
      zipSnapshot(
        await snapshots.export(),
        changeLog: await snapshots.changeLog(),
      ),
    );
    if (!wrote) return false;
    await schedule.recordSuccess();
    await _pruneOldCopies();
    return true;
  }

  /// A final archive that is intentionally never replaced by the normal
  /// daily snapshot after the library has been emptied.
  Future<bool> backUpBeforeDeletion() async {
    if (await drive.status() != ICloudState.available) return false;
    return await drive.writeBytes(
      preDeletionArchiveName(DateTime.now()),
      zipSnapshot(
        await snapshots.export(),
        changeLog: await snapshots.changeLog(),
      ),
    );
  }

  /// Backs up only if switched on, and only when it's owed — what every
  /// "something changed" caller wants, so none of them has to remember to
  /// check either thing. See [BackupSchedule].
  Future<void> backUpIfEnabled() async {
    if (!await isEnabled()) return;
    if (!await schedule.isDue()) return;
    await backUpNow();
  }

  /// Keeps the newest [keepCopies] and deletes this app's older ones.
  /// Names sort by date, so "newest" is the tail of a sorted list — and
  /// only names this app would have written are touched: the folder is the
  /// user's, and anything else in it is theirs.
  Future<void> _pruneOldCopies() async {
    final mine = (await drive.list()).where(isSnapshotArchiveName).toList()
      ..sort();
    if (mine.length <= keepCopies) return;
    for (final name in mine.take(mine.length - keepCopies)) {
      await drive.delete(name);
    }
  }

  /// Pulls the snapshot back on a fresh install, before anything else has
  /// had a chance to write. Returns how many photos' records came back.
  ///
  /// No prompt: on first launch the user has no context for a "restore from
  /// backup?" dialog, and getting their library's work back is the entire
  /// point of having taken the copy. Guarded twice — the library has to be
  /// empty, *and* a restore has to not have happened before — because
  /// running it a second time would layer a stale snapshot over live work.
  Future<int> restoreIfFreshInstall() async {
    if (await settings.getAppState(restoredKey) != null) return 0;
    if ((await settings.listAll()).isNotEmpty) return 0;
    if (await drive.status() != ICloudState.available) return 0;
    final snapshot = await _latestSnapshot();
    if (snapshot == null || snapshot.isEmpty) return 0;
    final restored = await snapshots.import(snapshot);
    await settings.setAppState(restoredKey, DateTime.now().toIso8601String());
    // Switched on for whoever restored: they plainly want the copy kept,
    // and asking again is asking a question already answered.
    await settings.setAppState(enabledKey, 'true');
    return restored;
  }

  /// The newest zip of either naming generation, or — for a backup taken
  /// before this app wrote zips at all — the single `library.json` it used
  /// to write.
  Future<AppSnapshot?> _latestSnapshot() async {
    final bytes = await drive.readLatestBytes();
    if (bytes != null) {
      final snapshot = unzipSnapshot(bytes);
      if (snapshot != null) return snapshot;
    }
    final contents = await drive.readLatest();
    return contents == null ? null : AppSnapshot.decode(contents);
  }

  /// What older builds wrote, and what [restoreIfFreshInstall] still reads.
  static const legacyFileName = 'library.json';
}
