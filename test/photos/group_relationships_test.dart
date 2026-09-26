import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/photos/person.dart';

PersonGroup _group(String id, GroupKind kind, {String? name}) =>
    PersonGroup(id: id, name: name ?? id, kind: kind);

void main() {
  test('a group is a link between everybody in it', () {
    final links = groupRelationships(
      personId: 'mia',
      members: {
        _group('acme', GroupKind.company): ['mia', 'dan', 'zoe'],
      },
    );

    expect(
      links.map((r) => r.relatedPersonId),
      unorderedEquals(['dan', 'zoe']),
    );
    expect(links.every((r) => r.type == RelationshipType.colleague), isTrue);
    // The company name rides along, which is what the relationship row would
    // have carried if somebody had typed it.
    expect(links.first.organization, 'acme');
  });

  test('never a link to yourself, and never to another group', () {
    final links = groupRelationships(
      personId: 'mia',
      members: {
        _group('smiths', GroupKind.family): ['mia', 'dan'],
        _group('other', GroupKind.family): ['ben', 'zoe'],
      },
    );

    expect(links.map((r) => r.relatedPersonId), ['dan']);
  });

  test('each kind of group means its own kind of link', () {
    for (final (kind, expected) in [
      (GroupKind.family, RelationshipType.family),
      (GroupKind.company, RelationshipType.colleague),
      (GroupKind.school, RelationshipType.schoolmate),
      (GroupKind.circle, RelationshipType.friend),
    ]) {
      final links = groupRelationships(
        personId: 'a',
        members: {
          _group('g', kind): ['a', 'b'],
        },
      );
      expect(links.single.type, expected, reason: kind.name);
    }
  });

  test('a circle carries no organization, because it is not one', () {
    final links = groupRelationships(
      personId: 'a',
      members: {
        _group('pub quiz', GroupKind.circle): ['a', 'b'],
      },
    );

    expect(links.single.organization, isNull);
  });

  test('something typed by hand wins over something a group implies', () {
    final links = groupRelationships(
      personId: 'mia',
      members: {
        _group('smiths', GroupKind.family): ['mia', 'dan'],
      },
      explicit: const [
        PersonRelationship(
          personId: 'mia',
          relatedPersonId: 'dan',
          type: RelationshipType.spouse,
        ),
      ],
    );

    // Otherwise a spouse in the family group would be flattened to "family".
    expect(links, isEmpty);
  });

  test('two groups holding the same pair produce one link, not two', () {
    final links = groupRelationships(
      personId: 'mia',
      members: {
        _group('acme', GroupKind.company): ['mia', 'dan'],
        _group('five-a-side', GroupKind.circle): ['mia', 'dan'],
      },
    );

    expect(links, hasLength(1));
  });
}
