import 'dart:convert';
import 'dart:typed_data';

import '../storage/asset_record_store.dart';
import 'app_snapshot.dart';
import 'backup_schedule.dart';
import 'icloud_drive.dart';
import 'snapshot_archive.dart';
import 'snapshot_index.dart';

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

  /// How many Remove All App Data copies to keep, matching
  /// `LocalVault.keepPreDeletionCopies`. Counted, not aged.
  static const keepPreDeletionCopies = 3;

  late final BackupSchedule schedule = BackupSchedule(
    settings: settings,
    snapshots: snapshots,
    markKey: markKey,
    atKey: lastBackupKey,
  );

  /// **On unless it has been turned off**, for the same reason
  /// `BucketBackup.isEnabled` is: this is the copy that gets the library's
  /// work back after a reinstall, it needs no setup at all, and a default
  /// of off meant the reinstall found nothing. An unset key is on; only an
  /// explicit `'false'` is off. Writing still no-ops silently when the
  /// container isn't available, so the default costs nothing on a device
  /// with iCloud Drive switched off.
  Future<bool> isEnabled() async =>
      await settings.getAppState(enabledKey) != 'false';

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
  ///
  /// [payload] is the copy a pause already built for every destination.
  Future<bool> backUpNow({SnapshotPayload? payload}) async {
    if (await drive.status() != ICloudState.available) return false;
    final built = payload ?? await SnapshotPayload.build(snapshots);
    final wrote = await drive.writeBytes(
      dailyArchiveName(DateTime.now()),
      built.zip,
    );
    if (!wrote) return false;
    // Loose beside the zips, overwritten each time: this folder is visible
    // in Files, and the recovery this is for starts with somebody opening
    // it and needing to see their library rather than a list of archives.
    // Never pruned — `isSnapshotArchiveName` only matches `.zip` names.
    await drive.writeBytes(
      indexEntryName,
      Uint8List.fromList(utf8.encode(built.csv)),
    );
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

  /// Keeps the newest [keepCopies] dated archives and the newest
  /// [keepPreDeletionCopies] final ones, and deletes this app's older ones.
  ///
  /// Two rules, because there are two kinds of copy. Dated archives sort by
  /// name, so "newest" is the tail of a sorted list. Final copies are
  /// counted separately and generously: age is the wrong rule for the one
  /// copy whose whole point is being wanted late, and ten days of dailies
  /// rolling past should not take it. But exempting them outright — which
  /// is what they got when the `99999999-` sentinel parked them at the end
  /// of the sorted list — means one more small file in somebody's own iCloud
  /// Drive for every wipe they ever perform, forever.
  ///
  /// Only names this app would have written are touched either way: the
  /// folder is the user's, and anything else in it is theirs.
  Future<void> _pruneOldCopies() async {
    final mine = (await drive.list()).where(isSnapshotArchiveName).toList();

    final dated = mine.where((name) => !isPreDeletionArchiveName(name)).toList()
      ..sort();
    if (dated.length > keepCopies) {
      for (final name in dated.take(dated.length - keepCopies)) {
        await drive.delete(name);
      }
    }

    final finals = mine.where(isPreDeletionArchiveName).toList()
      ..sort(comparePreDeletionArchives);
    if (finals.length > keepPreDeletionCopies) {
      for (final name in finals.take(finals.length - keepPreDeletionCopies)) {
        await drive.delete(name);
      }
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
  Future<int> restoreIfFreshInstall({bool scannedRows = false}) async {
    final candidate = await candidateForFreshInstall(scannedRows: scannedRows);
    if (candidate == null) return 0;
    return restoreFrom(candidate.snapshot);
  }

  /// This folder's copy for a fresh install, or null. Restores nothing.
  Future<RestoreCandidate?> candidateForFreshInstall({
    bool scannedRows = false,
  }) async {
    if (await settings.getAppState(restoredKey) != null) return null;
    if (!await snapshots.isFreshInstall(scannedRows: scannedRows)) {
      return null;
    }
    if (await drive.status() != ICloudState.available) return null;
    final found = await _latestSnapshot();
    if (found == null || found.snapshot.isEmpty) return null;
    return found;
  }

  Future<int> restoreFrom(AppSnapshot snapshot) async {
    final restored = await snapshots.import(snapshot);
    await markRestored();
    // Switched on for whoever restored: they plainly want the copy kept,
    // and asking again is asking a question already answered.
    await settings.setAppState(enabledKey, 'true');
    return restored;
  }

  Future<void> markRestored() =>
      settings.setAppState(restoredKey, DateTime.now().toIso8601String());

  /// The archive worth restoring from, of any naming generation, or — for
  /// a backup taken before this app wrote zips at all — the single
  /// `library.json` it used to write.
  ///
  /// Chosen here rather than by the folder handing back whatever sorts
  /// last: a pre-deletion copy outranks a newer daily one. See
  /// [latestArchiveName].
  Future<RestoreCandidate?> _latestSnapshot() async {
    final name = latestArchiveName(await drive.list());
    if (name != null) {
      final bytes = await drive.readBytes(name);
      if (bytes != null) {
        final snapshot = await unzipSnapshotAside(bytes);
        if (snapshot != null) {
          return RestoreCandidate(
            snapshot,
            preDeletion: isPreDeletionArchiveName(name),
          );
        }
      }
    }
    // A folder this build can't make sense of — an archive named by a
    // later build, or a listing that didn't come back.
    final bytes = await drive.readLatestBytes();
    if (bytes != null) {
      final snapshot = await unzipSnapshotAside(bytes);
      if (snapshot != null) return RestoreCandidate(snapshot);
    }
    final contents = await drive.readLatest();
    final snapshot = contents == null ? null : AppSnapshot.decode(contents);
    return snapshot == null ? null : RestoreCandidate(snapshot);
  }

  /// What older builds wrote, and what [restoreIfFreshInstall] still reads.
  static const legacyFileName = 'library.json';
}
