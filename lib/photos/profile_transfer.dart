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
  const ProfileImportResult({
    this.created = 0,
    this.updated = 0,
    this.personIds = const [],
  });

  final int created;
  final int updated;

  /// Who each row went to, in the rows' order.
  final List<String> personIds;

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
      final events = await _events(person.id);
      DateTime? fixed(bool Function(PersonEvent) which) =>
          events.where(which).firstOrNull?.at;
      rows.add(
        ProfileCsvRow(
          name: person.name,
          firstName: person.firstName,
          middleName: person.middleName,
          lastName: person.lastName,
          birthDate: detail.birthDate,
          gender: detail.gender,
          bio: detail.bio,
          firstMet: fixed((e) => e.isFirstMet),
          lastSeen: fixed((e) => e.isLastSeen),
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
  /// [targets], by row, says who a row goes to where its name alone
  /// can't: a name two people share is answered in the preview (see
  /// [PersonMatches]). A row with no target goes by name, and a new person
  /// when nobody has it.
  Future<ProfileImportResult> write(
    Iterable<ProfileCsvRow> rows, {
    List<PersonTarget?> targets = const [],
  }) async {
    final all = await store.listAll();
    final byId = {for (final person in all) person.id: person};
    final existing = {
      for (final person in all) person.name.trim().toLowerCase(): person,
    };
    var created = 0;
    var updated = 0;
    final ids = <String>[];
    // One group per name: rows naming the same group join the same one,
    // and one already here is joined rather than made again.
    _groupsByName = {
      for (final group in (await store.allGroups(
        passcodeHash: passcodeHash,
        keys: keys,
      )).keys)
        group.name.trim().toLowerCase(): group,
    };
    for (final (i, row) in rows.indexed) {
      final key = row.name.trim().toLowerCase();
      final target = i < targets.length ? targets[i] : null;
      final match = switch (target) {
        PersonTarget(:final personId?) => byId[personId],
        PersonTarget() => null,
        null => existing[key],
      };
      final person = match ?? await store.create(name: row.name.trim());
      ids.add(person.id);
      if (match == null) {
        existing.putIfAbsent(key, () => person);
        created++;
      } else {
        updated++;
      }
      await _writeNameParts(person, row);
      await _writeDetail(person.id, row);
      await _writeGroups(person.id, row);
      await _writeHistory(
        person.id,
        HistoryCategory.education,
        row.education,
        row.mode,
      );
      await _writeHistory(person.id, HistoryCategory.job, row.jobs, row.mode);
      await _writePlaces(person.id, row);
      await _writeFixed(
        person.id,
        PersonEventType.firstMet,
        row.firstMet,
        row.mode,
      );
      await _writeFixed(
        person.id,
        PersonEventType.lastSeen,
        row.lastSeen,
        row.mode,
      );
    }
    return ProfileImportResult(
      created: created,
      updated: updated,
      personIds: ids,
    );
  }

  PersonScope get _scope => PersonScope.of(passcodeHash, keys);

  /// First, middle and last, by the row's mode: `all` sets all three,
  /// `skip` only fills empty ones, otherwise the row wins where it says.
  Future<void> _writeNameParts(Person person, ProfileCsvRow row) async {
    final current = await store.getById(person.id) ?? person;
    String pick(String here, String file) => switch (row.mode) {
      ProfileCsvMode.all => file,
      ProfileCsvMode.skip => here.isEmpty ? file : here,
      _ => file.isEmpty ? here : file,
    };
    final first = pick(current.firstName, row.firstName);
    final middle = pick(current.middleName, row.middleName);
    final last = pick(current.lastName, row.lastName);
    if (first == current.firstName &&
        middle == current.middleName &&
        last == current.lastName) {
      return;
    }
    await store.update(
      current.copyWith(firstName: first, middleName: middle, lastName: last),
    );
  }

  Future<void> _writeDetail(String personId, ProfileCsvRow row) async {
    final before = await _detail(personId);
    final labels = {
      for (final field in before.customFields) field.label.toLowerCase(),
    };
    final after = switch (row.mode) {
      ProfileCsvMode.all => PersonDetail(
        bio: row.bio,
        birthDate: row.birthDate,
        gender: row.gender,
        traits: row.traits,
        customFields: _distinct(row.fields),
        impression: before.impression.copyWith(tags: row.tags),
        hint: before.hint,
      ),
      ProfileCsvMode.conflict => before.copyWith(
        bio: row.bio.isEmpty ? null : row.bio,
        birthDate: row.birthDate == null ? null : () => row.birthDate,
        gender: row.gender == null ? null : () => row.gender,
        traits: {...before.traits, ...row.traits},
        customFields: _mergedFields(before.customFields, row.fields),
        impression: before.impression.copyWith(
          tags: {...before.impression.tags, ...row.tags}.toList(),
        ),
      ),
      ProfileCsvMode.skip => before.copyWith(
        bio: before.bio.trim().isEmpty ? row.bio : null,
        birthDate: before.birthDate == null ? () => row.birthDate : null,
        gender: before.gender == null ? () => row.gender : null,
        traits: {
          ...row.traits,
          for (final MapEntry(:key, :value) in before.traits.entries)
            if (value.trim().isNotEmpty) key: value,
        },
        customFields: [
          ...before.customFields,
          for (final field in row.fields)
            if (labels.add(field.label.toLowerCase())) field,
        ],
        impression: before.impression.copyWith(
          tags: {...before.impression.tags, ...row.tags}.toList(),
        ),
      ),
      null => _defaultDetail(before, row, labels),
    };
    await store.saveDetail(personId, after, scope: _scope);
  }

  /// One per label, the first.
  static List<PersonCustomField> _distinct(List<PersonCustomField> fields) {
    final seen = <String>{};
    return [
      for (final f in fields)
        if (seen.add(f.label.toLowerCase())) f,
    ];
  }

  /// The row's value for a label both have; the rest of both.
  static List<PersonCustomField> _mergedFields(
    List<PersonCustomField> before,
    List<PersonCustomField> row,
  ) {
    final fromRow = {for (final f in _distinct(row)) f.label.toLowerCase(): f};
    final kept = <String>{};
    return [
      for (final f in before)
        if (kept.add(f.label.toLowerCase()))
          fromRow[f.label.toLowerCase()] ?? f,
      for (final f in fromRow.values)
        if (kept.add(f.label.toLowerCase())) f,
    ];
  }

  PersonDetail _defaultDetail(
    PersonDetail before,
    ProfileCsvRow row,
    Set<String> labels,
  ) {
    return before.copyWith(
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
  }

  /// By default First met keeps the earlier date and Last seen the later
  /// one, so a file can only widen what is known, never undo a date set by
  /// hand that it knows less about. [ProfileCsvMode.all] and `conflict`
  /// set the file's date; `all` clears one the file leaves empty; `skip`
  /// only fills a missing one.
  Future<void> _writeFixed(
    String personId,
    PersonEventType type,
    DateTime? at,
    ProfileCsvMode? mode,
  ) async {
    final existing = (await _events(personId))
        .where((e) => e.type == type)
        .firstOrNull;
    if (at == null) {
      if (mode == ProfileCsvMode.all && existing != null) {
        await store.removeEvent(existing.id, scope: _scope);
      }
      return;
    }
    final was = existing?.at;
    final keep = switch (mode) {
      ProfileCsvMode.all || ProfileCsvMode.conflict => was == at,
      ProfileCsvMode.skip => was != null,
      null =>
        was != null &&
            (type == PersonEventType.firstMet
                ? !at.isBefore(was)
                : !at.isAfter(was)),
    };
    if (keep) return;
    await store.saveEvent(
      (existing ??
              PersonEvent(id: store.newId(), personId: personId, type: type))
          .copyWith(at: () => at),
      scope: PersonScope.of(passcodeHash, keys),
    );
  }

  Future<List<PersonEvent>> _events(String personId) =>
      store.eventsFor(personId, passcodeHash: passcodeHash, keys: keys);

  Map<String, PersonGroup> _groupsByName = {};

  Future<void> _writeGroups(String personId, ProfileCsvRow row) async {
    final current = await _groups(personId);
    if (row.mode == ProfileCsvMode.all) {
      final wanted = {for (final g in row.groups) g.name.trim().toLowerCase()};
      for (final group in current) {
        if (!wanted.contains(group.name.trim().toLowerCase())) {
          await store.leaveGroup(personId, group.id, scope: _scope);
        }
      }
    }
    final already = {
      for (final group in current)
        if (row.mode != ProfileCsvMode.all ||
            row.groups.any(
              (g) =>
                  g.name.trim().toLowerCase() ==
                  group.name.trim().toLowerCase(),
            ))
          group.name.toLowerCase(),
    };
    for (final group in row.groups) {
      final key = group.name.trim().toLowerCase();
      if (!already.add(key)) continue;
      await store.joinGroup(
        personId,
        _groupsByName[key] ??= PersonGroup(
          id: store.newId(),
          name: group.name,
          kind: group.kind,
        ),
        scope: PersonScope.of(passcodeHash, keys),
      );
    }
  }

  Future<void> _writeHistory(
    String personId,
    HistoryCategory category,
    List<ProfileCsvHistory> entries,
    ProfileCsvMode? mode,
  ) async {
    if (mode == ProfileCsvMode.all) {
      final wanted = {for (final e in entries) e.title.trim().toLowerCase()};
      for (final entry in await store.historyFor(
        personId,
        category,
        passcodeHash: passcodeHash,
        keys: keys,
      )) {
        if (!wanted.contains(entry.title.trim().toLowerCase())) {
          await store.removeHistoryEntry(entry.id, scope: _scope);
        }
      }
    }
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
        scope: PersonScope.of(passcodeHash, keys),
      );
    }
  }

  Future<void> _writePlaces(String personId, ProfileCsvRow row) async {
    if (row.mode == ProfileCsvMode.all) {
      final wanted = {for (final p in row.places) p.trim().toLowerCase()};
      for (final at in await _locations(personId)) {
        if (!wanted.contains(at.place.trim().toLowerCase())) {
          await store.removeLocation(at.id, scope: _scope);
        }
      }
    }
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
        scope: PersonScope.of(passcodeHash, keys),
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

/// Who an import row goes to, when the user said: [personId] null is
/// a new person even though the name is taken.
class PersonTarget {
  const PersonTarget(this.personId);

  const PersonTarget.newPerson() : personId = null;

  final String? personId;
}

/// The people a name could mean, from one read of the registry.
class PersonMatches {
  PersonMatches(Iterable<Person> people) {
    for (final person in people) {
      (_byName[_key(person.name)] ??= []).add(person);
    }
  }

  final _byName = <String, List<Person>>{};

  static String _key(String name) => name.trim().toLowerCase();

  List<Person> of(String name) => _byName[_key(name)] ?? const [];

  /// Two or more people answer to it: the user picks.
  bool ambiguous(String name) => of(name).length > 1;
}
