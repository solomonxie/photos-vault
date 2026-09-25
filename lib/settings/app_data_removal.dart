import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../backup/app_snapshot.dart';
import '../backup/bucket_backup.dart';
import '../backup/icloud_backup.dart';
import '../backup/local_vault.dart';
import '../photos/thumbnail_cache.dart';
import '../storage/asset_record_store.dart';
import '../upload/sync_job_store.dart';
import '../vault/cache.dart';
import '../vault/keys.dart';
import 'ai_settings_store.dart';
import 'backup_targets_store.dart';
import 's3_target_drafts_store.dart';

/// Everything Remove All App Data has to erase, and the order that works.
///
/// The order is the whole design. The copies go out while the credentials
/// that reach them still exist; the databases empty next; the files those
/// rows pointed at go after, because a row is not a photo and deleting one
/// leaves the other; the credentials go last of all; and the restore
/// markers are written at the very end — without them the next launch sees
/// an empty library, reads it as a fresh install, and pulls the whole thing
/// back from the copy that was just taken.
///
/// Each step swallows its own failure. One destination unreachable, one
/// directory unwritable, must not leave the wipe half done and silent,
/// which is what a single `Future.wait` over all of them used to do.
///
/// What deliberately survives: the pre-deletion copies themselves — the zip
/// in Files, the raw database copies beside it, and the archives in iCloud
/// Drive and the buckets. That is the promise the dialog makes.
class AppDataRemoval {
  AppDataRemoval({
    required this.snapshots,
    required this.settings,
    required this.vault,
    required this.icloudBackup,
    required this.bucketBackup,
    required this.targetsStore,
    SyncJobStore? syncJobStore,
    S3TargetDraftsStore? draftsStore,
    AiSettingsStore? aiSettingsStore,
    VaultKeys? vaultKeys,

    this.supportDirectory = getApplicationSupportDirectory,
    this.cacheDirectory = getApplicationCacheDirectory,
  }) : _syncJobStore = syncJobStore ?? SyncJobStore(),
       _draftsStore = draftsStore ?? S3TargetDraftsStore(),
       _aiSettingsStore = aiSettingsStore ?? AiSettingsStore(),
       _vaultKeys = vaultKeys ?? VaultKeys();

  final AppSnapshotIo snapshots;

  /// Where `app_state` lives — read for nothing here, written once at the
  /// end to seal the wipe against the fresh-install restore.
  final AssetRecordStore settings;

  final LocalVault vault;
  final ICloudBackup icloudBackup;
  final BucketBackup bucketBackup;
  final BackupTargetsStore targetsStore;

  final SyncJobStore _syncJobStore;
  final S3TargetDraftsStore _draftsStore;
  final AiSettingsStore _aiSettingsStore;
  final VaultKeys _vaultKeys;

  /// Overridable so tests never reach a real container. `null` skips the
  /// on-disk pass, which is what a widget test wants: in `testWidgets`'
  /// fake-async zone a real `path_provider` call is a platform-channel
  /// round trip that never resolves.
  final Future<Directory> Function()? supportDirectory;
  final Future<Directory> Function()? cacheDirectory;

  Future<void> run() async {
    // On this phone first: it cannot fail to reach a network, and it is
    // the copy people come back for.
    await _attempt(vault.guardBeforeDeletion);
    await _attempt(icloudBackup.backUpBeforeDeletion);
    await _attempt(bucketBackup.backUpBeforeDeletion);

    await _attempt(snapshots.clearAll);
    await _attempt(_syncJobStore.clearQueue);
    await _attempt(deleteOwnedFiles);
    await _attempt(forgetCredentials);
    await _attempt(sealAgainstRestore);
  }

  /// The bytes the rows pointed at. Clearing the databases leaves every one
  /// of these on disk: the library looks empty and the storage it took is
  /// still gone.
  ///
  /// Only what this app wrote and owns. The hash-named originals are
  /// matched by shape rather than by walking the records, so a file
  /// orphaned by an earlier crash goes too — and so that nothing else
  /// sharing the container can be caught by it.
  Future<void> deleteOwnedFiles() async {
    final support = supportDirectory;
    if (support != null) {
      final root = await support();
      await _deleteTree(Directory(p.join(root.path, ThumbnailCache.dirName)));
      await _deleteOwnedOriginals(root);
    }
    final cache = cacheDirectory;
    if (cache != null) {
      await _deleteTree(
        Directory(p.join((await cache()).path, VaultCache.root)),
      );
    }
  }

  /// Every bucket, credential, API key and album passphrase. The carriers
  /// already in a bucket are untouched and stay unreadable — see
  /// [VaultKeys.clearAll].
  Future<void> forgetCredentials() async {
    await _attempt(targetsStore.clearAll);
    await _attempt(_draftsStore.clearAll);
    await _attempt(_aiSettingsStore.clearAll);
    await _attempt(_vaultKeys.clearAll);
  }

  /// Stops the next launch from undoing all of the above.
  ///
  /// `restoreIfFreshInstall` decides on two things: an empty library, and
  /// no record of a restore having happened. A wipe produces both — it
  /// empties the library and, because the marker lives in `app_state`, it
  /// erases the record as well. So the newest archive comes straight back
  /// down, and the newest archive is the pre-deletion copy written minutes
  /// earlier, because its `99999999-` sentinel sorts it last on purpose.
  ///
  /// Writing the marker here says "the question of restoring has been
  /// settled" rather than "a restore ran", which is the honest reading:
  /// the copy is still there and Settings can still pull it back, but
  /// nothing does it unasked. A real reinstall clears this database with
  /// everything else, so first-launch restore is untouched.
  Future<void> sealAgainstRestore() async {
    final at = DateTime.now().toIso8601String();
    await settings.setAppState(ICloudBackup.restoredKey, at);
    await settings.setAppState(BucketBackup.restoredKey, at);
  }

  Future<void> _deleteOwnedOriginals(Directory root) async {
    try {
      await for (final entity in root.list()) {
        if (entity is! File) continue;
        if (!_ownedOriginal.hasMatch(p.basename(entity.path))) continue;
        await entity.delete();
      }
    } catch (_) {
      // No container yet, or one file gone between the listing and the
      // delete. The rest of the pass still stands.
    }
  }

  /// `<sha256>.<ext>` — what `ManualAddService` names an imported or edited
  /// photo it has copied into app-owned storage.
  static final _ownedOriginal = RegExp(r'^[0-9a-f]{64}\.[A-Za-z0-9]+$');

  static Future<void> _deleteTree(Directory directory) async {
    try {
      if (await directory.exists()) await directory.delete(recursive: true);
    } catch (_) {
      // Unwritable, or already gone.
    }
  }

  static Future<void> _attempt(Future<void> Function() step) async {
    try {
      await step();
    } catch (_) {
      // Offline, no iCloud container, credentials since revoked, a full
      // disk. Every later step is still worth running.
    }
  }
}
