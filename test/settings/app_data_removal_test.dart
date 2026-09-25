import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:photos_vault/backup/app_snapshot.dart';
import 'package:photos_vault/backup/bucket_backup.dart';
import 'package:photos_vault/backup/icloud_backup.dart';
import 'package:photos_vault/backup/icloud_drive.dart';
import 'package:photos_vault/photos/thumbnail_cache.dart';
import 'package:photos_vault/settings/ai_settings_store.dart';
import 'package:photos_vault/settings/app_data_removal.dart';
import 'package:photos_vault/settings/backup_targets_store.dart';
import 'package:photos_vault/settings/s3_target_drafts_store.dart';
import 'package:photos_vault/storage/asset_record.dart';
import 'package:photos_vault/upload/pending_deletes.dart';
import 'package:photos_vault/upload/sync_job.dart';
import 'package:photos_vault/vault/cache.dart';
import 'package:photos_vault/vault/keys.dart';

import '../support/fake_album_store.dart';
import '../support/fake_asset_record_store.dart';
import '../support/fake_local_vault.dart';
import '../support/fake_person_store.dart';
import '../support/fake_sync_job_store.dart';
import 'fake_secure_store.dart';

/// An iCloud container in a map, holding whatever the wipe archived.
class _FakeDrive implements ICloudDrive {
  final archives = <String, Uint8List>{};

  @override
  Future<ICloudState> status() async => ICloudState.available;

  @override
  Future<bool> write(String name, String contents) async => false;

  @override
  Future<bool> writeBytes(String name, Uint8List bytes) async {
    archives[name] = bytes;
    return true;
  }

  @override
  Future<String?> readLatest() async => null;

  @override
  Future<Uint8List?> readBytes(String name) async => archives[name];

  @override
  Future<Uint8List?> readLatestBytes() async {
    if (archives.isEmpty) return null;
    final newest = archives.keys.toList()..sort();
    return archives[newest.last];
  }

  @override
  Future<DateTime?> latestWriteAt() async =>
      archives.isEmpty ? null : DateTime(2026, 9, 17);

  @override
  Future<List<String>> list() async => archives.keys.toList();

  @override
  Future<bool> delete(String name) async => archives.remove(name) != null;
}

({
  AppDataRemoval removal,
  FakeAssetRecordStore assets,
  FakeSyncJobStore jobs,
  FakeSecureStore keychain,
  ICloudBackup icloud,
  _FakeDrive drive,
  Directory support,
  Directory cache,
})
_subject() {
  final assets = FakeAssetRecordStore();
  final snapshots = AppSnapshotIo(
    assetRecordStore: assets,
    albumStore: FakeAlbumStore(),
    personStore: FakePersonStore(),
  );
  final drive = _FakeDrive();
  final icloud = ICloudBackup(
    snapshots: snapshots,
    settings: assets,
    drive: drive,
  );
  final keychain = FakeSecureStore();
  final targets = BackupTargetsStore(store: keychain);
  final jobs = FakeSyncJobStore();
  final support = Directory.systemTemp.createTempSync('support_');
  final cache = Directory.systemTemp.createTempSync('cache_');
  addTearDown(() {
    if (support.existsSync()) support.deleteSync(recursive: true);
    if (cache.existsSync()) cache.deleteSync(recursive: true);
  });

  return (
    assets: assets,
    jobs: jobs,
    keychain: keychain,
    icloud: icloud,
    drive: drive,
    support: support,
    cache: cache,
    removal: AppDataRemoval(
      snapshots: snapshots,
      settings: assets,
      vault: FakeLocalVault(),
      icloudBackup: icloud,
      bucketBackup: BucketBackup(
        settings: assets,
        targetsStore: targets,
        snapshots: snapshots,
      ),
      targetsStore: targets,
      syncJobStore: jobs,
      draftsStore: S3TargetDraftsStore(store: keychain),
      aiSettingsStore: AiSettingsStore(store: keychain),
      vaultKeys: VaultKeys(store: keychain),
      supportDirectory: () async => support,
      cacheDirectory: () async => cache,
    ),
  );
}

void main() {
  test('the next launch does not read the wipe as a fresh install', () async {
    final s = _subject();
    await s.assets.upsert(
      localId: 'manual:a',
      contentHash: 'a',
      platform: 'ios',
    );

    await s.removal.run();

    // The archive is in iCloud and the library is empty — both conditions
    // the fresh-install restore looks for. Only the marker stands between
    // the user and getting everything they just deleted handed back.
    expect(s.drive.archives, isNotEmpty);
    expect(await s.assets.listAll(), isEmpty);
    expect(await s.icloud.restoreIfFreshInstall(), 0);
    expect(await s.assets.listAll(), isEmpty);
  });

  test('a real reinstall still restores itself', () async {
    final s = _subject();
    await s.assets.upsert(
      localId: 'manual:a',
      contentHash: 'a',
      platform: 'ios',
    );
    await s.removal.run();

    // A reinstall takes the database with it, marker and all. The copy in
    // iCloud is the whole point of having taken it.
    final fresh = FakeAssetRecordStore();
    final reinstalled = ICloudBackup(
      snapshots: AppSnapshotIo(
        assetRecordStore: fresh,
        albumStore: FakeAlbumStore(),
        personStore: FakePersonStore(),
      ),
      settings: fresh,
      drive: s.drive,
    );

    expect(await reinstalled.restoreIfFreshInstall(), 1);
  });

  test('the photos themselves go, not just the rows', () async {
    final s = _subject();
    final owned = File(p.join(s.support.path, '${'a' * 64}.jpg'))
      ..writeAsBytesSync(const [1, 2, 3]);
    final thumbnails = Directory(p.join(s.support.path, ThumbnailCache.dirName))
      ..createSync();
    File(p.join(thumbnails.path, 'manual_a.jpg')).writeAsBytesSync(const [4]);
    final vaultCache = Directory(p.join(s.cache.path, VaultCache.root))
      ..createSync();
    File(p.join(vaultCache.path, 'blob')).writeAsBytesSync(const [5]);
    // Not ours: the raw database copies the pre-deletion guard just took,
    // and anything else sharing the container.
    final keep = File(p.join(s.support.path, 'asset_record-pre-deletion.db'))
      ..writeAsBytesSync(const [6]);

    await s.removal.run();

    expect(owned.existsSync(), isFalse);
    expect(thumbnails.existsSync(), isFalse);
    expect(vaultCache.existsSync(), isFalse);
    expect(keep.existsSync(), isTrue);
  });

  test('the only copy of a photo is never the thing deleted', () async {
    final s = _subject();
    // Imported, not backed up anywhere: the bytes on disk are the photo.
    final onlyCopy = File(p.join(s.support.path, '${'a' * 64}.jpg'))
      ..writeAsBytesSync(const [1, 2, 3]);
    await s.assets.upsert(
      localId: 'manual:${'a' * 64}',
      contentHash: 'a' * 64,
      platform: 'ios',
      sourceType: AssetSourceType.manualFile,
      sourcePath: onlyCopy.path,
    );

    await s.removal.run();

    // The copy taken first is a snapshot of rows and has never held a
    // photo. Deleting this would restore a row pointing at nothing.
    expect(onlyCopy.existsSync(), isTrue);
  });

  test('a photo safely in a bucket loses its local copy', () async {
    final s = _subject();
    final backedUp = File(p.join(s.support.path, '${'b' * 64}.jpg'))
      ..writeAsBytesSync(const [1, 2, 3]);
    await s.assets.upsert(
      localId: 'manual:${'b' * 64}',
      contentHash: 'b' * 64,
      platform: 'ios',
      sourceType: AssetSourceType.manualFile,
      sourcePath: backedUp.path,
    );
    await s.assets.updateDerivative(
      'manual:${'b' * 64}',
      DerivativeKind.original,
      const DerivativeState(
        status: UploadStatus.uploaded,
        destinationKey: 'originals/bbb',
      ),
    );

    await s.removal.run();

    expect(backedUp.existsSync(), isFalse);
  });

  test('a hidden photo with no carrier keeps its bytes', () async {
    final s = _subject();
    final hidden = File(p.join(s.support.path, '${'c' * 64}.jpg'))
      ..writeAsBytesSync(const [1, 2, 3]);
    await s.assets.upsert(
      localId: 'manual:${'c' * 64}',
      contentHash: 'c' * 64,
      platform: 'ios',
      sourceType: AssetSourceType.manualFile,
      sourcePath: hidden.path,
    );
    await s.assets.setPasscodeHash('manual:${'c' * 64}', 'hash');

    await s.removal.run();

    // Without a bucket a hidden photo has no carrier, so this file is the
    // whole photo. The restore brings the row back; the bytes have to be
    // here for it to mean anything.
    expect(hidden.existsSync(), isTrue);
  });

  test('an owed object deletion survives the wipe', () async {
    final s = _subject();
    final owed = PendingDeletes(store: s.assets);
    await owed.add(const [
      PendingDelete(objectKey: 'originals/abc', targetId: 'bucket-1'),
    ]);

    await s.removal.run();

    // The plaintext copy of a photo somebody *hid* is still in a bucket.
    // Dropping the task abandons it there with nothing left that knows.
    // Dormant is fine — the credentials went too, and re-adding that
    // bucket is what runs them.
    expect(await owed.pending(), [
      const PendingDelete(objectKey: 'originals/abc', targetId: 'bucket-1'),
    ]);
  });

  test('nothing is left to connect with', () async {
    final s = _subject();
    s.keychain.seed('backup_targets_v1', '[]');
    s.keychain.seed('s3_target_drafts_v1', '[]');
    s.keychain.seed('ai_keys_v1', '[]');
    s.keychain.seed('openai_api_key_v1', 'sk-legacy');
    s.keychain.seed('backup_sync_frequency_v1', 'daily');

    await s.removal.run();

    for (final key in const [
      'backup_targets_v1',
      's3_target_drafts_v1',
      'ai_keys_v1',
      'openai_api_key_v1',
      'backup_sync_frequency_v1',
    ]) {
      expect(await s.keychain.read(key), isNull, reason: key);
    }
  });

  test(
    'the passphrase entries survive, so the album can be reopened',
    () async {
      final s = _subject();
      final keys = VaultKeys(store: s.keychain);
      final entry = await keys.add('correct horse', hint: 'the usual');

      await s.removal.run();

      // The master key is gone — this phone cannot open the album unaided.
      expect(await s.keychain.read('vault_master_${entry.id}'), isNull);
      // The entry is not, because its salt and verifier are what a retyped
      // passphrase re-derives from. Delete it and the gate offers to set up a
      // *new* passphrase, which derives a key matching no carrier and opens
      // an album that looks empty.
      expect((await keys.entries()).map((e) => e.id), [entry.id]);
      expect(await keys.unlockEntry(entry, 'correct horse'), isTrue);
    },
  );

  test('the sync queue goes with the photos it pointed at', () async {
    final s = _subject();
    await s.jobs.enqueue(
      localId: 'manual:a',
      kind: SyncJobKind.uploadOriginal,
      displayName: 'a.jpg',
      assetCreatedAt: DateTime(2026, 9, 20),
    );

    await s.removal.run();

    expect(await s.jobs.all(), isEmpty);
  });

  test('one step failing does not strand the rest', () async {
    final s = _subject();
    s.assets.throwOnClear = true;

    await s.removal.run();

    // The database refused; the credentials and the seal still had to land,
    // or the wipe would be half done and say nothing about it.
    expect(await s.keychain.read('backup_targets_v1'), isNull);
    expect(await s.assets.getAppState(ICloudBackup.restoredKey), isNotNull);
  });
}
