import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/photos/person_owner.dart';
import 'package:photos_vault/photos/person_placement.dart';
import 'package:photos_vault/photos/person_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../support/fake_asset_record_store.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  late FakeAssetRecordStore records;
  late PersonStore people;
  late PersonPlacement placement;
  late String me;
  late String mia;

  setUp(() async {
    records = FakeAssetRecordStore();
    people = PersonStore(
      databaseFactory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    addTearDown(people.close);
    placement = PersonPlacement(records: records, people: people);
    me = (await people.create(name: 'Me')).id;
    mia = (await people.create(name: 'Mia')).id;
    await PersonOwner(records).set(me);
  });

  Future<void> add(
    String id, {
    bool archived = false,
    bool only = false,
    String? owner,
  }) => records.upsert(
    localId: id,
    contentHash: id,
    platform: 'ios',
    isArchived: archived,
    peopleOnly: only,
    ownerId: owner,
  );

  Future<({bool archived, String? owner})> state(String id) async {
    final r = (await records.getByLocalId(id))!;
    expect(r.peopleOnly, isFalse);
    return (archived: r.isArchived, owner: r.ownerId);
  }

  test('kept for someone else: tagged and theirs', () async {
    await add('a');
    await placement.keepFor(mia, ['a']);
    expect(await people.localIdsIn(mia), ['a']);
    expect(await state('a'), (archived: false, owner: mia));
    expect((await records.getByLocalId('a'))!.inLibraryViews, isFalse);
  });

  test('kept for the owner: tagged, and in the main library', () async {
    await add('a', owner: mia);
    await add('b', archived: true);
    await placement.keepFor(me, ['a', 'b']);
    expect(await people.localIdsIn(me), unorderedEquals(['a', 'b']));
    expect(await state('a'), (archived: false, owner: null));
    // The owner's archived photo stays archived.
    expect(await state('b'), (archived: true, owner: null));
  });

  test("restored from someone's hidden folder: theirs", () async {
    await add('a');
    await placement.restoreTo(mia, ['a']);
    expect(await people.localIdsIn(mia), ['a']);
    expect(await state('a'), (archived: false, owner: mia));
  });

  test("restored from the owner's folder: mine, untagged", () async {
    await add('a', owner: mia);
    await placement.restoreTo(me, ['a']);
    expect(await people.localIdsIn(me), isEmpty);
    expect(await state('a'), (archived: false, owner: null));
  });

  test('a merge hands every photo over; into the owner, mine', () async {
    final bob = (await people.create(name: 'Bob')).id;
    await add('a', owner: mia);
    await add('b', owner: mia);
    await placement.reassign(mia, bob);
    expect(await state('a'), (archived: false, owner: bob));
    await placement.reassign(bob, me);
    expect(await state('b'), (archived: false, owner: null));
  });

  test('old kept-for-someone photos get their one person, else mine', () async {
    final bob = (await people.create(name: 'Bob')).id;
    await add('one', archived: true, only: true);
    await add('two', archived: true, only: true);
    await add('none', archived: true, only: true);
    await people.addAssets(mia, ['one', 'two']);
    await people.addAssets(me, ['one']);
    await people.addAssets(bob, ['two']);
    await placement.convertLegacy(await records.listAll());
    expect(await state('one'), (archived: false, owner: mia));
    expect(await state('two'), (archived: false, owner: null));
    expect(await state('none'), (archived: false, owner: null));
  });
}
