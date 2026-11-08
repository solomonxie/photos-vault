import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:photos_vault/backup/app_snapshot.dart';
import 'package:photos_vault/backup/change_log.dart';
import 'package:photos_vault/photos/person_owner.dart';
import 'package:photos_vault/photos/person_store.dart';
import 'package:photos_vault/storage/album_store.dart';
import 'package:photos_vault/storage/asset_record_store.dart';
import 'package:photos_vault/storage/passcode_hash.dart';
import 'package:photos_vault/vault/hidden_notes.dart';
import 'package:photos_vault/vault/keys.dart';
import 'package:photos_vault/vault/owner_folder.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../settings/fake_secure_store.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  late Directory dir;
  late AssetRecordStore records;
  late AlbumStore albums;
  late PersonStore people;
  late VaultKeys keys;

  ({AssetRecordStore records, AlbumStore albums, PersonStore people}) open(
    String at,
  ) => (
    records: AssetRecordStore(
      databaseFactory: databaseFactoryFfi,
      path: p.join(at, 'photos_vault.db'),
    ),
    albums: AlbumStore(
      databaseFactory: databaseFactoryFfi,
      path: p.join(at, 'photo_albums.db'),
    ),
    people: PersonStore(
      databaseFactory: databaseFactoryFfi,
      path: p.join(at, 'people.db'),
    ),
  );

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('pv_owner_backup_');
    (:records, :albums, :people) = open(dir.path);
    keys = VaultKeys(store: FakeSecureStore(), derive: deriveOnThisIsolate);
    await keys.add('correct horse battery');
  });

  tearDown(() async {
    await records.close();
    await albums.close();
    await people.close();
    await dir.delete(recursive: true);
  });

  AppSnapshotIo io(AssetRecordStore r, AlbumStore a, PersonStore pe) =>
      AppSnapshotIo(assetRecordStore: r, albumStore: a, personStore: pe);

  test('a hidden note write moves the mark and logs nothing of it', () async {
    final before = await records.changeMark();
    final album = (await keys.activeAlbumKeys('1234'))!;

    await HiddenNotes(store: records, keys: album).save('secret words');

    expect(await records.changeMark(), greaterThan(before));
    final db = await records.syncDatabase();
    expect(
      await db.query(changeLogTable, where: "table_name = 'hidden_note'"),
      isEmpty,
    );
  });

  test('choosing who is me moves the mark', () async {
    await people.create(name: 'Kim', id: 'kim');
    final before = await records.changeMark();

    await PersonOwner(records).set('kim');

    expect(await records.changeMark(), greaterThan(before));
  });

  test('the owner and the moved notes come back on a fresh install', () async {
    await people.create(name: 'Kim', id: 'kim');
    await PersonOwner(records).set('kim');
    final plainKeys = (await keys.activeAlbumKeys('1234'))!;
    await HiddenNotes(store: records, keys: plainKeys).save('flight AS 841');
    final before = await records.changeMark();

    await OwnerFolder(
      store: records,
      people: people,
      vaultKeys: keys,
      bucketHolds: (_, _) async => false,
    ).adoptPlain('kim', '1234');
    expect(await records.changeMark(), greaterThan(before));

    final snapshot = await io(records, albums, people).export();
    expect(snapshot.vault['owner'], 'kim');

    final freshDir = await Directory.systemTemp.createTemp('pv_owner_new_');
    final fresh = open(freshDir.path);
    addTearDown(() async {
      await fresh.records.close();
      await fresh.albums.close();
      await fresh.people.close();
      await freshDir.delete(recursive: true);
    });
    await io(fresh.records, fresh.albums, fresh.people).import(snapshot);

    expect(await PersonOwner(fresh.records).id(), 'kim');
    final ownerKeys = (await keys.activeAlbumKeys(
      personAlbumCode('kim', '1234'),
    ))!;
    expect(
      (await HiddenNotes(
        store: fresh.records,
        keys: ownerKeys,
      ).list()).single.text,
      'flight AS 841',
    );
  });

  test("a restore doesn't overrule this phone's own choice", () async {
    await people.create(name: 'Kim', id: 'kim');
    await PersonOwner(records).set('kim');
    final snapshot = await io(records, albums, people).export();
    await people.create(name: 'Lee', id: 'lee');
    await PersonOwner(records).set('lee');

    await io(records, albums, people).import(snapshot);

    expect(await PersonOwner(records).id(), 'lee');
  });
}
