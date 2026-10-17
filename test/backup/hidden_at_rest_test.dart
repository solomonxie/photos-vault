import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:photos_vault/backup/app_snapshot.dart';
import 'package:photos_vault/backup/change_log.dart';
import 'package:photos_vault/backup/snapshot_archive.dart';
import 'package:photos_vault/photos/person_store.dart';
import 'package:photos_vault/settings/secure_store.dart';
import 'package:photos_vault/storage/album_store.dart';
import 'package:photos_vault/storage/asset_record.dart';
import 'package:photos_vault/storage/asset_record_store.dart';
import 'package:photos_vault/storage/bucket_object.dart';
import 'package:photos_vault/storage/passcode_hash.dart';
import 'package:photos_vault/vault/keys.dart';
import 'package:photos_vault/vault/passcode_tags.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _MemoryStore implements SecureStore {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}

const _carrierKey =
    'p/originals/20170309082303_cccccccccccccccccccccccccccccccc.jpg';
const _secretCaption = 'the-hidden-caption';

void main() {
  setUpAll(sqfliteFfiInit);

  late Directory dir;
  late AssetRecordStore records;
  late AlbumStore albums;
  late PersonStore people;
  late AppSnapshotIo io;
  late _MemoryStore keychain;
  late VaultKeys keys;
  late String tag;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('pv_at_rest_');
    records = AssetRecordStore(
      databaseFactory: databaseFactoryFfi,
      path: p.join(dir.path, 'photos_vault.db'),
    );
    albums = AlbumStore(
      databaseFactory: databaseFactoryFfi,
      path: p.join(dir.path, 'photo_albums.db'),
    );
    people = PersonStore(
      databaseFactory: databaseFactoryFfi,
      path: p.join(dir.path, 'people.db'),
    );
    io = AppSnapshotIo(
      assetRecordStore: records,
      albumStore: albums,
      personStore: people,
    );
    keychain = _MemoryStore();
    keys = VaultKeys(store: keychain, derive: deriveOnThisIsolate);
    await keys.add('correct horse battery');
    tag = await PasscodeTags(
      records: records,
      people: people,
      vaultKeys: keys,
      store: keychain,
    ).tagFor('1234');

    await records.upsert(
      localId: 'photo:open',
      contentHash: 'o',
      platform: 'ios',
    );
    await records.upsert(
      localId: 'photo:hid',
      contentHash: 'h',
      platform: 'ios',
    );
    await records.setDescription('photo:hid', _secretCaption);
    await records.recordUpload(
      localId: 'photo:hid',
      kind: DerivativeKind.original,
      targetId: 't1',
      destinationKey: _carrierKey,
    );
    await records.setPasscodeHash('photo:hid', tag);
    await records.putHiddenNote(
      id: 'n1',
      albumTag: 'album-tag',
      payload: 'sealed-payload',
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );
    final album = await albums.upsert(id: 'al', name: 'Trip');
    await albums.addAssets(album.id, ['photo:open', 'photo:hid']);
    final mia = await people.create(name: 'Mia', id: 'mia');
    await people.addAssets(mia.id, ['photo:open', 'photo:hid']);
  });

  tearDown(() async {
    await records.close();
    await albums.close();
    await people.close();
    await dir.delete(recursive: true);
  });

  test('the export holds no hidden row, tag, carrier key or code', () async {
    final snapshot = await io.export();
    final zip = utf8.decode(
      zipSnapshot(snapshot, changeLog: await io.changeLog()),
      allowMalformed: true,
    );
    final text = snapshot.encode() + jsonEncode(await io.changeLog());

    expect(snapshot.assets.map((a) => a['localId']), ['photo:open']);
    for (final leak in [
      'photo:hid',
      tag,
      hashPasscode('1234'),
      _carrierKey,
      _secretCaption,
      keychain.values[PasscodeTags.keyName]!,
    ]) {
      expect(text.contains(leak), isFalse, reason: 'leaks into the export');
      expect(zip.contains(leak), isFalse, reason: 'leaks into the zip');
    }
    expect(snapshot.albums.single['localIds'], ['photo:open']);
    expect(snapshot.people.single['localIds'], ['photo:open']);
    // What is already sealed goes, so a new phone keeps it.
    final vault = snapshot.vault;
    expect((vault['hiddenNotes'] as List).single['payload'], 'sealed-payload');
    expect(vault['tagEscrow'] as List, hasLength(1));
  });

  test('a deleted hidden photo leaves nothing in the change log', () async {
    final before = await records.changeMark();
    await records.remove('photo:hid');

    expect(await records.changeMark(), greaterThan(before));
    final log = jsonEncode(await records.changeLogRows());
    expect(log.contains('photo:hid'), isFalse);
    expect(log.contains(tag), isFalse);
    expect(log.contains(_secretCaption), isFalse);
  });

  test('an older log is purged of what it wrote about hidden rows', () async {
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    addTearDown(db.close);
    await db.execute(
      'CREATE TABLE t (id TEXT PRIMARY KEY, passcode_hash TEXT, note TEXT)',
    );
    await installChangeLog(db, const ['t']);
    await db.insert('t', {'id': 'a', 'note': 'before hiding'});
    await db.insert('t', {'id': 'b', 'note': 'open'});
    await db.update('t', {'passcode_hash': 'h'}, where: "id = 'a'");
    await db.delete('t', where: "id = 'a'");

    await purgePrivateEntries(db, 't', '{row}.passcode_hash IS NOT NULL');
    final rows = await changeLogTail(db);
    expect(rows.map((r) => r['row_key']), ['a', 'b'], reason: 'only plain');
    expect(jsonEncode(rows).contains('"h"'), isFalse);
  });

  test('database copies are compact and carry nothing hidden', () async {
    final out = await Directory(p.join(dir.path, 'copies')).create();
    expect(await io.copyDatabases(out.path, 'lead'), 3);

    final copy = File(p.join(out.path, 'lead-photos_vault.db'));
    final bytes = latin1.decode(await copy.readAsBytes());
    for (final leak in ['photo:hid', tag, _secretCaption, _carrierKey]) {
      expect(bytes.contains(leak), isFalse, reason: 'in the raw copy');
    }
    final opened = await databaseFactoryFfi.openDatabase(copy.path);
    addTearDown(opened.close);
    final ids = await opened.query('asset_record', columns: ['local_id']);
    expect(ids.map((r) => r['local_id']), ['photo:open']);
    final albumCopy = await databaseFactoryFfi.openDatabase(
      p.join(out.path, 'lead-photo_albums.db'),
    );
    addTearDown(albumCopy.close);
    final members = await albumCopy.query('album_asset');
    expect(members.map((r) => r['local_id']), ['photo:open']);
    expect(File('${copy.path}.part').existsSync(), isFalse);
  });

  test('the daily copy drops the bucket listing and old log, and still '
      'restores', () async {
    await records.replaceBucketObjects('t1', [
      BucketObject(
        targetId: 't1',
        key: 'p/originals/x.jpg',
        size: 1,
        lastModified: DateTime(2026),
      ),
    ]);
    final mark = await records.changeMark();
    final out = await Directory(p.join(dir.path, 'copies')).create();
    expect(await io.copyDatabases(out.path, 'daily', slim: true), 3);
    expect(await io.copyDatabases(out.path, 'pre'), 3);

    Future<int> count(String file, String table) async {
      final db = await databaseFactoryFfi.openDatabase(p.join(out.path, file));
      try {
        return (await db.rawQuery('SELECT COUNT(*) FROM $table'))
                .first
                .values
                .first!
            as int;
      } finally {
        await db.close();
      }
    }

    expect(await count('daily-photos_vault.db', 'bucket_object'), 0);
    expect(await count('pre-photos_vault.db', 'bucket_object'), 1);

    // A restore is a file swap: the copy opens as the library.
    final restored = AssetRecordStore(
      databaseFactory: databaseFactoryFfi,
      path: p.join(out.path, 'daily-photos_vault.db'),
    );
    addTearDown(restored.close);
    expect((await restored.listAll()).map((r) => r.localId), ['photo:open']);
    expect(await restored.changeMark(), mark, reason: 'the gate holds');
    expect(await restored.listBucketObjects(), isEmpty);
  });

  test('the zip log decodes the same off the UI isolate', () async {
    await records.setDescription('photo:open', 'changed');
    final raw = await io.rawChangeLog();
    expect((raw.assets.last['before'] as String), startsWith('{'));
    expect(jsonEncode(raw.open()), jsonEncode(await io.changeLog()));
    final assets = raw.open()['assets'] as List;
    expect((assets.last as Map)['after'], {'description': 'changed'});
  });

  test('an older export with a hidden row still restores and opens', () async {
    final old = AppSnapshot(
      version: 1,
      exportedAt: DateTime(2026, 9),
      assets: [
        {
          'localId': 'photo:old',
          'contentHash': 'x',
          'createdAt': DateTime(2020).toIso8601String(),
          'passcodeHash': hashPasscode('5555'),
        },
      ],
      albums: const [],
      people: const [],
    );
    final fresh = AssetRecordStore(
      databaseFactory: databaseFactoryFfi,
      path: p.join(dir.path, 'fresh.db'),
    );
    addTearDown(fresh.close);
    final restoring = AppSnapshotIo(
      assetRecordStore: fresh,
      albumStore: albums,
      personStore: people,
    );
    expect(await restoring.import(AppSnapshot.decode(old.encode())!), 1);

    final tagged = await PasscodeTags(
      records: fresh,
      people: people,
      vaultKeys: keys,
      store: keychain,
    ).tagFor('5555');
    expect((await fresh.forPasscodeHash(tagged)).single.localId, 'photo:old');
  });

  test('the escrow travels, so a new phone keeps its tags', () async {
    final snapshot = await io.export();
    final freshDir = await Directory.systemTemp.createTemp('pv_new_phone_');
    addTearDown(() => freshDir.delete(recursive: true));
    final fresh = AssetRecordStore(
      databaseFactory: databaseFactoryFfi,
      path: p.join(freshDir.path, 'photos_vault.db'),
    );
    final freshPeople = PersonStore(
      databaseFactory: databaseFactoryFfi,
      path: p.join(freshDir.path, 'people.db'),
    );
    addTearDown(fresh.close);
    addTearDown(freshPeople.close);
    await AppSnapshotIo(
      assetRecordStore: fresh,
      albumStore: albums,
      personStore: freshPeople,
    ).import(snapshot);
    // A sealed set kept under the old phone's tag, as an export carries it.
    await freshPeople.create(name: 'Mia', id: 'mia');
    await freshPeople.restoreSealedRows([
      {
        'table': 'person_detail',
        'person_id': 'mia',
        'passcode_hash': tag,
        'payload': 'x',
        'sealed': 1,
        'updated_at': 0,
      },
    ]);

    final newKeychain = _MemoryStore();
    final newKeys = VaultKeys(store: newKeychain, derive: deriveOnThisIsolate);
    await newKeys.unlockEntry(
      (await keys.entries()).single,
      'correct horse battery',
    );
    final again = await PasscodeTags(
      records: fresh,
      people: freshPeople,
      vaultKeys: newKeys,
      store: newKeychain,
    ).tagFor('1234');
    expect(again, tag);
    expect(await freshPeople.namespaces(), {tag});
  });
}
