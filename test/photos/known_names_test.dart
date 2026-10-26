import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/backup/app_snapshot.dart';
import 'package:photos_vault/photos/known_names.dart';
import 'package:photos_vault/photos/person.dart';
import 'package:photos_vault/photos/person_store.dart';
import 'package:photos_vault/viewer/import_name_choice.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../support/fake_album_store.dart';
import '../support/fake_asset_record_store.dart';
import '../support/fake_person_store.dart';

Person _p(String id, String name) => Person(
  id: id,
  name: name,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
);

void main() {
  setUpAll(sqfliteFfiInit);

  PersonStore newStore() {
    final store = PersonStore(
      databaseFactory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    addTearDown(store.close);
    return store;
  }

  test('a remembered handle or name finds them; a handle wins', () {
    final mia = _p('1', 'Mia Chen'), zoe = _p('2', 'Zoe');
    final known = KnownNames(
      [mia, zoe],
      known: const [
        KnownAs(personId: '1', kind: KnownAs.name, value: '  mia   C. '),
        KnownAs(personId: '2', kind: KnownAs.handle, value: 'wechat:WXID_9'),
      ],
      former: const {
        '2': ['Zoey'],
      },
    );
    expect(known.remembered('Mia c.'), mia);
    expect(known.remembered('zoey'), zoe);
    expect(known.remembered('Mia C.', ['wechat:wxid_9']), zoe);
    expect(known.remembered('Nobody'), isNull);
    expect(importCandidates('mia c.', [mia, zoe], known: known), [mia]);
    expect(importCandidates('Zoe', [mia, zoe], known: known, handles: ['x']), [
      zoe,
    ]);
  });

  test('remembered once each, never their own name; merge and delete '
      'carry them, and the change mark moves', () async {
    final store = newStore();
    final mia = await store.create(name: 'Mia');
    final other = await store.create(name: 'M');
    final mark = await store.changeMark();
    await store.rememberKnownAs([
      KnownAs(personId: mia.id, kind: KnownAs.name, value: 'mia'),
      KnownAs(personId: mia.id, kind: KnownAs.name, value: 'Mia Chen'),
      KnownAs(personId: mia.id, kind: KnownAs.name, value: ' MIA  chen'),
      KnownAs(personId: mia.id, kind: KnownAs.handle, value: 'sms:+1555'),
      KnownAs(personId: other.id, kind: KnownAs.handle, value: 'qq:1'),
    ]);
    expect(await store.changeMark(), greaterThan(mark));
    expect(
      [for (final k in await store.knownAsOf(mia.id)) k.value],
      ['Mia Chen', 'sms:+1555'],
    );

    await store.merge(mia.id, other.id);
    expect(
      [for (final k in await store.knownAsOf(mia.id)) k.value],
      ['Mia Chen', 'sms:+1555', 'qq:1'],
    );
    final names = await store.knownNames(await store.listAll());
    expect(names.remembered('anything', ['QQ:1'])?.id, mia.id);
    expect(names.remembered('M')?.id, mia.id, reason: 'merged-in name');

    await store.forgetKnownAs(
      KnownAs(personId: mia.id, kind: KnownAs.handle, value: 'qq:1'),
    );
    expect(await store.knownAsOf(mia.id), hasLength(2));
    await store.remove(mia.id);
    expect(await store.allKnownAs(), isEmpty);
  });

  test('backed up, and back on a fresh restore', () async {
    final people = FakePersonStore();
    final mia = await people.create(name: 'Mia');
    await people.rememberKnownAs([
      KnownAs(personId: mia.id, kind: KnownAs.name, value: 'Mia C.'),
      KnownAs(personId: mia.id, kind: KnownAs.handle, value: 'wechat:wxid_1'),
    ]);
    final snapshot = await AppSnapshotIo(
      assetRecordStore: FakeAssetRecordStore(),
      albumStore: FakeAlbumStore(),
      personStore: people,
    ).export();

    final restored = FakePersonStore();
    await AppSnapshotIo(
      assetRecordStore: FakeAssetRecordStore(),
      albumStore: FakeAlbumStore(),
      personStore: restored,
    ).import(AppSnapshot.decode(snapshot.encode())!);
    final back = (await restored.listAll()).single;
    expect(
      [for (final k in await restored.knownAsOf(back.id)) (k.kind, k.value)],
      [(KnownAs.name, 'Mia C.'), (KnownAs.handle, 'wechat:wxid_1')],
    );
  });
}
