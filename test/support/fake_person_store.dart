import 'dart:io';

import 'package:bring_your_own_photos/photos/person.dart';
import 'package:bring_your_own_photos/photos/person_store.dart';

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
  Future<Person> create({
    required String name,
    String? id,
    bool isDemo = false,
  }) async {
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
      isDemo: isDemo,
    );
    _people[person.id] = person;
    return person;
  }

  @override
  Future<void> update(Person person) async => _people[person.id] = person;

  @override
  Future<Person?> getById(String id) async => _people[id];

  @override
  Future<List<Person>> listAll() async =>
      _people.values.toList()
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt));

  @override
  Future<void> remove(String id) async {
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
  Future<void> addAssets(String personId, Iterable<String> localIds) async {
    _members.putIfAbsent(personId, () => {}).addAll(localIds);
    // Mirrors the real store: the first photo someone is tagged in becomes
    // their picture, unless they already have one.
    final first = localIds.firstOrNull;
    if (first == null) return;
    final person = _people[personId];
    if (person == null || person.avatarLocalId != null) return;
    _people[personId] = person.copyWith(avatarLocalId: first);
  }

  @override
  Future<void> removeAsset(String personId, String localId) async {
    _members[personId]?.remove(localId);
  }

  @override
  Future<List<String>> localIdsIn(String personId) async =>
      _members[personId]?.toList() ?? const [];

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
    String relatedPersonId,
  ) async {
    _relationships[personId]?.remove(relatedPersonId);
    _relationships[relatedPersonId]?.remove(personId);
  }

  @override
  Future<List<PersonRelationship>> relationshipsFor(String personId) async =>
      _relationships[personId]?.values.toList() ?? const [];

  @override
  Future<List<PersonRelationship>> allRelationships() async =>
      _relationships.values.expand((m) => m.values).toList();

  @override
  Future<Set<String>> allOrganizations() async => _relationships.values
      .expand((m) => m.values)
      .map((r) => r.organization)
      .whereType<String>()
      .where((o) => o.isNotEmpty)
      .toSet();

  @override
  Future<void> addLocation(PersonLocation location) async {
    final list = _locations.putIfAbsent(location.personId, () => []);
    list.removeWhere((l) => l.id == location.id);
    list.add(location);
  }

  @override
  Future<void> removeLocation(String id) async {
    for (final list in _locations.values) {
      list.removeWhere((l) => l.id == id);
    }
  }

  @override
  Future<List<PersonLocation>> locationsFor(String personId) async =>
      _locations[personId] ?? const [];

  @override
  Future<void> addHistoryEntry(PersonHistoryEntry entry) async =>
      _history[entry.id] = entry;

  @override
  Future<void> removeHistoryEntry(String id) async => _history.remove(id);

  @override
  Future<List<PersonHistoryEntry>> historyFor(
    String personId,
    HistoryCategory category,
  ) async =>
      _history.values
          .where((e) => e.personId == personId && e.category == category)
          .toList()
        ..sort(
          (a, b) => (a.startDate ?? DateTime(0)).compareTo(
            b.startDate ?? DateTime(0),
          ),
        );

  @override
  Future<Set<String>> allHistoryTitles(HistoryCategory category) async =>
      _history.values
          .where((e) => e.category == category && e.title.isNotEmpty)
          .map((e) => e.title)
          .toSet();

  @override
  String newId() => 'fake-person-${_nextId++}';

  /// No file and no log: these fakes are maps, and the tier-1 copy has
  /// nothing to copy. `LocalVault` treats both as "nothing to snapshot".
  @override
  Future<File?> checkpointedFile() async => null;

  @override
  Future<int> changeMark() async => 0;

  @override
  Future<List<Map<String, Object?>>> changeLogRows() async => const [];
}
