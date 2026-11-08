import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:photos_vault/backup/app_snapshot.dart';
import 'package:photos_vault/photos/person_detail.dart';
import 'package:photos_vault/photos/person_store.dart';
import 'package:photos_vault/storage/album_store.dart';
import 'package:photos_vault/storage/asset_record_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('pv_person_tables_'));
  tearDown(() => dir.deleteSync(recursive: true));

  ({
    AssetRecordStore records,
    AlbumStore albums,
    PersonStore people,
    AppSnapshotIo io,
  })
  phone(String name) {
    final records = AssetRecordStore(
      databaseFactory: databaseFactoryFfi,
      path: p.join(dir.path, '$name-photos.db'),
    );
    final albums = AlbumStore(
      databaseFactory: databaseFactoryFfi,
      path: p.join(dir.path, '$name-albums.db'),
    );
    final people = PersonStore(
      databaseFactory: databaseFactoryFfi,
      path: p.join(dir.path, '$name-people.db'),
    );
    addTearDown(() async {
      await records.close();
      await albums.close();
      await people.close();
    });
    return (
      records: records,
      albums: albums,
      people: people,
      io: AppSnapshotIo(
        assetRecordStore: records,
        albumStore: albums,
        personStore: people,
      ),
    );
  }

  Future<AppSnapshot> roundTrip(AppSnapshotIo io) async =>
      AppSnapshot.decode((await io.export()).encode())!;

  test('events, name parts, aliases, face links and history come back '
      'on a fresh install', () async {
    final old = phone('old');
    for (final id in ['face', 'hand', 'secret']) {
      await old.records.upsert(
        localId: id,
        contentHash: id,
        platform: 'ios',
        passcodeHash: id == 'secret' ? 'tag' : null,
      );
    }
    final mia = await old.people.create(name: 'Mia', id: 'mia');
    await old.people.update(
      mia.copyWith(firstName: 'Mia', middleName: 'Jane', lastName: 'Wu'),
    );
    await old.people.create(name: 'Mimi', id: 'mimi');
    expect(await old.people.merge('mia', 'mimi'), PersonMergeOutcome.merged);
    await old.people.addAssets('mia', ['face'], viaFace: true);
    await old.people.addAssets('mia', ['hand', 'secret']);

    final before = await old.io.changeMark();
    final met = PersonEvent(
      id: 'e1',
      personId: 'mia',
      type: PersonEventType.firstMet,
      at: DateTime(2012, 9, 1),
    );
    await old.people.saveEvent(met, scope: PersonScope.open);
    expect(await old.io.changeMark(), greaterThan(before));
    await old.people.saveEvent(
      PersonEvent(
        id: 'e2',
        personId: 'mia',
        type: PersonEventType.lastSeen,
        at: DateTime(2026, 10, 3),
      ),
      scope: PersonScope.open,
    );
    await old.people.saveEvent(
      PersonEvent(
        id: 'e3',
        personId: 'mia',
        type: PersonEventType.trip,
        at: DateTime(2019, 4, 2),
        tags: const ['Kyoto'],
        notes: 'Spring',
      ),
      scope: PersonScope.open,
    );
    final history = await old.people.changesOf('mia');
    expect(history, isNotEmpty);

    final snapshot = await roundTrip(old.io);
    final fresh = phone('new');
    expect(await fresh.io.isFreshInstall(), isTrue);
    await fresh.io.import(snapshot);

    final events = await fresh.people.eventsFor('mia');
    expect(
      [for (final e in events) (e.id, e.type, e.at, e.tags.join(), e.notes)],
      [
        ('e1', PersonEventType.firstMet, DateTime(2012, 9, 1), '', ''),
        ('e3', PersonEventType.trip, DateTime(2019, 4, 2), 'Kyoto', 'Spring'),
        ('e2', PersonEventType.lastSeen, DateTime(2026, 10, 3), '', ''),
      ],
    );
    final restored = (await fresh.people.getById('mia'))!;
    expect(
      (restored.firstName, restored.middleName, restored.lastName),
      ('Mia', 'Jane', 'Wu'),
    );
    expect(await fresh.people.aliasesOf('mia'), ['mimi']);
    expect(await fresh.people.allAliasIds(), {'mimi'});

    // History as it was, without the restore's own writes or the hidden
    // photo's id.
    final restoredHistory = await fresh.people.changesOf('mia');
    String line(PersonChange c) =>
        '${c.at.millisecondsSinceEpoch} ${c.kind} ${c.before} ${c.after}';
    expect(restoredHistory.map(line), [
      for (final c in history)
        if (c.after != 'secret') line(c),
    ]);

    // The face's link goes with the face; the hand-added one stays.
    await fresh.people.removeFaceTags('mia', ['face', 'hand']);
    expect(await fresh.people.localIdsIn('mia'), unorderedEquals(['hand']));
  });

  test('a second import neither duplicates nor replaces newer work', () async {
    final old = phone('old');
    await old.people.create(name: 'Mia', id: 'mia');
    await old.people.saveEvent(
      PersonEvent(
        id: 'e1',
        personId: 'mia',
        type: PersonEventType.firstMet,
        at: DateTime(2012, 9, 1),
      ),
      scope: PersonScope.open,
    );
    final snapshot = await roundTrip(old.io);

    final fresh = phone('new');
    await fresh.io.import(snapshot);
    final edited = PersonEvent(
      id: 'e1',
      personId: 'mia',
      type: PersonEventType.firstMet,
      at: DateTime(2013, 1, 1),
    );
    await fresh.people.saveEvent(edited, scope: PersonScope.open);
    final history = (await fresh.people.changesOf('mia')).length;

    await fresh.io.import(snapshot);
    final events = await fresh.people.eventsFor('mia');
    expect([for (final e in events) e.at], [DateTime(2013, 1, 1)]);
    expect((await fresh.people.changesOf('mia')).length, history);
  });

  test('album notes, tags and cover, and locked photos come back', () async {
    final old = phone('old');
    for (final id in ['a', 'b']) {
      await old.records.upsert(localId: id, contentHash: id, platform: 'ios');
    }
    await old.records.setLocked('a', true);
    final album = await old.albums.upsert(id: 'kyoto', name: 'Kyoto');
    await old.albums.addAssets('kyoto', ['a', 'b']);
    final before = await old.io.changeMark();
    await old.albums.update(
      album.copyWith(
        description: 'October trip',
        tags: ['travel', 'japan'],
        coverLocalId: 'b',
      ),
    );
    expect(await old.io.changeMark(), greaterThan(before));

    final snapshot = await roundTrip(old.io);
    final fresh = phone('new');
    expect(await fresh.io.isFreshInstall(), isTrue);
    await fresh.io.import(snapshot);

    final restored = (await fresh.albums.getById('kyoto'))!;
    expect(
      (restored.description, restored.tags.join(','), restored.coverLocalId),
      ('October trip', 'travel,japan', 'b'),
    );
    expect((await fresh.records.getByLocalId('a'))!.isLocked, isTrue);
    expect((await fresh.records.getByLocalId('b'))!.isLocked, isFalse);
  });
}
