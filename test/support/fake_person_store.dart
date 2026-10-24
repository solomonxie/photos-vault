import 'package:photos_vault/photos/person.dart';
import 'package:photos_vault/photos/person_detail.dart';
import 'package:photos_vault/vault/keys.dart' show AlbumKeys;
import 'package:photos_vault/photos/person_store.dart';

/// Pure-Dart, in-memory stand-in for [PersonStore] — for widget tests, same
/// rationale as `fake_asset_record_store.dart`.
class FakePersonStore implements PersonStore {
  final _people = <String, Person>{};
  final _members = <String, Set<String>>{};
  final _relationships = <String, Map<String, PersonRelationship>>{};
  final _locations = <String, List<PersonLocation>>{};
  final _history = <String, PersonHistoryEntry>{};
  var _nextId = 0;

  @override
  Future<void> close() async {}

  @override
  Future<Person> create({required String name, String? id}) async {
    if (id != null) {
      final existing = _people[id];
      if (existing != null) return existing;
    }
    final now = DateTime.now();
    final person = Person(
      id: id ?? newId(),
      name: name,
      createdAt: now,
      updatedAt: now,
    );
    _people[person.id] = person;
    return person;
  }

  @override
  Future<void> update(Person person) async {
    final old = _people[person.id];
    if (old != null && old.name != person.name) {
      _log(person.id, 'name', old.name, person.name);
    }
    _people[person.id] = person;
  }

  /// Names and merges only; the real store's triggers log the rest.
  final Map<String, List<PersonChange>> _changes = {};

  void _log(String id, String kind, String? before, String? after) => _changes
      .putIfAbsent(id, () => [])
      .insert(
        0,
        PersonChange(
          at: DateTime.now(),
          kind: kind,
          before: before,
          after: after,
        ),
      );

  @override
  Future<void> markSeen(String personId, DateTime at) async {
    final last = (await eventsFor(personId))
        .where((e) => e.isLastSeen)
        .firstOrNull;
    if (last?.at case final was? when !at.isAfter(was)) return;
    await saveEvent(
      PersonEvent(
        id: last?.id ?? newId(),
        personId: personId,
        type: PersonEventType.lastSeen,
        at: at,
      ),
      scope: PersonScope.open,
    );
  }

  @override
  Future<List<PersonChange>> changesOf(String personId) async => [
    ...?_changes[personId],
  ];

  @override
  Future<Map<String, List<String>>> allFormerNames() async => {
    for (final MapEntry(:key, :value) in _changes.entries)
      if (_people[key] case final person?)
        key: {
          for (final c in value.reversed)
            if ((c.kind == 'name' || c.kind == 'merged') &&
                c.before != null &&
                c.before != person.name)
              c.before!,
        }.toList(),
  };

  @override
  Future<List<String>> formerNames(String personId) async =>
      (await allFormerNames())[personId] ?? const [];

  /// Raw sealed rows, by person. The fake keeps them opaque, same as the
  /// real store does.
  final sealedRows = <String, List<Map<String, Object?>>>{};

  @override
  Future<List<Map<String, Object?>>> sealedRowsFor(String personId) async =>
      sealedRows[personId] ?? const [];

  @override
  Future<void> restoreSealedRows(List<Map<String, Object?>> rows) async {
    for (final row in rows) {
      (sealedRows[row['person_id'] as String? ?? ''] ??= []).add(row);
    }
  }

  @override
  Future<Map<String, PersonDetail>> openDetails() async => {
    for (final entry in details.entries)
      if (entry.key.endsWith('/')) entry.key.split('/').first: entry.value,
  };

  /// `personId` → groups they are in.
  final groups = <String, List<PersonGroup>>{};

  @override
  Future<void> joinGroup(
    String personId,
    PersonGroup group, {
    required PersonScope scope,
  }) async {
    final mine = groups[personId] ??= [];
    mine.removeWhere((g) => g.id == group.id);
    mine.add(group);
  }

  @override
  Future<void> leaveGroup(
    String personId,
    String groupId, {
    required PersonScope scope,
  }) async => groups[personId]?.removeWhere((g) => g.id == groupId);

  @override
  Future<void> deleteGroup(String groupId, {required PersonScope scope}) async {
    for (final list in groups.values) {
      list.removeWhere((g) => g.id == groupId);
    }
  }

  @override
  Future<List<PersonGroup>> groupsFor(
    String personId, {
    String passcodeHash = openNamespace,
    AlbumKeys? keys,
  }) async => List.unmodifiable(groups[personId] ?? const []);

  @override
  Future<Map<PersonGroup, List<String>>> allGroups({
    String passcodeHash = openNamespace,
    AlbumKeys? keys,
  }) async {
    final byId = <String, PersonGroup>{};
    final members = <String, List<String>>{};
    for (final entry in groups.entries) {
      for (final group in entry.value) {
        byId[group.id] = group;
        (members[group.id] ??= []).add(entry.key);
      }
    }
    return {for (final e in byId.entries) e.value: members[e.key] ?? const []};
  }

  final events = <String, PersonEvent>{};

  @override
  Future<void> saveEvent(
    PersonEvent event, {
    required PersonScope scope,
  }) async {
    events[event.id] = event;
  }

  @override
  Future<void> removeEvent(String id, {required PersonScope scope}) async =>
      events.remove(id);

  @override
  Future<List<PersonEvent>> eventsFor(
    String personId, {
    String passcodeHash = openNamespace,
    AlbumKeys? keys,
  }) async =>
      events.values.where((e) => e.personId == personId).toList()
        ..sort((a, b) => (a.at ?? DateTime(0)).compareTo(b.at ?? DateTime(0)));

  @override
  Future<Map<String, PersonSpan>> openEventSpans() async {
    final out = <String, PersonSpan>{};
    for (final e in events.values) {
      final at = e.at;
      if (at == null) continue;
      out[e.personId] = (out[e.personId] ?? const PersonSpan()).including(
        type: e.type.name,
        lo: at,
        hi: at,
      );
    }
    return out;
  }

  final details = <String, PersonDetail>{};

  static String _key(String personId, String passcodeHash) =>
      '$personId/$passcodeHash';

  @override
  Future<PersonDetail> detailFor(
    String personId, {
    String passcodeHash = openNamespace,
    AlbumKeys? keys,
  }) async => details[_key(personId, passcodeHash)] ?? PersonDetail.empty;

  @override
  Future<void> saveDetail(
    String personId,
    PersonDetail detail, {
    required PersonScope scope,
  }) async {
    details[_key(personId, scope.passcodeHash)] = detail;
  }

  @override
  Future<void> dropMembersOfMissingPeople() async =>
      _members.removeWhere((id, _) => !_people.containsKey(id));

  @override
  Future<Map<String, PersonExportSet>> exportSets() async => {
    for (final id in _people.keys)
      id: PersonExportSet()
        ..detail = await detailFor(id)
        ..history.addAll([
          for (final c in HistoryCategory.values) ...await historyFor(id, c),
        ])
        ..locations.addAll(await locationsFor(id))
        ..relationships.addAll(await relationshipsFor(id))
        ..sealed.addAll(await sealedRowsFor(id)),
  };

  @override
  Future<Person?> getById(String id) async => _people[id];

  @override
  Future<List<Person>> listAll() async =>
      _people.values.toList()
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt));

  @override
  Future<bool> hasAnyRecord(String id) async =>
      (_members[id]?.isNotEmpty ?? false) ||
      (_relationships[id]?.isNotEmpty ?? false) ||
      _relationships.values.any((m) => m.containsKey(id)) ||
      (_locations[id]?.isNotEmpty ?? false) ||
      _history.values.any((e) => e.personId == id) ||
      events.values.any((e) => e.personId == id) ||
      (groups[id]?.isNotEmpty ?? false) ||
      details.entries.any(
        (e) => e.key.startsWith('$id/') && !e.value.isEmpty,
      ) ||
      (sealedRows[id]?.isNotEmpty ?? false);

  @override
  Future<PersonMergeOutcome> merge(String keepId, String goneId) async {
    if (keepId == goneId ||
        !_people.containsKey(keepId) ||
        !_people.containsKey(goneId)) {
      return PersonMergeOutcome.missing;
    }
    _members.putIfAbsent(keepId, () => {}).addAll(_members[goneId] ?? const {});
    final carried = _aliases.remove(goneId) ?? const [];
    final history = _changes.remove(goneId) ?? const [];
    final goneName = _people[goneId]!.name;
    await remove(goneId);
    _changes.putIfAbsent(keepId, () => []).insertAll(0, history);
    _log(keepId, 'merged', goneName, _people[keepId]!.name);
    _aliases.putIfAbsent(keepId, () => []).addAll([...carried, goneId]);
    return PersonMergeOutcome.merged;
  }

  final Map<String, List<String>> _aliases = {};

  @override
  Future<List<String>> aliasesOf(String personId) async => [
    ...?_aliases[personId],
  ];

  @override
  Future<void> remove(String id) async {
    _aliases.remove(id);
    _changes.remove(id);
    _people.remove(id);
    _members.remove(id);
    _relationships.remove(id);
    for (final map in _relationships.values) {
      map.remove(id);
    }
    _locations.remove(id);
    _history.removeWhere((_, entry) => entry.personId == id);
  }

  @override
  Future<void> addAssets(
    String personId,
    Iterable<String> localIds, {
    bool fillAvatar = true,
  }) async {
    _members.putIfAbsent(personId, () => {}).addAll(localIds);
    // Mirrors the real store: the first photo someone is tagged in becomes
    // their picture, unless they already have one.
    final first = localIds.firstOrNull;
    if (first == null || !fillAvatar) return;
    final person = _people[personId];
    if (person == null || person.avatarLocalId != null) return;
    _people[personId] = person.copyWith(avatarLocalId: first);
  }

  @override
  Future<void> removeAsset(String personId, String localId) async {
    _members[personId]?.remove(localId);
  }

  @override
  Future<void> removeAssets(String personId, Iterable<String> localIds) async {
    _members[personId]?.removeAll(localIds);
  }

  @override
  Future<void> forgetAssets(Iterable<String> localIds) async {
    final gone = localIds.toSet();
    for (final members in _members.values) {
      members.removeAll(gone);
    }
  }

  @override
  Future<void> reorientAvatars(String localId, int orientation) async {
    for (final person in _people.values.toList()) {
      final face = person.avatarFace;
      if (person.avatarLocalId != localId || face == null) continue;
      _people[person.id] = person.copyWith(
        avatarFace: () => face.oriented(orientation),
      );
    }
  }

  @override
  Future<List<String>> localIdsIn(String personId) async =>
      _members[personId]?.toList() ?? const [];

  @override
  Future<Map<String, List<String>>> allMemberships() async => {
    for (final entry in _members.entries)
      if (entry.value.isNotEmpty) entry.key: entry.value.toList(),
  };

  @override
  Future<List<Person>> peopleFor(String localId) async => _members.entries
      .where((e) => e.value.contains(localId))
      .map((e) => _people[e.key])
      .whereType<Person>()
      .toList();

  @override
  Future<void> addRelationship(
    String personId,
    String relatedPersonId,
    RelationshipType type, {
    String? organization,
    required PersonScope scope,
  }) async {
    final inverse = switch (type) {
      RelationshipType.parent => RelationshipType.child,
      RelationshipType.child => RelationshipType.parent,
      _ => type,
    };
    _relationships.putIfAbsent(
      personId,
      () => {},
    )[relatedPersonId] = PersonRelationship(
      personId: personId,
      relatedPersonId: relatedPersonId,
      type: type,
      organization: organization,
    );
    _relationships.putIfAbsent(
      relatedPersonId,
      () => {},
    )[personId] = PersonRelationship(
      personId: relatedPersonId,
      relatedPersonId: personId,
      type: inverse,
      organization: organization,
    );
  }

  @override
  Future<void> removeRelationship(
    String personId,
    String relatedPersonId, {
    required PersonScope scope,
  }) async {
    _relationships[personId]?.remove(relatedPersonId);
    _relationships[relatedPersonId]?.remove(personId);
  }

  @override
  Future<List<PersonRelationship>> relationshipsFor(
    String personId, {
    String passcodeHash = openNamespace,
    AlbumKeys? keys,
  }) async => _relationships[personId]?.values.toList() ?? const [];

  @override
  Future<List<PersonRelationship>> allRelationships({
    String passcodeHash = openNamespace,
    AlbumKeys? keys,
  }) async => _relationships.values.expand((m) => m.values).toList();

  @override
  Future<Set<String>> allOrganizations({
    String passcodeHash = openNamespace,
    AlbumKeys? keys,
  }) async => _relationships.values
      .expand((m) => m.values)
      .map((r) => r.organization)
      .whereType<String>()
      .where((o) => o.isNotEmpty)
      .toSet();

  @override
  Future<void> addLocation(
    PersonLocation location, {
    required PersonScope scope,
  }) async {
    final list = _locations.putIfAbsent(location.personId, () => []);
    list.removeWhere((l) => l.id == location.id);
    list.add(location);
  }

  @override
  Future<void> removeLocation(String id, {required PersonScope scope}) async {
    for (final list in _locations.values) {
      list.removeWhere((l) => l.id == id);
    }
  }

  @override
  Future<List<PersonLocation>> locationsFor(
    String personId, {
    String passcodeHash = openNamespace,
    AlbumKeys? keys,
  }) async => _locations[personId] ?? const [];

  @override
  Future<void> addHistoryEntry(
    PersonHistoryEntry entry, {
    required PersonScope scope,
  }) async {
    _history[entry.id] = entry;
    historyScopes[entry.id] = scope.passcodeHash;
  }

  /// Which set each history entry was last written to, by entry id.
  final historyScopes = <String, String>{};

  @override
  Future<void> removeHistoryEntry(
    String id, {
    required PersonScope scope,
  }) async {
    if (historyScopes[id] != scope.passcodeHash) return;
    _history.remove(id);
    historyScopes.remove(id);
  }

  @override
  Future<List<PersonHistoryEntry>> historyFor(
    String personId,
    HistoryCategory category, {
    String passcodeHash = openNamespace,
    AlbumKeys? keys,
  }) async =>
      _history.values
          .where(
            (e) =>
                e.personId == personId &&
                e.category == category &&
                (historyScopes[e.id] ?? openNamespace) == passcodeHash,
          )
          .toList()
        ..sort(
          (a, b) => (a.startDate ?? DateTime(0)).compareTo(
            b.startDate ?? DateTime(0),
          ),
        );

  @override
  Future<Set<String>> allHistoryTitles(
    HistoryCategory category, {
    String passcodeHash = openNamespace,
    AlbumKeys? keys,
  }) async => _history.values
      .where((e) => e.category == category && e.title.isNotEmpty)
      .map((e) => e.title)
      .toSet();

  @override
  String newId() => 'fake-person-${_nextId++}';

  @override
  Future<int> changeMark() async => 0;

  /// Never equal: every reload re-reads, as before stamps.
  @override
  Future<Object> changeStamp() async => Object();

  @override
  Future<void> clearAll() async {
    _people.clear();
    _members.clear();
    _relationships.clear();
    _locations.clear();
    _history.clear();
  }

  @override
  Future<List<Map<String, Object?>>> changeLogRows({
    bool decode = true,
  }) async => const [];

  @override
  Future<Set<String>> namespaces() async => {};

  @override
  Future<void> retag(String from, String to) async {}

  @override
  Future<bool> copyTo(
    String dest,
    Set<String> hiddenIds, {
    bool slim = false,
  }) async => false;
}
