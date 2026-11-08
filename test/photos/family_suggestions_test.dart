import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/photos/family_suggestions.dart';
import 'package:photos_vault/photos/person.dart';

final _t = DateTime(2026);

Person _p(String id, String name, {bool ignored = false}) =>
    Person(id: id, name: name, createdAt: _t, updatedAt: _t, ignored: ignored);

List<FamilySuggestion> _find(
  List<Person> people, {
  Map<PersonGroup, List<String>> groups = const {},
  List<PersonRelationship> relationships = const [],
  Map<String, List<String>> photosOf = const {},
}) => familySuggestions(
  people: people,
  groups: groups,
  relationships: relationships,
  photosOf: photosOf,
);

void main() {
  test('a rare surname is enough', () {
    final found = _find([
      _p('a', 'Anna Okonkwo'),
      _p('b', 'Ben Okonkwo'),
      _p('c', 'Cara Smithers'),
    ]);
    expect(found, hasLength(1));
    expect(found.single.surname, 'Okonkwo');
    expect(found.single.personIds, ['a', 'b']);
  });

  test('a common romanized surname needs photos together', () {
    final people = [_p('a', 'Amy Wang'), _p('b', 'Bo Wang')];
    expect(
      _find(
        people,
        photosOf: {
          'a': ['1'],
          'b': ['1'],
        },
      ),
      isEmpty,
    );
    final found = _find(
      people,
      photosOf: {
        'a': ['1', '2'],
        'b': ['1', '2'],
      },
    );
    expect(found.single.personIds, ['a', 'b']);
  });

  test('a Chinese surname needs a generation name and a photo', () {
    final people = [_p('a', '王小明'), _p('b', '王小红'), _p('c', '王大伟')];
    expect(_find(people), isEmpty);
    final found = _find(
      people,
      photosOf: {
        'a': ['1'],
        'b': ['1'],
        'c': ['1'],
      },
    );
    // 大伟 isn't of the 小 generation.
    expect(found.single.personIds, unorderedEquals(['a', 'b']));
  });

  test('already family: nothing to suggest', () {
    final people = [_p('a', 'Anna Okonkwo'), _p('b', 'Ben Okonkwo')];
    expect(
      _find(
        people,
        relationships: const [
          PersonRelationship(
            personId: 'a',
            relatedPersonId: 'b',
            type: RelationshipType.sibling,
          ),
        ],
      ),
      isEmpty,
    );
  });

  test('joins the family group some are already in', () {
    const group = PersonGroup(
      id: 'g',
      name: 'Okonkwos',
      kind: GroupKind.family,
    );
    final found = _find(
      [_p('a', 'Anna Okonkwo'), _p('b', 'Ben Okonkwo'), _p('c', 'Cy Okonkwo')],
      groups: {
        group: ['a', 'b'],
      },
    );
    expect(found.single.into?.id, 'g');
  });

  test('ignored people count too', () {
    final found = _find([
      _p('a', 'Anna Okonkwo'),
      _p('b', 'Ben Okonkwo', ignored: true),
    ]);
    expect(found.single.personIds, ['a', 'b']);
  });
}
