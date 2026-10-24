import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/photos/person_store.dart';
import 'package:photos_vault/photos/person.dart';
import 'package:photos_vault/photos/person_detail.dart';
import 'package:photos_vault/photos/profile_csv.dart';
import 'package:photos_vault/photos/profile_transfer.dart';

import '../support/fake_person_store.dart';

void main() {
  test('exports what a profile holds', () async {
    final store = FakePersonStore();
    final mia = await store.create(name: 'Mia');
    await store.saveDetail(
      mia.id,
      PersonDetail(
        bio: 'Photographer',
        birthDate: DateTime(1990, 6, 14),
        gender: Gender.female,
        traits: const {'hair': 'black', 'eyes': ''},
        customFields: const [PersonCustomField(label: 'Phone', value: '0700')],
        impression: const PersonImpression(tags: ['organised']),
      ),
      scope: PersonScope.open,
    );
    await store.joinGroup(
      mia.id,
      const PersonGroup(id: 'g1', name: 'Acme Ltd', kind: GroupKind.company),
      scope: PersonScope.open,
    );
    await store.addHistoryEntry(
      PersonHistoryEntry(
        id: 'h1',
        personId: mia.id,
        category: HistoryCategory.job,
        title: 'Acme Ltd',
        notes: 'Engineer',
        startDate: DateTime(2015),
      ),
      scope: PersonScope.open,
    );
    await store.addLocation(
      PersonLocation(
        id: 'l1',
        personId: mia.id,
        kind: LocationKind.origin,
        place: 'Kyoto',
        since: DateTime(2015),
      ),
      scope: PersonScope.open,
    );

    final rows = await ProfileTransfer(store: store).read();

    final row = rows.single;
    expect(row.name, 'Mia');
    expect(row.bio, 'Photographer');
    // An empty trait is not a column worth filling.
    expect(row.traits, {'hair': 'black'});
    expect(row.groups.single.name, 'Acme Ltd');
    expect(row.jobs.single.detail, 'Engineer');
    expect(row.places, ['Kyoto']);
    expect(row.tags, ['organised']);
  });

  test('imports a new person and matches an existing one by name', () async {
    final store = FakePersonStore();
    await store.create(name: 'Mia');

    final result = await ProfileTransfer(store: store).write([
      const ProfileCsvRow(name: 'mia', bio: 'Photographer'),
      const ProfileCsvRow(name: 'Daniel', bio: 'Cellist'),
    ]);

    expect(result.created, 1);
    expect(result.updated, 1);
    final people = await store.listAll();
    expect(people.map((p) => p.name), ['Mia', 'Daniel']);
    final mia = people.first;
    expect((await store.detailFor(mia.id)).bio, 'Photographer');
  });

  test('a blank cell leaves what is already there alone', () async {
    final store = FakePersonStore();
    final mia = await store.create(name: 'Mia');
    await store.saveDetail(
      mia.id,
      PersonDetail(bio: 'Photographer', birthDate: DateTime(1990)),
      scope: PersonScope.open,
    );

    await ProfileTransfer(store: store).write([
      const ProfileCsvRow(name: 'Mia', traits: {'hair': 'black'}),
    ]);

    final detail = await store.detailFor(mia.id);
    expect(detail.bio, 'Photographer');
    expect(detail.birthDate, DateTime(1990));
    expect(detail.traits, {'hair': 'black'});
  });

  test('importing the same file twice adds nothing the second time', () async {
    final store = FakePersonStore();
    const rows = [
      ProfileCsvRow(
        name: 'Mia',
        fields: [PersonCustomField(label: 'Phone', value: '0700')],
        groups: [ProfileCsvGroup('Acme Ltd', GroupKind.company)],
        jobs: [ProfileCsvHistory(title: 'Acme Ltd', detail: 'Engineer')],
        places: ['Kyoto'],
        tags: ['organised'],
      ),
    ];
    final transfer = ProfileTransfer(store: store);

    await transfer.write(rows);
    final second = await transfer.write(rows);

    expect(second.created, 0);
    expect(second.updated, 1);
    final mia = (await store.listAll()).single;
    expect(await store.groupsFor(mia.id), hasLength(1));
    expect(await store.historyFor(mia.id, HistoryCategory.job), hasLength(1));
    expect(await store.locationsFor(mia.id), hasLength(1));
    final detail = await store.detailFor(mia.id);
    expect(detail.customFields, hasLength(1));
    expect(detail.impression.tags, ['organised']);
  });

  test('a shared name goes where it was pointed, or to a new person', () async {
    final store = FakePersonStore();
    final first = await store.create(name: 'Li Xia');
    final second = await store.create(name: 'li xia ');
    final matches = PersonMatches(await store.listAll());
    expect(matches.ambiguous('LI XIA'), isTrue);
    expect(matches.ambiguous('Mia'), isFalse);

    final result = await ProfileTransfer(store: store).write(
      const [
        ProfileCsvRow(name: 'Li Xia', bio: 'first'),
        ProfileCsvRow(name: 'Li Xia', bio: 'third'),
      ],
      targets: [PersonTarget(first.id), const PersonTarget.newPerson()],
    );

    expect(result.personIds.first, first.id);
    expect(result.personIds.last, isNot(anyOf(first.id, second.id)));
    expect((result.created, result.updated), (1, 1));
    expect((await store.detailFor(first.id)).bio, 'first');
    expect((await store.detailFor(second.id)).bio, isEmpty);
    expect(await store.listAll(), hasLength(3));
  });

  test(
    'first met and last seen round-trip, and a file only widens them',
    () async {
      final store = FakePersonStore();
      final transfer = ProfileTransfer(store: store);
      await transfer.write([
        ProfileCsvRow(
          name: 'Mia',
          firstMet: DateTime(2010),
          lastSeen: DateTime(2015),
        ),
      ]);
      await transfer.write([
        ProfileCsvRow(
          name: 'Mia',
          firstMet: DateTime(2012),
          lastSeen: DateTime(2018),
        ),
      ]);
      final row = (await transfer.read()).single;
      expect(row.firstMet, DateTime(2010));
      expect(row.lastSeen, DateTime(2018));
      final again = readProfileCsv(writeProfileCsv([row])).rows.single;
      expect(
        (again.firstMet, again.lastSeen),
        (DateTime(2010), DateTime(2018)),
      );
    },
  );

  test('rows naming one group join one group, and one already here', () async {
    final store = FakePersonStore();
    final zoe = await store.create(name: 'Zoe');
    const club = PersonGroup(id: 'g1', name: 'Club', kind: GroupKind.circle);
    await store.joinGroup(zoe.id, club, scope: PersonScope.open);

    await ProfileTransfer(store: store).write(const [
      ProfileCsvRow(
        name: 'Mia',
        groups: [ProfileCsvGroup('Club', GroupKind.circle)],
      ),
      ProfileCsvRow(
        name: 'Leo',
        groups: [ProfileCsvGroup('club', GroupKind.circle)],
      ),
      ProfileCsvRow(
        name: 'Ann',
        groups: [ProfileCsvGroup('Choir', GroupKind.circle)],
      ),
      ProfileCsvRow(
        name: 'Bob',
        groups: [ProfileCsvGroup('Choir', GroupKind.circle)],
      ),
    ]);

    final groups = await store.allGroups();
    expect(groups, hasLength(2));
    final byName = {for (final e in groups.entries) e.key.name: e.value};
    expect(byName['Club'], hasLength(3));
    expect(byName['Choir'], hasLength(2));
  });

  group('a row\'s mode', () {
    Future<(FakePersonStore, String)> seeded() async {
      final store = FakePersonStore();
      final mia = await store.create(name: 'Mia');
      await store.saveDetail(
        mia.id,
        PersonDetail(
          bio: 'Old bio',
          birthDate: DateTime(1990),
          customFields: const [
            PersonCustomField(label: 'Phone', value: '111'),
            PersonCustomField(label: 'Email', value: 'a@b.c'),
          ],
        ),
        scope: PersonScope.open,
      );
      await store.joinGroup(
        mia.id,
        const PersonGroup(id: 'g', name: 'QQ group X', kind: GroupKind.circle),
        scope: PersonScope.open,
      );
      return (store, mia.id);
    }

    const row = ProfileCsvRow(
      name: 'Mia',
      bio: 'New bio',
      fields: [PersonCustomField(label: 'Phone', value: '222')],
    );

    test('all makes the profile the row', () async {
      final (store, id) = await seeded();
      await ProfileTransfer(store: store).write([
        ProfileCsvRow(
          name: row.name,
          bio: row.bio,
          fields: row.fields,
          mode: ProfileCsvMode.all,
        ),
      ]);
      final detail = await store.detailFor(id);
      expect(detail.bio, 'New bio');
      expect(detail.birthDate, isNull);
      expect([for (final f in detail.customFields) f.value], ['222']);
      expect(await store.groupsFor(id), isEmpty);
    });

    test('conflict lets the row win and removes nothing', () async {
      final (store, id) = await seeded();
      await ProfileTransfer(store: store).write([
        ProfileCsvRow(
          name: row.name,
          bio: row.bio,
          fields: row.fields,
          mode: ProfileCsvMode.conflict,
        ),
      ]);
      final detail = await store.detailFor(id);
      expect(detail.bio, 'New bio');
      expect(detail.birthDate, DateTime(1990));
      expect([for (final f in detail.customFields) f.value], ['222', 'a@b.c']);
      expect(await store.groupsFor(id), hasLength(1));
    });

    test('skip keeps what is here', () async {
      final (store, id) = await seeded();
      await ProfileTransfer(store: store).write([
        ProfileCsvRow(
          name: row.name,
          bio: row.bio,
          fields: row.fields,
          mode: ProfileCsvMode.skip,
        ),
      ]);
      final detail = await store.detailFor(id);
      expect(detail.bio, 'Old bio');
      expect([for (final f in detail.customFields) f.value], ['111', 'a@b.c']);
    });

    test('is read and written as a column', () {
      final text = writeProfileCsv([
        const ProfileCsvRow(name: 'Mia', mode: ProfileCsvMode.all),
      ]);
      expect(readProfileCsv(text).rows.single.mode, ProfileCsvMode.all);
      expect(
        readProfileCsv('name,mode\nLeo,Override\n').rows.single.mode,
        ProfileCsvMode.conflict,
      );
    });
  });
}
