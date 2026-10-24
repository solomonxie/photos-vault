import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/photos/person.dart';
import 'package:photos_vault/photos/person_detail.dart';
import 'package:photos_vault/photos/person_store.dart';
import 'package:photos_vault/storage/passcode_hash.dart';
import 'package:photos_vault/vault/keys.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

AlbumKeys _keysFor(String passcode) => AlbumKeys(
  albumKey: Uint8List.fromList(
    List.generate(32, (i) => (i * passcode.hashCode + 7) % 256),
  ),
  entry: PassphraseEntry(
    id: 'entry',
    salt: Uint8List(16),
    verifier: Uint8List(32),
    hint: '',
  ),
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

  List<String> kinds(List<PersonChange> changes) => [
    for (final c in changes) c.kind,
  ];

  test('a name typed letter by letter is one change, old to new', () async {
    final store = newStore();
    var mia = await store.create(name: 'Mi');
    for (final name in ['Mia', 'Mia W', 'Mia Wu']) {
      mia = mia.copyWith(name: name);
      await store.update(mia);
    }
    final changes = await store.changesOf(mia.id);
    expect(kinds(changes), ['name', 'created']);
    expect(changes.first.before, 'Mi');
    expect(changes.first.after, 'Mia Wu');
    expect(await store.formerNames(mia.id), ['Mi']);
  });

  test('photos, details, groups, events, places, background and links are '
      'all logged', () async {
    final store = newStore();
    final mia = await store.create(name: 'Mia');
    final sam = await store.create(name: 'Sam');
    await store.addAssets(mia.id, ['p1', 'p2']);
    await store.removeAsset(mia.id, 'p1');
    await store.saveDetail(
      mia.id,
      const PersonDetail(bio: 'Climbs'),
      scope: PersonScope.open,
    );
    const club = PersonGroup(id: 'g', name: 'Club', kind: GroupKind.circle);
    await store.joinGroup(mia.id, club, scope: PersonScope.open);
    await store.saveEvent(
      PersonEvent(
        id: 'e',
        personId: mia.id,
        type: PersonEventType.trip,
        at: DateTime(2020),
      ),
      scope: PersonScope.open,
    );
    await store.addLocation(
      PersonLocation(
        id: 'l',
        personId: mia.id,
        kind: LocationKind.origin,
        place: 'Leeds',
        since: DateTime(1990),
      ),
      scope: PersonScope.open,
    );
    await store.addHistoryEntry(
      PersonHistoryEntry(
        id: 'h',
        personId: mia.id,
        category: HistoryCategory.job,
        title: 'Acme',
      ),
      scope: PersonScope.open,
    );
    await store.addRelationship(
      mia.id,
      sam.id,
      RelationshipType.friend,
      scope: PersonScope.open,
    );

    final logged = kinds(await store.changesOf(mia.id)).toSet();
    expect(
      logged,
      containsAll([
        'created',
        'photo_added',
        'photo_removed',
        'details',
        'group_joined',
        'event_added',
        'place_added',
        'background_added',
        'link_added',
      ]),
    );
  });

  test('nothing under a code is logged', () async {
    final store = newStore();
    final mia = await store.create(name: 'Mia');
    final sealed = PersonScope.sealed(hashPasscode('x'), _keysFor('1111'));
    await store.saveDetail(
      mia.id,
      const PersonDetail(bio: 'secret'),
      scope: sealed,
    );
    await store.saveEvent(
      PersonEvent(
        id: 'e',
        personId: mia.id,
        type: PersonEventType.trip,
        at: DateTime(2020),
      ),
      scope: sealed,
    );
    expect(kinds(await store.changesOf(mia.id)), ['created']);
  });

  test("a merge brings the other's history and names, without a flood "
      'of moved rows', () async {
    final store = newStore();
    final keep = await store.create(name: 'Mia');
    var gone = await store.create(name: 'M. Chen');
    gone = gone.copyWith(name: 'Mia Chen');
    await store.update(gone);
    await store.addAssets(gone.id, ['g1', 'g2', 'g3']);

    await store.merge(keep.id, gone.id);

    final changes = await store.changesOf(keep.id);
    expect(changes.first.kind, 'merged');
    expect(changes.first.before, 'Mia Chen');
    expect(
      kinds(changes).where((k) => k == 'photo_added'),
      hasLength(3),
      reason: 'their own adds, not one per moved row',
    );
    expect(kinds(changes).where((k) => k == 'photo_removed'), isEmpty);
    expect(await store.changesOf(gone.id), isEmpty);
    expect(await store.formerNames(keep.id), ['M. Chen', 'Mia Chen']);
  });

  test('Last seen only ever moves forward', () async {
    final store = newStore();
    final mia = await store.create(name: 'Mia');
    await store.markSeen(mia.id, DateTime(2020));
    await store.markSeen(mia.id, DateTime(2010));
    var events = await store.eventsFor(mia.id);
    expect(events.where((e) => e.isLastSeen).single.at, DateTime(2020));
    await store.markSeen(mia.id, DateTime(2024));
    events = await store.eventsFor(mia.id);
    expect(events.where((e) => e.isLastSeen).single.at, DateTime(2024));
  });

  test('First met only ever moves back', () async {
    final store = newStore();
    final mia = await store.create(name: 'Mia');
    await store.markMet(mia.id, DateTime(2020));
    await store.markMet(mia.id, DateTime(2024));
    var events = await store.eventsFor(mia.id);
    expect(events.where((e) => e.isFirstMet).single.at, DateTime(2020));
    await store.markMet(mia.id, DateTime(2010));
    events = await store.eventsFor(mia.id);
    expect(events.where((e) => e.isFirstMet).single.at, DateTime(2010));
  });

  test('deleting a person deletes their history', () async {
    final store = newStore();
    final mia = await store.create(name: 'Mia');
    await store.update(mia.copyWith(name: 'Mia Wu'));
    await store.remove(mia.id);
    expect(await store.changesOf(mia.id), isEmpty);
  });
}
