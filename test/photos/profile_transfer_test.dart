import 'package:flutter_test/flutter_test.dart';
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
    );
    await store.joinGroup(
      mia.id,
      const PersonGroup(id: 'g1', name: 'Acme Ltd', kind: GroupKind.company),
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
    );
    await store.addLocation(
      PersonLocation(
        id: 'l1',
        personId: mia.id,
        kind: LocationKind.origin,
        place: 'Kyoto',
        since: DateTime(2015),
      ),
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
}
