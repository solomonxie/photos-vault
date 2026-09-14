import 'package:back_your_own_photos/photos/person.dart';
import 'package:back_your_own_photos/photos/person_store.dart';

/// Pure-Dart, in-memory stand-in for [PersonStore] — for widget tests, same
/// rationale as `fake_asset_record_store.dart`.
class FakePersonStore implements PersonStore {
  final _people = <String, Person>{};
  final _members = <String, Set<String>>{};
  final _relationships = <String, Map<String, PersonRelationship>>{};
  final _locations = <String, List<PersonLocation>>{};
  var _nextId = 0;

  @override
  Future<void> close() async {}

  @override
  Future<Person> create({required String name, String? id, bool isDemo = false}) async {
    if (id != null) {
      final existing = _people[id];
      if (existing != null) return existing;
    }
    final now = DateTime.now();
    final person = Person(id: id ?? newId(), name: name, createdAt: now, updatedAt: now, isDemo: isDemo);
    _people[person.id] = person;
    return person;
  }

  @override
  Future<void> update(Person person) async => _people[person.id] = person;

  @override
  Future<Person?> getById(String id) async => _people[id];

  @override
  Future<List<Person>> listAll() async =>
      _people.values.toList()..sort((a, b) => a.createdAt.compareTo(b.createdAt));

  @override
  Future<void> remove(String id) async {
    _people.remove(id);
    _members.remove(id);
    _relationships.remove(id);
    for (final map in _relationships.values) {
      map.remove(id);
    }
    _locations.remove(id);
  }

  @override
  Future<void> addAssets(String personId, Iterable<String> localIds) async {
    _members.putIfAbsent(personId, () => {}).addAll(localIds);
  }

  @override
  Future<void> removeAsset(String personId, String localId) async {
    _members[personId]?.remove(localId);
  }

  @override
  Future<List<String>> localIdsIn(String personId) async => _members[personId]?.toList() ?? const [];

  @override
  Future<void> addRelationship(String personId, String relatedPersonId, RelationshipType type) async {
    final inverse = switch (type) {
      RelationshipType.parent => RelationshipType.child,
      RelationshipType.child => RelationshipType.parent,
      _ => type,
    };
    _relationships.putIfAbsent(personId, () => {})[relatedPersonId] = PersonRelationship(
      personId: personId,
      relatedPersonId: relatedPersonId,
      type: type,
    );
    _relationships.putIfAbsent(relatedPersonId, () => {})[personId] = PersonRelationship(
      personId: relatedPersonId,
      relatedPersonId: personId,
      type: inverse,
    );
  }

  @override
  Future<void> removeRelationship(String personId, String relatedPersonId) async {
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
  Future<List<PersonLocation>> locationsFor(String personId) async => _locations[personId] ?? const [];

  @override
  String newId() => 'fake-person-${_nextId++}';
}
