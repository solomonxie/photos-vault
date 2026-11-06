import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:photos_vault/backup/app_snapshot.dart';
import 'package:photos_vault/photos/person.dart';
import 'package:photos_vault/photos/person_store.dart';
import 'package:photos_vault/storage/album_store.dart';
import 'package:photos_vault/storage/asset_record_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('pv_group_restore_'));
  tearDown(() => dir.deleteSync(recursive: true));

  ({PersonStore people, AppSnapshotIo io}) phone(String name) {
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
      people: people,
      io: AppSnapshotIo(
        assetRecordStore: records,
        albumStore: albums,
        personStore: people,
      ),
    );
  }

  test('groups and their dates survive a fresh-install restore', () async {
    final old = phone('old');
    final mia = await old.people.create(name: 'Mia', id: 'mia');
    final dan = await old.people.create(name: 'Dan', id: 'dan');
    final school = PersonGroup(
      id: 'g1',
      name: 'School',
      kind: GroupKind.school,
      start: DateTime(2010, 9, 1),
      end: DateTime(2014, 6, 30),
    );
    const club = PersonGroup(id: 'g2', name: 'Club', kind: GroupKind.circle);
    for (final id in [mia.id, dan.id]) {
      await old.people.joinGroup(id, school, scope: PersonScope.open);
    }
    await old.people.joinGroup(dan.id, club, scope: PersonScope.open);

    final before = await old.io.changeMark();
    await old.people.updateGroup(
      'g1',
      range: (start: DateTime(2010, 9, 1), end: DateTime(2014, 7, 1)),
    );
    expect(await old.io.changeMark(), greaterThan(before));

    final snapshot = AppSnapshot.decode((await old.io.export()).encode())!;
    final fresh = phone('new');
    expect(await fresh.io.isFreshInstall(), isTrue);
    await fresh.io.import(snapshot);

    final groups = await fresh.people.allGroups();
    final byId = {for (final g in groups.keys) g.id: g};
    expect(
      (byId['g1']!.name, byId['g1']!.kind, byId['g1']!.start, byId['g1']!.end),
      ('School', GroupKind.school, DateTime(2010, 9, 1), DateTime(2014, 7, 1)),
    );
    expect((byId['g2']!.start, byId['g2']!.end), (null, null));
    expect(
      {for (final e in groups.entries) e.key.id: e.value.toSet()},
      {
        'g1': {'mia', 'dan'},
        'g2': {'dan'},
      },
    );
  });
}
