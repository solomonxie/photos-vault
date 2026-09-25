import 'dart:convert';

import 'package:http/http.dart' as http;

import '../settings/backup_targets_store.dart';
import '../settings/s3_backup_target.dart';
import '../settings/s3_listing.dart';
import '../storage/asset_record_store.dart';
import '../upload/signing.dart';
import 'app_snapshot.dart';
import 'backup_schedule.dart';
import 'snapshot_archive.dart';

/// The same snapshot `ICloudBackup` writes to iCloud Drive, kept in the
/// user's own bucket instead — for anyone whose photos already go there and
/// who'd rather the one part that *isn't* a photo didn't depend on Apple.
///
/// Deliberately the same shape as the iCloud copy: one zip a day,
/// `app-data/20260918.zip` under the target's prefix, written only on a day
/// something actually changed. Written to every configured bucket,
/// restored from the first that answers — newest day first, and falling
/// back to the monthly zips and the `library.json` older builds wrote.
///
/// **Nothing here is ever deleted.** Where iCloud prunes to ten because the
/// user pays for that storage by the account, a bucket is already theirs
/// and a few hundred kilobytes a day is the price of being able to ask what
/// the library looked like in March. Write-only credentials are the common
/// case and the right default anyway: a bucket this app cannot delete from
/// cannot be wiped by a bug in this app.
///
/// It is the second destination, not a replacement — both switches can be
/// on, and having the copy in two places is the point of offering two.
/// Credentials still never go in it: they're in the keychain, which
/// outlives the app on its own.
class BucketBackup {
  BucketBackup({
    required this.snapshots,
    required this.settings,
    required this.targetsStore,
    Future<http.Response> Function(Uri url, {Object? body})? put,
    Future<http.Response> Function(Uri url)? get,
    Future<S3ListingResult> Function({
      required S3BackupTarget target,
      String prefix,
    })?
    list,
  }) : _put = put ?? http.put,
       _get = get ?? http.get,
       _list =
           list ??
           (({required target, prefix = ''}) =>
               listBucket(target: target, prefix: prefix));

  final AppSnapshotIo snapshots;
  final BackupTargetsStore targetsStore;

  /// Where the switch and the "already restored once" mark live — the
  /// database, not the keychain, for the same reason `ICloudBackup` says:
  /// a keychain flag survives a reinstall, so a fresh install would come up
  /// believing it had already restored and stay empty.
  final AssetRecordStore settings;

  /// Overridable for tests so none of this makes a real network call.
  ///
  /// A plain PUT rather than the photos' `background_downloader` task: this
  /// is a few kilobytes of JSON already in memory, so writing it to a
  /// temporary file first to hand a background upload a path would be work
  /// for nothing.
  final Future<http.Response> Function(Uri url, {Object? body}) _put;
  final Future<http.Response> Function(Uri url) _get;
  final Future<S3ListingResult> Function({
    required S3BackupTarget target,
    String prefix,
  })
  _list;

  static const enabledKey = 'bucket_backup_enabled';
  static const restoredKey = 'bucket_backup_restored_at';
  static const lastBackupKey = 'bucket_backup_at';
  static const markKey = 'bucket_backup_mark';

  /// Its own gate, separate from iCloud's: the two fail independently, and
  /// a week of unreachable buckets must not leave this one believing it is
  /// up to date. See [BackupSchedule].
  late final BackupSchedule schedule = BackupSchedule(
    settings: settings,
    snapshots: snapshots,
    markKey: markKey,
    atKey: lastBackupKey,
  );

  /// Its own folder beside `originals/`, so a lifecycle rule written for
  /// the photos doesn't expire the files that describe them.
  static const directoryName = 'app-data';

  /// What older builds wrote, and what [restoreIfFreshInstall] still reads
  /// when there's no monthly archive yet.
  static const legacyFileName = 'library.json';

  Future<bool> isEnabled() async =>
      await settings.getAppState(enabledKey) == 'true';

  /// Turning it on backs up immediately — "did that work?" is answered by
  /// the switch, not by a button next to it.
  Future<bool> setEnabled(bool value) async {
    await settings.setAppState(enabledKey, value ? 'true' : 'false');
    if (!value) return true;
    return backUpNow();
  }

  Future<DateTime?> lastBackupAt() => schedule.lastRunAt();

  /// Writes the current snapshot to every configured bucket. Silent about
  /// failure: this runs unattended, and a bucket that can't be reached
  /// right now is not an error to interrupt anyone with.
  Future<bool> backUpNow() async {
    final targets = await targetsStore.loadAll();
    if (targets.isEmpty) return false;
    final body = zipSnapshot(
      await snapshots.export(),
      changeLog: await snapshots.changeLog(),
    );
    final name = dailyArchiveName(DateTime.now());
    var wrote = false;
    for (final target in targets) {
      try {
        final url = await presignPutUrl(
          target: target,
          key: keyFor(target, name),
        );
        final response = await _put(url, body: body);
        wrote = wrote || response.statusCode == 200;
      } catch (_) {
        // Unreachable bucket, expired credentials — the next one may work,
        // and the copy in iCloud may already have it covered.
      }
    }
    // Only after a bucket actually took it. Recorded before, a failed
    // upload is remembered as done and the next day's gate skips for good.
    if (wrote) await schedule.recordSuccess();
    return wrote;
  }

  /// A final archive that remains newer than any ordinary daily snapshot,
  /// including one written after the library has been emptied.
  Future<bool> backUpBeforeDeletion() async {
    final targets = await targetsStore.loadAll();
    if (targets.isEmpty) return false;
    final body = zipSnapshot(
      await snapshots.export(),
      changeLog: await snapshots.changeLog(),
    );
    final name = preDeletionArchiveName(DateTime.now());
    var wrote = false;
    for (final target in targets) {
      try {
        final url = await presignPutUrl(
          target: target,
          key: keyFor(target, name),
        );
        final response = await _put(url, body: body);
        wrote = wrote || response.statusCode == 200;
      } catch (_) {
        // The remaining destinations may still preserve the final copy.
      }
    }
    return wrote;
  }

  Future<void> backUpIfEnabled() async {
    if (!await isEnabled()) return;
    if (!await schedule.isDue()) return;
    await backUpNow();
  }

  /// Pulls the snapshot back on a fresh install. Guarded the same way the
  /// iCloud one is — the library has to be empty *and* a restore must not
  /// have happened already — because running it twice would layer a stale
  /// snapshot over live work.
  Future<int> restoreIfFreshInstall() async {
    if (await settings.getAppState(restoredKey) != null) return 0;
    if ((await settings.listAll()).isNotEmpty) return 0;
    for (final target in await targetsStore.loadAll()) {
      try {
        final snapshot = await _latestSnapshotIn(target);
        if (snapshot == null || snapshot.isEmpty) continue;
        final restored = await snapshots.import(snapshot);
        await settings.setAppState(
          restoredKey,
          DateTime.now().toIso8601String(),
        );
        // Switched on for whoever restored: they plainly want the copy
        // kept, and asking again asks a question already answered.
        await settings.setAppState(enabledKey, 'true');
        return restored;
      } catch (_) {
        // Wrong bucket, expired credentials, network — try the next one.
      }
    }
    return 0;
  }

  /// The newest archive in [target], of either naming generation, or the
  /// single `library.json` an older build left there.
  ///
  /// Listed rather than guessed at: the newest copy is whatever is actually
  /// in the folder, and a device that has been off for two months has no
  /// way to know what that is.
  Future<AppSnapshot?> _latestSnapshotIn(S3BackupTarget target) async {
    final listing = await _list(target: target, prefix: keyFor(target, ''));
    final archives =
        (listing.page?.objects ?? const <S3Object>[])
            .map((object) => object.key.split('/').last)
            .where(isSnapshotArchiveName)
            .toList()
          ..sort();
    for (final name in archives.reversed) {
      final bytes = await _fetch(target, name);
      if (bytes == null) continue;
      final snapshot = unzipSnapshot(bytes);
      if (snapshot != null) return snapshot;
    }
    final legacy = await _fetch(target, legacyFileName);
    return legacy == null ? null : AppSnapshot.decode(utf8.decode(legacy));
  }

  Future<List<int>?> _fetch(S3BackupTarget target, String name) async {
    try {
      final response = await _get(
        await presignGetUrl(target: target, key: keyFor(target, name)),
      );
      return response.statusCode == 200 ? response.bodyBytes : null;
    } catch (_) {
      return null;
    }
  }

  static String keyFor(S3BackupTarget target, String fileName) => derivativeKey(
    prefix: target.prefix,
    derivativeDir: directoryName,
    fileName: fileName,
  );
}
