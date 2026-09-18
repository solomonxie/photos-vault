import 'dart:io';

import 'package:photos_vault/backup/app_snapshot.dart';
import 'package:photos_vault/backup/snapshot_archive.dart';
import 'package:photos_vault/backup/snapshot_file.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_album_store.dart';
import '../support/fake_asset_record_store.dart';
import '../support/fake_local_vault.dart';
import '../support/fake_person_store.dart';
import '../support/test_platform_file.dart';

void main() {
  late Directory outbox;

  setUp(() {
    outbox = Directory.systemTemp.createTempSync('snapshot-outbox');
    addTearDown(() => outbox.deleteSync(recursive: true));
  });

  ({FakeAssetRecordStore assets, AppSnapshotIo io}) newStores() {
    final assets = FakeAssetRecordStore();
    return (
      assets: assets,
      io: AppSnapshotIo(
        assetRecordStore: assets,
        albumStore: FakeAlbumStore(),
        personStore: FakePersonStore(),
      ),
    );
  }

  test('the exported file is the same payload every tier gets', () async {
    final (:assets, :io) = newStores();
    await assets.upsert(localId: 'a', contentHash: 'h', platform: 'ios');
    await assets.setDescription('a', 'a day at the beach');

    final file = await SnapshotFile(
      snapshots: io,
      vault: FakeLocalVault(),
      outboxDirectory: () async => outbox,
      now: () => DateTime(2026, 9, 18),
    ).export();

    expect(file!.path, endsWith('photos-vault-2026-09-18.zip'));
    final snapshot = unzipSnapshot(file.readAsBytesSync());
    expect(snapshot!.assets.single['description'], 'a day at the beach');
  });

  test('a picked file comes back as a snapshot', () async {
    final (:assets, :io) = newStores();
    await assets.upsert(localId: 'a', contentHash: 'h', platform: 'ios');

    final exported = await SnapshotFile(
      snapshots: io,
      vault: FakeLocalVault(),
      outboxDirectory: () async => outbox,
    ).export();

    final (assets: _, io: fresh) = newStores();
    final picked = await SnapshotFile(
      snapshots: fresh,
      vault: FakeLocalVault(),
      picker: ({type = FileType.any, allowMultiple = false}) async => [
        TestPlatformFile(exported!.path),
      ],
    ).pick();

    expect(picked!.assets.single['localId'], 'a');
  });

  test('anything that is not one of ours reads as nothing', () async {
    final (assets: _, io: io) = newStores();
    final junk = File('${outbox.path}/notes.txt')
      ..writeAsStringSync('not a zip');

    final read = await SnapshotFile(
      snapshots: io,
      vault: FakeLocalVault(),
    ).read(junk);

    expect(read, isNull);
  });

  test('a restore takes the safety copy before it merges', () async {
    final (:assets, :io) = newStores();
    final vault = FakeLocalVault();
    final snapshot = AppSnapshot(
      version: AppSnapshot.currentVersion,
      exportedAt: DateTime(2026, 9, 12),
      assets: const [
        {'localId': 'a', 'contentHash': 'h', 'platform': 'ios'},
      ],
      albums: const [],
      people: const [],
    );

    final restored = await SnapshotFile(
      snapshots: io,
      vault: vault,
    ).restore(snapshot);

    expect(vault.guards, ['restore']);
    expect(restored, 1);
    expect(await assets.getByLocalId('a'), isNotNull);
  });

  test('a photo already here keeps what it has', () async {
    final (:assets, :io) = newStores();
    await assets.upsert(localId: 'a', contentHash: 'h', platform: 'ios');
    await assets.setDescription('a', 'what I wrote');

    await SnapshotFile(snapshots: io, vault: FakeLocalVault()).restore(
      AppSnapshot(
        version: AppSnapshot.currentVersion,
        exportedAt: DateTime(2026, 9, 12),
        assets: const [
          {
            'localId': 'a',
            'contentHash': 'h',
            'platform': 'ios',
            'description': 'what the file says',
          },
        ],
        albums: const [],
        people: const [],
      ),
    );

    expect((await assets.getByLocalId('a'))!.description, 'what I wrote');
  });
}
