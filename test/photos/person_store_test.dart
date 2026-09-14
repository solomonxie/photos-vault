import 'package:back_your_own_photos/photos/person.dart';
import 'package:back_your_own_photos/photos/person_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  PersonStore newStore() {
    final store = PersonStore(databaseFactory: databaseFactoryFfi, path: inMemoryDatabasePath);
    addTearDown(store.close);
    return store;
  }

  test('create with a fixed id is idempotent, same trick as demo albums', () async {
    final store = newStore();

    final first = await store.create(name: 'Mia', id: 'demo-mia', isDemo: true);
    final second = await store.create(name: 'Renamed', id: 'demo-mia');

    expect(second.name, first.name);
    expect(await store.listAll(), hasLength(1));
  });

  test('update persists profile field edits', () async {
    final store = newStore();
    final person = await store.create(name: 'Mia');

    await store.update(person.copyWith(education: 'MIT', job: 'Engineer'));

    final reloaded = await store.getById(person.id);
    expect(reloaded!.education, 'MIT');
    expect(reloaded.job, 'Engineer');
  });

  test('addAssets / localIdsIn track tagged photos, ignoring duplicates', () async {
    final store = newStore();
    final person = await store.create(name: 'Mia');

    await store.addAssets(person.id, ['p1', 'p2']);
    await store.addAssets(person.id, ['p2', 'p3']);

    expect(await store.localIdsIn(person.id), unorderedEquals(['p1', 'p2', 'p3']));
  });

  test('addRelationship stores both directions, inverting parent/child', () async {
    final store = newStore();
    final parent = await store.create(name: 'Parent');
    final child = await store.create(name: 'Child');

    await store.addRelationship(parent.id, child.id, RelationshipType.parent);

    final fromParent = await store.relationshipsFor(parent.id);
    final fromChild = await store.relationshipsFor(child.id);
    expect(fromParent.single.type, RelationshipType.parent);
    expect(fromChild.single.type, RelationshipType.child);
  });

  test('addRelationship mirrors symmetric types as-is', () async {
    final store = newStore();
    final a = await store.create(name: 'A');
    final b = await store.create(name: 'B');

    await store.addRelationship(a.id, b.id, RelationshipType.friend);

    expect((await store.relationshipsFor(b.id)).single.type, RelationshipType.friend);
  });

  test('removeRelationship drops both directions', () async {
    final store = newStore();
    final a = await store.create(name: 'A');
    final b = await store.create(name: 'B');
    await store.addRelationship(a.id, b.id, RelationshipType.friend);

    await store.removeRelationship(a.id, b.id);

    expect(await store.relationshipsFor(a.id), isEmpty);
    expect(await store.relationshipsFor(b.id), isEmpty);
  });

  test('location history is ordered by since date', () async {
    final store = newStore();
    final person = await store.create(name: 'Mia');
    await store.addLocation(
      PersonLocation(id: 'l2', personId: person.id, kind: LocationKind.relocation, place: 'Vancouver', since: DateTime(2020)),
    );
    await store.addLocation(
      PersonLocation(id: 'l1', personId: person.id, kind: LocationKind.origin, place: 'Guangzhou', since: DateTime(1990)),
    );

    final locations = await store.locationsFor(person.id);

    expect(locations.map((l) => l.place), ['Guangzhou', 'Vancouver']);
  });

  test('addRelationship stores an organization, shared by both directions', () async {
    final store = newStore();
    final a = await store.create(name: 'A');
    final b = await store.create(name: 'B');

    await store.addRelationship(a.id, b.id, RelationshipType.colleague, organization: 'Acme Corp');

    expect((await store.relationshipsFor(a.id)).single.organization, 'Acme Corp');
    expect((await store.relationshipsFor(b.id)).single.organization, 'Acme Corp');
  });

  test('allOrganizations returns distinct, non-empty organizations across all relationships', () async {
    final store = newStore();
    final a = await store.create(name: 'A');
    final b = await store.create(name: 'B');
    final c = await store.create(name: 'C');
    await store.addRelationship(a.id, b.id, RelationshipType.colleague, organization: 'Acme Corp');
    await store.addRelationship(a.id, c.id, RelationshipType.friend);

    expect(await store.allOrganizations(), {'Acme Corp'});
  });

  test('remove deletes the person, their memberships, relationships, and locations', () async {
    final store = newStore();
    final a = await store.create(name: 'A');
    final b = await store.create(name: 'B');
    await store.addAssets(a.id, ['p1']);
    await store.addRelationship(a.id, b.id, RelationshipType.friend);
    await store.addLocation(PersonLocation(id: 'l1', personId: a.id, kind: LocationKind.origin, place: 'X', since: DateTime(2000)));

    await store.remove(a.id);

    expect(await store.getById(a.id), isNull);
    expect(await store.localIdsIn(a.id), isEmpty);
    expect(await store.relationshipsFor(b.id), isEmpty);
    expect(await store.locationsFor(a.id), isEmpty);
  });
}
