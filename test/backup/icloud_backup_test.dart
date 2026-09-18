import 'package:bring_your_own_photos/backup/app_snapshot.dart';
import 'package:bring_your_own_photos/backup/icloud_backup.dart';
import 'package:bring_your_own_photos/backup/icloud_drive.dart';
import 'package:bring_your_own_photos/backup/snapshot_archive.dart';
import 'package:bring_your_own_photos/photos/person.dart';
import 'package:bring_your_own_photos/storage/asset_record.dart';

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../support/fake_album_store.dart';
import '../support/fake_asset_record_store.dart';
import '../support/fake_person_store.dart';

/// An iCloud container that lives in a map — the folder, not the plumbing,
/// is what these cases are about.
class _FakeDrive implements ICloudDrive {
  _FakeDrive({this.state = ICloudState.available});

  ICloudState state;
  final files = <String, String>{};
  final archives = <String, Uint8List>{};

  @override
  Future<ICloudState> status() async => state;

  @override
  Future<bool> write(String name, String contents) async {
    if (state != ICloudState.available) return false;
    files[name] = contents;
    return true;
  }

  @override
  Future<bool> writeBytes(String name, Uint8List bytes) async {
    if (state != ICloudState.available) return false;
    archives[name] = bytes;
    return true;
  }

  @override
  Future<String?> readLatest() async {
    if (files.isEmpty) return null;
    final newest = files.keys.toList()..sort();
    return files[newest.last];
  }

  @override
  Future<Uint8List?> readLatestBytes() async {
    if (archives.isEmpty) return null;
    final newest = archives.keys.toList()..sort();
    return archives[newest.last];
  }

  @override
  Future<DateTime?> latestWriteAt() async =>
      files.isEmpty && archives.isEmpty ? null : DateTime(2026, 9, 17);
}

({
  FakeAssetRecordStore assets,
  FakeAlbumStore albums,
  FakePersonStore people,
  AppSnapshotIo io,
})
_stores() {
  final assets = FakeAssetRecordStore();
  final albums = FakeAlbumStore();
  final people = FakePersonStore();
  return (
    assets: assets,
    albums: albums,
    people: people,
    io: AppSnapshotIo(
      assetRecordStore: assets,
      albumStore: albums,
      personStore: people,
    ),
  );
}

void main() {
  setUpAll(sqfliteFfiInit);

  test('a backup carries the work, and the switch turns it on', () async {
    final source = _stores();
    await source.assets.upsert(
      localId: 'photo:PH1',
      contentHash: 'PH1',
      platform: 'ios',
      libraryId: 'PH1',
    );
    await source.assets.setLocation('photo:PH1', 'Kyoto, Japan');
    await source.assets.setTags('photo:PH1', ['temple', 'autumn']);
    final drive = _FakeDrive();
    final backup = ICloudBackup(
      snapshots: source.io,
      settings: source.assets,
      drive: drive,
    );

    expect(await backup.isEnabled(), isFalse);
    await backup.setEnabled(true);

    expect(await backup.isEnabled(), isTrue);
    // Flipping it on backed up at once, rather than waiting for the next
    // change — which could be days off.
    expect(drive.archives, hasLength(1));
    expect(drive.archives.keys.single, monthlyArchiveName(DateTime.now()));
  });

  test('a reinstall gets its library back without being asked', () async {
    final source = _stores();
    await source.assets.upsert(
      localId: 'photo:PH1',
      contentHash: 'PH1',
      platform: 'ios',
      libraryId: 'PH1',
    );
    await source.assets.setLocation('photo:PH1', 'Kyoto, Japan');
    await source.assets.setDescription('photo:PH1', 'The maple one');
    final album = await source.albums.upsert(id: 'a1', name: 'Japan');
    await source.albums.addAssets(album.id, ['photo:PH1']);
    final person = await source.people.create(name: 'Mia');
    await source.people.addAssets(person.id, ['photo:PH1']);
    final drive = _FakeDrive();
    await ICloudBackup(
      snapshots: source.io,
      settings: source.assets,
      drive: drive,
    ).setEnabled(true);

    // Same iCloud folder, a brand new empty app.
    final fresh = _stores();
    final restored = await ICloudBackup(
      snapshots: fresh.io,
      settings: fresh.assets,
      drive: drive,
    ).restoreIfFreshInstall();

    expect(restored, 1);
    final photo = (await fresh.assets.getByLocalId('photo:PH1'))!;
    expect(photo.location, 'Kyoto, Japan');
    expect(photo.description, 'The maple one');
    expect(photo.libraryId, 'PH1');
    expect(await fresh.albums.localIdsIn('a1'), ['photo:PH1']);
    expect((await fresh.people.listAll()).single.name, 'Mia');
    // Whoever restored plainly wants the copy kept.
    expect(
      await ICloudBackup(
        snapshots: fresh.io,
        settings: fresh.assets,
        drive: drive,
      ).isEnabled(),
      isTrue,
    );
  });

  test('a library that already has photos is never restored over', () async {
    final source = _stores();
    await source.assets.upsert(
      localId: 'photo:PH1',
      contentHash: 'PH1',
      platform: 'ios',
    );
    final drive = _FakeDrive();
    await ICloudBackup(
      snapshots: source.io,
      settings: source.assets,
      drive: drive,
    ).setEnabled(true);

    final other = _stores();
    await other.assets.upsert(
      localId: 'photo:PH9',
      contentHash: 'PH9',
      platform: 'ios',
    );

    expect(
      await ICloudBackup(
        snapshots: other.io,
        settings: other.assets,
        drive: drive,
      ).restoreIfFreshInstall(),
      0,
    );
    expect(await other.assets.getByLocalId('photo:PH1'), isNull);
  });

  test('restoring happens once, not on every launch', () async {
    final source = _stores();
    await source.assets.upsert(
      localId: 'photo:PH1',
      contentHash: 'PH1',
      platform: 'ios',
    );
    final drive = _FakeDrive();
    await ICloudBackup(
      snapshots: source.io,
      settings: source.assets,
      drive: drive,
    ).setEnabled(true);

    final fresh = _stores();
    final backup = ICloudBackup(
      snapshots: fresh.io,
      settings: fresh.assets,
      drive: drive,
    );
    expect(await backup.restoreIfFreshInstall(), 1);
    // The library is empty again — the user cleared it — and a second run
    // must not hand them a stale snapshot back.
    await fresh.assets.remove('photo:PH1');
    expect(await backup.restoreIfFreshInstall(), 0);
  });

  test('an unusable container backs up nothing, quietly', () async {
    final source = _stores();
    final drive = _FakeDrive(state: ICloudState.driveOff);
    final backup = ICloudBackup(
      snapshots: source.io,
      settings: source.assets,
      drive: drive,
    );

    await backup.setEnabled(true);

    expect(drive.files, isEmpty);
    // Still on: the switch is the user's choice, not a report on whether
    // iCloud happened to be reachable this minute.
    expect(await backup.isEnabled(), isTrue);
  });

  test(
    'one file, overwritten — not a shelf of near-identical snapshots',
    () async {
      final source = _stores();
      await source.assets.upsert(
        localId: 'photo:PH1',
        contentHash: 'PH1',
        platform: 'ios',
      );
      final drive = _FakeDrive();
      final backup = ICloudBackup(
        snapshots: source.io,
        settings: source.assets,
        drive: drive,
      );

      await backup.setEnabled(true);
      await backup.backUpNow();
      await backup.backUpNow();

      // Same month, same file: a backup twice in September is one
      // September.
      expect(drive.archives.keys.toList(), [
        monthlyArchiveName(DateTime.now()),
      ]);
    },
  );

  group('the snapshot', () {
    test('survives a round trip through text', () async {
      final source = _stores();
      await source.assets.upsert(
        localId: 'manual:a',
        contentHash: 'a',
        platform: 'ios',
        sourceType: AssetSourceType.manualFile,
        sourcePath: '/old/container/a.jpg',
      );
      await source.assets.setEvent('manual:a', "Nina's Wedding");
      final mia = await source.people.create(name: 'Mia');
      final dan = await source.people.create(name: 'Daniel');
      await source.people.addRelationship(
        mia.id,
        dan.id,
        RelationshipType.sibling,
      );

      final encoded = (await source.io.export()).encode();
      final decoded = AppSnapshot.decode(encoded)!;
      final fresh = _stores();
      await fresh.io.import(decoded);

      final photo = (await fresh.assets.getByLocalId('manual:a'))!;
      expect(photo.event, "Nina's Wedding");
      // The old container is gone; the path in it would never open again.
      expect(photo.sourcePath, isNull);
      expect(
        (await fresh.people.relationshipsFor(mia.id)).single.type,
        RelationshipType.sibling,
      );
    });

    test('refuses one written by a newer version of the app', () {
      expect(AppSnapshot.decode('{"version": 99, "assets": []}'), isNull);
      expect(AppSnapshot.decode('not json at all'), isNull);
    });
  });
}
