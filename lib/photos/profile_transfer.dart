/// Profiles out to a spreadsheet and back in again.
///
/// The read and write of the file itself is `profile_csv.dart`; this is the
/// part that touches the store, kept out of the screen so the rules about
/// what an import overwrites can be tested without a widget.
library;

import 'person.dart';
import 'person_detail.dart';
import 'person_store.dart';
import 'profile_csv.dart';
import '../vault/keys.dart';

/// What an import did. Nothing is ever deleted by one, so there are only two
/// numbers: people who did not exist, and people who did.
class ProfileImportResult {
  const ProfileImportResult({this.created = 0, this.updated = 0});

  final int created;
  final int updated;

  int get total => created + updated;
}

class ProfileTransfer {
  ProfileTransfer({
    required this.store,
    this.passcodeHash = openNamespace,
    this.keys,
  });

  final PersonStore store;

  /// Which set this reads and writes. The open one, from the library page —
  /// a profile kept under a passcode is not in the file, and an import does
  /// not reach it. See [PersonDetail].
  final String passcodeHash;
  final AlbumKeys? keys;

  /// Everybody in this set, as rows, in the order the People list shows them.
  Future<List<ProfileCsvRow>> read() async {
    final people = await store.listAll();
    final rows = <ProfileCsvRow>[];
    for (final person in people) {
      final detail = await _detail(person.id);
      rows.add(
        ProfileCsvRow(
          name: person.name,
          birthDate: detail.birthDate,
          gender: detail.gender,
          bio: detail.bio,
          traits: {
            for (final entry in detail.traits.entries)
              if (entry.value.trim().isNotEmpty) entry.key: entry.value,
          },
          fields: detail.customFields,
          groups: [
            for (final group in await _groups(person.id))
              ProfileCsvGroup(group.name, group.kind),
          ],
          education: await _history(person.id, HistoryCategory.education),
          jobs: await _history(person.id, HistoryCategory.job),
          places: [for (final at in await _locations(person.id)) at.place],
          tags: detail.impression.tags,
        ),
      );
    }
    return rows;
  }

  /// Writes [rows], matching people by name.
  ///
  /// A blank cell leaves what is already there alone: a spreadsheet with
  /// four columns filled in is somebody adding phone numbers, not somebody
  /// asking for every bio to be erased. Lists are merged rather than
  /// replaced, so importing the same file twice adds nothing the second
  /// time — which is what makes a round trip safe to repeat.
  Future<ProfileImportResult> write(Iterable<ProfileCsvRow> rows) async {
    final existing = {
      for (final person in await store.listAll())
        person.name.trim().toLowerCase(): person,
    };
    var created = 0;
    var updated = 0;
    for (final row in rows) {
      final key = row.name.trim().toLowerCase();
      final match = existing[key];
      final person = match ?? await store.create(name: row.name.trim());
      if (match == null) {
        existing[key] = person;
        created++;
      } else {
        updated++;
      }
      await _writeDetail(person.id, row);
      await _writeGroups(person.id, row);
      await _writeHistory(person.id, HistoryCategory.education, row.education);
      await _writeHistory(person.id, HistoryCategory.job, row.jobs);
      await _writePlaces(person.id, row);
    }
    return ProfileImportResult(created: created, updated: updated);
  }

  Future<void> _writeDetail(String personId, ProfileCsvRow row) async {
    final before = await _detail(personId);
    final labels = {
      for (final field in before.customFields) field.label.toLowerCase(),
    };
    final after = before.copyWith(
      bio: row.bio.isEmpty ? null : row.bio,
      birthDate: row.birthDate == null ? null : () => row.birthDate,
      gender: row.gender == null ? null : () => row.gender,
      traits: {...before.traits, ...row.traits},
      customFields: [
        ...before.customFields,
        // `labels.add` as the filter, so a cell naming the same field twice
        // adds it once.
        for (final field in row.fields)
          if (labels.add(field.label.toLowerCase())) field,
      ],
      impression: before.impression.copyWith(
        tags: {...before.impression.tags, ...row.tags}.toList(),
      ),
    );
    await store.saveDetail(
      personId,
      after,
      passcodeHash: passcodeHash,
      keys: keys,
    );
  }

  Future<void> _writeGroups(String personId, ProfileCsvRow row) async {
    final already = {
      for (final group in await _groups(personId)) group.name.toLowerCase(),
    };
    for (final group in row.groups) {
      if (!already.add(group.name.toLowerCase())) continue;
      await store.joinGroup(
        personId,
        PersonGroup(id: store.newId(), name: group.name, kind: group.kind),
        passcodeHash: passcodeHash,
        keys: keys,
      );
    }
  }

  Future<void> _writeHistory(
    String personId,
    HistoryCategory category,
    List<ProfileCsvHistory> entries,
  ) async {
    final already = {
      for (final entry in await _history(personId, category))
        entry.title.toLowerCase(),
    };
    for (final entry in entries) {
      if (!already.add(entry.title.toLowerCase())) continue;
      await store.addHistoryEntry(
        PersonHistoryEntry(
          id: store.newId(),
          personId: personId,
          category: category,
          title: entry.title,
          startDate: entry.start,
          endDate: entry.end,
          notes: entry.detail,
        ),
        passcodeHash: passcodeHash,
        keys: keys,
      );
    }
  }

  Future<void> _writePlaces(String personId, ProfileCsvRow row) async {
    final already = {
      for (final at in await _locations(personId)) at.place.toLowerCase(),
    };
    for (final place in row.places) {
      if (!already.add(place.toLowerCase())) continue;
      await store.addLocation(
        PersonLocation(
          id: store.newId(),
          personId: personId,
          // Nothing in a column says whether somebody was born there or
          // moved there, and a guess would be a claim. Relocation is the
          // one that says only "they were here".
          kind: LocationKind.relocation,
          place: place,
          since: DateTime.now(),
        ),
        passcodeHash: passcodeHash,
        keys: keys,
      );
    }
  }

  Future<PersonDetail> _detail(String personId) =>
      store.detailFor(personId, passcodeHash: passcodeHash, keys: keys);

  Future<List<PersonGroup>> _groups(String personId) =>
      store.groupsFor(personId, passcodeHash: passcodeHash, keys: keys);

  Future<List<PersonLocation>> _locations(String personId) =>
      store.locationsFor(personId, passcodeHash: passcodeHash, keys: keys);

  Future<List<ProfileCsvHistory>> _history(
    String personId,
    HistoryCategory category,
  ) async => [
    for (final entry in await store.historyFor(
      personId,
      category,
      passcodeHash: passcodeHash,
      keys: keys,
    ))
      ProfileCsvHistory(
        title: entry.title,
        detail: entry.latestTitle?.title ?? entry.notes,
        start: entry.startDate,
        end: entry.endDate,
      ),
  ];
}
