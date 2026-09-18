import '../storage/asset_record_store.dart';
import 'app_snapshot.dart';
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
/// One zip a month — `202609.zip` — overwritten within the month and left
/// alone after it. A single rolling file was tried first and is the wrong
/// shape for the job: the copy is there for the day something goes wrong,
/// and "something went wrong" is usually noticed weeks later, by which
/// time one rolling file has already been overwritten with the damage.
/// Twelve small files a year is a year of undo for a few hundred kilobytes.
///
/// The restore reads the newest zip, and falls back to the `library.json`
/// older builds wrote so an upgrade never loses the copy it already had.
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
    final snapshot = await snapshots.export();
    return drive.writeBytes(
      monthlyArchiveName(DateTime.now()),
      zipSnapshot(snapshot),
    );
  }

  /// Backs up only if switched on — what every "something changed" caller
  /// wants, so none of them has to remember to check.
  Future<void> backUpIfEnabled() async {
    if (await isEnabled()) await backUpNow();
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

  /// The newest monthly zip, or — for a backup taken before this app wrote
  /// zips — the single `library.json` it used to write.
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
