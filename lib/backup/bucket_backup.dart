import 'dart:convert';

import 'package:http/http.dart' as http;

import '../settings/backup_targets_store.dart';
import '../settings/s3_backup_target.dart';
import '../settings/s3_listing.dart';
import '../storage/asset_record_store.dart';
import '../upload/bucket_http.dart';
import '../upload/s3_uploader.dart';
import '../upload/signing.dart';
import 'app_snapshot.dart';
import 'backup_schedule.dart';
import 'snapshot_archive.dart';
import 'snapshot_index.dart';

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
    FetchToFile? download,
    Future<S3ListingResult> Function({
      required S3BackupTarget target,
      String prefix,
      String? continuationToken,
    })?
    list,
  }) : _put = put ?? http.put,
       _download =
           download ??
           (get != null ? fetchThroughGet(get) : S3Downloader().fetch),
       _list =
           list ??
           (({required target, prefix = '', continuationToken}) => listBucket(
             target: target,
             prefix: prefix,
             continuationToken: continuationToken,
           ));

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

  /// Archives come down to a file on the background transfer.
  final FetchToFile _download;
  final Future<S3ListingResult> Function({
    required S3BackupTarget target,
    String prefix,
    String? continuationToken,
  })
  _list;

  /// A day's archive is megabytes: a longer leash than a HEAD, never none.
  static const putTimeout = Duration(seconds: 60);

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

  /// **On unless it has been turned off.** The snapshot is the only thing
  /// that maps a bucket full of opaque keys back to dates, albums, people
  /// and captions, so a bucket without one holds photos nobody can find
  /// again — and [restoreIfFreshInstall] on the new phone finds nothing to
  /// restore. Defaulting it off made the copy that makes the backup
  /// *legible* the one thing the user had to go and ask for.
  ///
  /// A few hundred kilobytes a day, into a bucket they are already paying
  /// to fill with gigabytes of photos. An unset key is therefore on; only
  /// an explicit `'false'` is off.
  Future<bool> isEnabled() async =>
      await settings.getAppState(enabledKey) != 'false';

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
  ///
  /// [payload] is the copy a pause already built for every destination.
  Future<bool> backUpNow({SnapshotPayload? payload}) async {
    final targets = await targetsStore.loadAll();
    if (targets.isEmpty) return false;
    final built = payload ?? await SnapshotPayload.build(snapshots);
    final body = built.zip;
    final index = built.csv;
    final name = dailyArchiveName(DateTime.now());
    var wrote = false;
    for (final target in targets) {
      try {
        final url = await presignPutUrl(
          target: target,
          key: keyFor(target, name),
        );
        final response = await bucketRequest(
          _put(url, body: body),
          timeout: putTimeout,
        );
        wrote = wrote || response.statusCode == 200;
      } catch (_) {
        // Unreachable bucket, expired credentials — the next one may work,
        // and the copy in iCloud may already have it covered.
      }
      await _writeIndex(target, index);
    }
    // Only after a bucket actually took it. Recorded before, a failed
    // upload is remembered as done and the next day's gate skips for good.
    if (wrote) await schedule.recordSuccess();
    return wrote;
  }

  /// The readable index, loose in `app-data/` rather than only inside the
  /// day's zip: somebody staring at this bucket in a web console after
  /// losing the phone should not have to know which of thirty zips to
  /// download first, or that they need to unzip anything at all.
  ///
  /// One rolling file, overwritten — the history is in the dated zips,
  /// each of which carries the index it was written with. Its own try
  /// block because it must never be what makes the day's backup report
  /// failure: the zip is the copy that restores.
  Future<void> _writeIndex(S3BackupTarget target, String csv) async {
    try {
      await bucketRequest(
        _put(
          await presignPutUrl(
            target: target,
            key: keyFor(target, indexEntryName),
          ),
          // Bytes, like every other body this class PUTs — a String body
          // leaves the charset to the HTTP client, and this file holds
          // captions in whatever language they were typed in.
          body: utf8.encode(csv),
        ),
        timeout: putTimeout,
      );
    } catch (_) {
      // See above.
    }
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
        final response = await bucketRequest(
          _put(url, body: body),
          timeout: putTimeout,
        );
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
  /// iCloud one is — nothing a restore could overwrite, *and* a restore
  /// must not have happened already — because running it twice would layer
  /// a stale snapshot over live work.
  Future<int> restoreIfFreshInstall({bool scannedRows = false}) async {
    final candidate = await candidateForFreshInstall(scannedRows: scannedRows);
    if (candidate == null) return 0;
    return restoreFrom(candidate.snapshot);
  }

  /// The newest copy across every bucket, or null when this install isn't
  /// fresh or none has one. Restores nothing.
  Future<RestoreCandidate?> candidateForFreshInstall({
    bool scannedRows = false,
  }) async {
    if (await settings.getAppState(restoredKey) != null) return null;
    if (!await snapshots.isFreshInstall(scannedRows: scannedRows)) {
      return null;
    }
    final found = <RestoreCandidate?>[];
    for (final target in await targetsStore.loadAll()) {
      try {
        found.add(await _latestSnapshotIn(target));
      } catch (_) {
        // Wrong bucket, expired credentials, network — try the next one.
      }
    }
    return RestoreCandidate.best(found);
  }

  Future<int> restoreFrom(AppSnapshot snapshot) async {
    final restored = await snapshots.import(snapshot);
    await markRestored();
    // Switched on for whoever restored: they plainly want the copy kept,
    // and asking again asks a question already answered.
    await settings.setAppState(enabledKey, 'true');
    return restored;
  }

  Future<void> markRestored() =>
      settings.setAppState(restoredKey, DateTime.now().toIso8601String());

  /// The archive worth restoring from in [target], of any naming
  /// generation, or the single `library.json` an older build left there.
  ///
  /// Listed rather than guessed at: what is really in the folder is the
  /// only answer, and a device that has been off for two months has no way
  /// to know it. Every page of it: the folder is never pruned, and after a
  /// thousand days the newest archives are past the first. A pre-deletion
  /// copy is taken over a newer daily one (see [latestArchiveName]); past
  /// that the dates decide, and each candidate is tried in turn because a
  /// download can fail or a zip be truncated.
  Future<RestoreCandidate?> _latestSnapshotIn(S3BackupTarget target) async {
    final names = <String>[];
    String? token;
    for (var page = 0; page < maxListingPages; page++) {
      final listing = await _list(
        target: target,
        prefix: keyFor(target, ''),
        continuationToken: token,
      );
      // A bucket that didn't answer has nothing to offer, legacy file
      // included.
      if (listing.outcome != S3ListingOutcome.ok) {
        if (page == 0) return null;
        break;
      }
      names.addAll(
        (listing.page?.objects ?? const <S3Object>[])
            .map((object) => object.key.split('/').last)
            .where(isSnapshotArchiveName),
      );
      token = listing.page?.nextToken;
      if (token == null) break;
    }
    final first = latestArchiveName(names);
    final archives = [
      ...(names.where((name) => name != first).toList()..sort()),
      ?first,
    ];
    for (final name in archives.reversed) {
      final bytes = await _fetch(target, name);
      if (bytes == null) continue;
      final snapshot = await unzipSnapshotAside(bytes);
      if (snapshot == null) continue;
      // An empty library's copy restores nothing; nor does an older one
      // stand in for it.
      return snapshot.isEmpty
          ? null
          : RestoreCandidate(
              snapshot,
              preDeletion: isPreDeletionArchiveName(name),
            );
    }
    final legacy = await _fetch(target, legacyFileName);
    final snapshot = legacy == null
        ? null
        : AppSnapshot.decode(utf8.decode(legacy));
    return snapshot == null || snapshot.isEmpty
        ? null
        : RestoreCandidate(snapshot);
  }

  /// Ten thousand objects of `app-data/`: decades of dailies.
  static const maxListingPages = 10;

  Future<List<int>?> _fetch(S3BackupTarget target, String name) async {
    final file = await downloadScratchFile(name);
    try {
      final got = await _download(target, keyFor(target, name), file.path);
      return got.saved ? await file.readAsBytes() : null;
    } catch (_) {
      return null;
    } finally {
      await dropScratch(file);
    }
  }

  static String keyFor(S3BackupTarget target, String fileName) => derivativeKey(
    prefix: target.prefix,
    derivativeDir: directoryName,
    fileName: fileName,
  );
}
