import 'dart:convert';

import 'package:http/http.dart' as http;

import '../settings/backup_targets_store.dart';
import '../settings/s3_backup_target.dart';
import '../settings/s3_listing.dart';
import '../storage/asset_record_store.dart';
import '../upload/bucket_http.dart';
import '../upload/bucket_ops.dart';
import '../upload/s3_uploader.dart';
import '../upload/signing.dart';
import 'app_snapshot.dart';
import 'backup_device.dart';
import 'backup_schedule.dart';
import 'data_files.dart';
import 'snapshot_archive.dart';
import 'snapshot_index.dart';

/// The same snapshot `ICloudBackup` writes to iCloud Drive, kept in the
/// user's own bucket instead — for anyone whose photos already go there and
/// who'd rather the one part that *isn't* a photo didn't depend on Apple.
///
/// Deliberately the same shape as the iCloud copy: one zip a day per
/// device, `app-data/<device>/20260918.zip` under the target's prefix
/// (see `backup_device.dart`), written only on a day something actually
/// changed. A device never writes over another's day. Written to every
/// configured bucket; a restore weighs every device's copy and the old
/// shared `app-data/20260918.zip` ones, monthly zips and `library.json`
/// included (see [bestArchiveAcrossDevices]).
///
/// The chats, writings and faces go beside the zips as blobs,
/// `app-data/blobs/<sha256>`, each sent once and never again while it is
/// unchanged; the zip lists which ones it names (see `data_files.dart`).
/// A zip names only blobs a live HEAD found — today's, or the newest
/// earlier one of that store — so it never waits on a slow upload and
/// never points at a missing blob. Blobs are never deleted.
///
/// **Thinned, never emptied.** Daily zips are kept for [keepDailyDays]
/// days; older months keep their newest daily and lose the rest — "what
/// did March look like" still has an answer, at a twelfth of the cost.
/// Only this device's own exact `<device>/YYYYMMDD.zip` names are ever
/// deleted — the old shared layout is left as it is — only after a complete
/// live listing, only once that month's keeper answers a HEAD, and only on
/// a run that wrote today's zip. Write-only credentials (the common case)
/// make the delete fail, and thinning simply stops: nothing else depends on
/// it.
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
    Future<bool> Function({
      required String filePath,
      required String key,
      required S3BackupTarget target,
    })?
    putFile,
    BucketOps? ops,
    DateTime Function()? now,
    BackupDevice? backupDevice,
  }) : _put = put ?? http.put,
       _putFile = putFile ?? S3Uploader().put,
       _ops = ops ?? BucketOps(),
       _now = now ?? DateTime.now,
       _device = backupDevice,
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

  /// This phone's folder under `app-data/`.
  late final BackupDevice device =
      _device ?? BackupDevice(snapshots: snapshots, settings: settings);
  final BackupDevice? _device;

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

  /// Blobs go up from their file on the native background transfer —
  /// a hundred megabytes of chats must not sit in memory or stop when the
  /// app is backgrounded.
  final Future<bool> Function({
    required String filePath,
    required String key,
    required S3BackupTarget target,
  })
  _putFile;

  /// HEADs, and the one guarded archive delete.
  final BucketOps _ops;
  final DateTime Function() _now;

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
  /// The rows never wait for the blobs: the zip goes up first, naming for
  /// each store the newest blob confirmed in the bucket, and the changed
  /// blobs follow. Once they've all landed the zip is written again naming
  /// them. A database that changes between runs (it always does) and takes
  /// longer to send than iOS grants used to hold every zip back for good.
  ///
  /// [payload] is the copy a pause already built for every destination.
  Future<bool> backUpNow({SnapshotPayload? payload}) async {
    final targets = await targetsStore.loadAll();
    if (targets.isEmpty) return false;
    await _note('started');
    final built = payload ?? await SnapshotPayload.build(snapshots);
    try {
      // Missing the chats and writings, it would be the newest zip and
      // restore as if they never existed. Tomorrow tries again.
      if (!built.complete) {
        await _note('incomplete payload: ${built.failure}');
        return false;
      }
      if (built.empty) {
        await schedule.recordNothingToSend();
        return false;
      }
      final today = _now();
      final folder = await device.id();
      final name = '$folder/${dailyArchiveName(today)}';
      var wrote = false;
      var complete = true;
      for (final target in targets) {
        final blobs = await _planBlobs(target, built.files);
        await _note('blobs checked, ${blobs.missing.length} missing');
        final ok = await _putZip(
          target,
          name,
          blobs.complete
              ? built.zip
              : await zipWithDataFilesAside(built.zip, blobs.manifest),
        );
        await _note(ok ? 'zip up' : 'zip failed: $_lastPutError');
        // Recorded as soon as a copy is there, not after the blobs: with
        // thousands to send iOS suspends the app first, and a copy that
        // landed went on reading as days old.
        if (ok && !wrote) await schedule.recordSuccess(complete: false);
        await _writeIndex(target, folder, built.csv);
        var whole = blobs.complete;
        if (!whole && await _sendMissing(target, built.files!, blobs)) {
          whole = ok && await _putZip(target, name, built.zip);
        }
        if (!ok) continue;
        wrote = true;
        complete = complete && whole;
        try {
          await _thin(target, folder, today);
        } catch (_) {
          // Thinning is housekeeping; the day's copy is already safe.
        }
      }
      // Only after a bucket actually took it. Recorded before, a failed
      // upload is remembered as done and the next day's gate skips for good.
      if (wrote) await schedule.recordSuccess(complete: complete);
      await _note(
        wrote
            ? (complete ? 'done' : 'done, blobs pending')
            : 'no bucket took it',
      );
      return wrote;
    } finally {
      if (payload == null) await built.dispose();
    }
  }

  /// Whether the last copy is over [BackupSchedule.staleAfter] old with
  /// changes made since. For the settings row's warning.
  Future<bool> isStale() async =>
      await isEnabled() &&
      (await targetsStore.loadAll()).isNotEmpty &&
      await schedule.isStale();

  Future<bool> _putZip(
    S3BackupTarget target,
    String name,
    List<int> zip,
  ) async {
    try {
      final url = await presignPutUrl(
        target: target,
        key: keyFor(target, name),
      );
      final response = await bucketRequest(
        _put(url, body: zip),
        timeout: putTimeout,
      );
      _lastPutError = 'HTTP ${response.statusCode}';
      return response.statusCode == 200;
    } catch (e) {
      // Unreachable bucket, expired credentials — the next one may
      // work, and the copy in iCloud may already have it covered.
      _lastPutError = e.runtimeType.toString();
      return false;
    }
  }

  String? _lastPutError;

  /// How the last run went, step by step, for a stale copy to be explained
  /// from the database. Never shown; overwritten every step.
  static const lastTryKey = 'bucket_backup_last_try';

  Future<void> _note(String step) async {
    try {
      await settings.setAppState(
        lastTryKey,
        '${_now().toIso8601String()} $step',
      );
    } catch (_) {}
  }

  /// For each store in [files], the blob a zip written now may name: today's
  /// when a live HEAD finds it, else the newest earlier one that a live HEAD
  /// still finds, else none — never one that isn't there.
  Future<_BlobPlan> _planBlobs(
    S3BackupTarget target,
    DataFileSet? files,
  ) async {
    if (files == null) return const _BlobPlan([], []);
    final state = await _BlobState.load(settings, _blobStateKey(target));
    // One listing, not a HEAD per blob: thousands of chat voice clips made
    // that minutes of requests before the zip, and iOS ends a backgrounded
    // app long before. Still live; a listing that fails falls back to HEAD.
    final listed = await _listBlobs(target);
    final seen = <String, bool>{};
    Future<bool> there(DataFileEntry e) async =>
        seen[e.sha256] ??= listed == null
        ? await _blobThere(target, e)
        : listed[e.sha256] == e.bytes;
    // Uploads an earlier run handed to the background transfer and stopped
    // waiting for: they count once they've arrived.
    for (final e in state.pending) {
      if (await there(e)) state.confirmed[e.name] = e;
    }
    final manifest = <DataFileEntry>[];
    final missing = <DataFileEntry>[];
    for (final e in files.entries) {
      if (await there(e)) {
        state.confirmed[e.name] = e;
        manifest.add(e);
        continue;
      }
      missing.add(e);
      final older = state.confirmed[e.name];
      if (older != null && older.sha256 != e.sha256 && await there(older)) {
        manifest.add(older);
      }
    }
    final names = {for (final e in files.entries) e.name};
    state.confirmed.removeWhere((name, _) => !names.contains(name));
    state.pending = missing;
    await state.save(settings, _blobStateKey(target));
    return _BlobPlan([for (final e in manifest) e.toJson()], missing);
  }

  /// Sends [plan]'s missing blobs, smallest first so the most stores move
  /// forward in whatever time there is, each on the native background
  /// transfer. True once every one is proven there by a live HEAD.
  Future<bool> _sendMissing(
    S3BackupTarget target,
    DataFileSet files,
    _BlobPlan plan,
  ) async {
    final state = await _BlobState.load(settings, _blobStateKey(target));
    final sent = <String>{};
    final queue = [...plan.missing]..sort((a, b) => a.bytes - b.bytes);
    for (final e in queue) {
      if (sent.add(e.sha256)) {
        final path = files.files[e.sha256];
        if (path == null) return false;
        final key = keyFor(target, '$blobFolder/${e.sha256}');
        if (!await _putFile(filePath: path, key: key, target: target)) {
          return false;
        }
        if (!await _blobThere(target, e)) return false;
      }
      state.confirmed[e.name] = e;
      state.pending.removeWhere((p) => p.sha256 == e.sha256);
      await state.save(settings, _blobStateKey(target));
    }
    return true;
  }

  /// Every blob in [target]'s blob folder: sha256 → size. Null when the
  /// bucket couldn't be listed.
  Future<Map<String, int>?> _listBlobs(S3BackupTarget target) async {
    final folder = keyFor(target, '$blobFolder/');
    if (!folder.startsWith(target.prefix)) return null;
    try {
      final objects = await _ops.listFolder(
        target,
        folder.substring(target.prefix.length),
      );
      if (objects == null) return null;
      return {
        for (final o in objects)
          if (o.key.startsWith(folder)) o.key.substring(folder.length): o.size,
      };
    } catch (_) {
      return null;
    }
  }

  Future<bool> _blobThere(S3BackupTarget target, DataFileEntry e) async {
    final head = await _ops.head(
      target,
      keyFor(target, '$blobFolder/${e.sha256}'),
    );
    return head.isPresent && (head.size ?? e.bytes) == e.bytes;
  }

  /// Per bucket: the newest blob confirmed there for each store, and the
  /// ones last handed to the background transfer.
  static String _blobStateKey(S3BackupTarget target) =>
      'bucket_backup_blobs_${target.id}';

  /// The blobs' folder under `app-data/`.
  static const blobFolder = 'blobs';

  /// Days of dailies kept whole before a month is thinned to one.
  static const keepDailyDays = 30;

  /// Most deletions in one run: a first run over years of dailies spreads
  /// out over a few days rather than firing thousands of DELETEs at once.
  static const maxDeletesPerRun = 200;

  /// See the class comment. Only this device's own folder: the old shared
  /// layout and other devices' folders are never touched. Lists afresh, all
  /// pages, and plans from that alone; a page that doesn't answer deletes
  /// nothing.
  Future<void> _thin(
    S3BackupTarget target,
    String folder,
    DateTime today,
  ) async {
    final names = <String>[];
    String? token;
    var page = 0;
    do {
      if (page++ >= maxListingPages) return;
      final listing = await _list(
        target: target,
        // Dailies all start with the year, so the listing stays the size
        // of the archives.
        prefix: keyFor(target, '$folder/2'),
        continuationToken: token,
      );
      if (listing.outcome != S3ListingOutcome.ok || listing.page == null) {
        return;
      }
      names.addAll(listing.page!.objects.map((o) => o.key.split('/').last));
      token = listing.page!.nextToken;
    } while (token != null);
    final todays = dailyArchiveName(today);
    if (!names.contains(todays)) return;
    var deleted = 0;
    for (final (doomed, keeper) in thinningPlan(names, today)) {
      if (deleted >= maxDeletesPerRun) return;
      final outcome = await _ops.deleteOldArchive(
        target,
        keyFor(target, '$folder/$doomed'),
        keeperKey: keyFor(target, '$folder/$keeper'),
      );
      switch (outcome) {
        case ArchiveDelete.deleted:
          deleted++;
        case ArchiveDelete.refused:
          continue;
        case ArchiveDelete.failed:
          // Write-only credentials, most likely: stop for this bucket.
          return;
      }
    }
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
  ///
  /// Every device writes its own beside its zips. The loose one in
  /// `app-data/` is the library at its fullest: a device whose index would
  /// be much smaller than the one there (a cloud-only phone) leaves it be.
  Future<void> _writeIndex(
    S3BackupTarget target,
    String folder,
    String csv,
  ) async {
    final bytes = utf8.encode(csv);
    Future<void> put(String name) async {
      try {
        await bucketRequest(
          // Bytes, like every other body this class PUTs — a String body
          // leaves the charset to the HTTP client, and this file holds
          // captions in whatever language they were typed in.
          _put(
            await presignPutUrl(target: target, key: keyFor(target, name)),
            body: bytes,
          ),
          timeout: putTimeout,
        );
      } catch (_) {
        // See above.
      }
    }

    await put('$folder/$indexEntryName');
    try {
      final there = await _ops.head(target, keyFor(target, indexEntryName));
      if (shouldReplaceIndex(there, bytes.length)) await put(indexEntryName);
    } catch (_) {}
  }

  /// A final archive that remains newer than any ordinary daily snapshot,
  /// including one written after the library has been emptied.
  Future<bool> backUpBeforeDeletion() async {
    final targets = await targetsStore.loadAll();
    if (targets.isEmpty) return false;
    final built = await SnapshotPayload.build(snapshots);
    try {
      return await _writeBeforeDeletion(targets, built);
    } finally {
      await built.dispose();
    }
  }

  Future<bool> _writeBeforeDeletion(
    List<S3BackupTarget> targets,
    SnapshotPayload built,
  ) async {
    if (built.empty) return false;
    final name = '${await device.id()}/${preDeletionArchiveName(_now())}';
    var wrote = false;
    for (final target in targets) {
      // The final copy still goes up if its blobs can't: the rows are what
      // a wipe destroys first. It names only the blobs that are there.
      var blobs = await _planBlobs(target, built.files);
      if (!blobs.complete && await _sendMissing(target, built.files!, blobs)) {
        blobs = await _planBlobs(target, built.files);
      }
      final zip = blobs.complete
          ? built.zip
          : await zipWithDataFilesAside(built.zip, blobs.manifest);
      // The remaining destinations may still preserve the final copy.
      wrote = await _putZip(target, name, zip) || wrote;
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
    await snapshots.restoreDataFiles(snapshot, fetchBlob);
    await markRestored();
    // Switched on for whoever restored: they plainly want the copy kept,
    // and asking again asks a question already answered.
    await settings.setAppState(enabledKey, 'true');
    return restored;
  }

  Future<void> markRestored() =>
      settings.setAppState(restoredKey, DateTime.now().toIso8601String());

  /// The copy worth restoring from in [target]: each device's folder and
  /// the old shared layout weighed against each other (see
  /// [bestArchiveAcrossDevices]), or the single `library.json` an older
  /// build left there.
  ///
  /// Listed rather than guessed at: what is really in the folder is the
  /// only answer, and a device that has been off for two months has no way
  /// to know it. Every page of it: after a thousand days the newest
  /// archives are past the first.
  Future<RestoreCandidate?> _latestSnapshotIn(S3BackupTarget target) async {
    final base = keyFor(target, '');
    final root = await _listAll(target, base);
    // A bucket that didn't answer has nothing to offer, legacy file
    // included.
    if (root == null) return null;
    final byDevice = <String?, List<String>>{};
    void add(String rel) {
      final parts = rel.split('/');
      if (parts.length == 1 && isSnapshotArchiveName(parts[0])) {
        (byDevice[null] ??= []).add(parts[0]);
      } else if (parts.length == 2 &&
          isDeviceId(parts[0]) &&
          isSnapshotArchiveName(parts[1])) {
        (byDevice[parts[0]] ??= []).add(parts[1]);
      }
    }

    for (final key in root.keys) {
      if (key.startsWith(base)) add(key.substring(base.length));
    }
    for (final folder in root.folders) {
      final name = folder.split('/').where((s) => s.isNotEmpty).last;
      if (!isDeviceId(name) || byDevice.containsKey(name)) continue;
      final inside = await _listAll(target, '$base$name/');
      for (final key in inside?.keys ?? const <String>[]) {
        if (key.startsWith(base)) add(key.substring(base.length));
      }
    }
    final best = await bestArchiveAcrossDevices(byDevice, (device, name) async {
      final bytes = await _fetch(
        target,
        device == null ? name : '$device/$name',
      );
      return bytes == null ? null : unzipSnapshotAside(bytes);
    });
    if (best != null) return best;
    final legacy = await _fetch(target, legacyFileName);
    final snapshot = legacy == null
        ? null
        : AppSnapshot.decode(utf8.decode(legacy));
    return snapshot == null || snapshot.isEmpty
        ? null
        : RestoreCandidate(snapshot);
  }

  /// Every key and sub-folder directly under [prefix], all pages; null when
  /// the first page didn't answer.
  Future<({List<String> keys, List<String> folders})?> _listAll(
    S3BackupTarget target,
    String prefix,
  ) async {
    final keys = <String>[];
    final folders = <String>[];
    String? token;
    for (var page = 0; page < maxListingPages; page++) {
      final listing = await _list(
        target: target,
        prefix: prefix,
        continuationToken: token,
      );
      if (listing.outcome != S3ListingOutcome.ok) {
        if (page == 0) return null;
        break;
      }
      keys.addAll(
        (listing.page?.objects ?? const <S3Object>[]).map((o) => o.key),
      );
      folders.addAll(listing.page?.folders ?? const <String>[]);
      token = listing.page?.nextToken;
      if (token == null) break;
    }
    return (keys: keys, folders: folders);
  }

  /// A blob from the first bucket that has it. Also what a restore from a
  /// file picked by hand fetches through: the file is the zip, the blobs it
  /// lists are here.
  Future<bool> fetchBlob(String sha256, String toPath) async {
    if (!isBlobName(sha256)) return false;
    for (final target in await targetsStore.loadAll()) {
      try {
        final got = await _download(
          target,
          keyFor(target, '$blobFolder/$sha256'),
          toPath,
        );
        if (got.saved) return true;
      } catch (_) {}
    }
    return false;
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

/// What a zip written now may name in one bucket, and what it still owes.
class _BlobPlan {
  const _BlobPlan(this.manifest, this.missing);

  final List<Map<String, Object?>> manifest;
  final List<DataFileEntry> missing;

  bool get complete => missing.isEmpty;
}

class _BlobState {
  _BlobState(this.confirmed, this.pending);

  final Map<String, DataFileEntry> confirmed;
  List<DataFileEntry> pending;

  static Future<_BlobState> load(AssetRecordStore settings, String key) async {
    try {
      final json = jsonDecode(await settings.getAppState(key) ?? '{}') as Map;
      return _BlobState({
        for (final e in DataFileEntry.listFrom(
          json['confirmed'] as List? ?? const [],
        ))
          e.name: e,
      }, DataFileEntry.listFrom(json['pending'] as List? ?? const []));
    } catch (_) {
      return _BlobState({}, []);
    }
  }

  Future<void> save(AssetRecordStore settings, String key) =>
      settings.setAppState(
        key,
        jsonEncode({
          'confirmed': [for (final e in confirmed.values) e.toJson()],
          'pending': [for (final e in pending) e.toJson()],
        }),
      );
}

/// Whether the loose `index.csv` that [there] describes should give way to
/// one of [bytes]: always when absent, never when the bucket didn't answer,
/// and otherwise unless the new one is under four fifths of its size.
bool shouldReplaceIndex(ObjectHead there, int bytes) => switch (there.state) {
  Probe.absent => true,
  Probe.unknown => false,
  Probe.present => indexOutweighs(there.size, bytes),
};
