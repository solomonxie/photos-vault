import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/photos/person.dart';
import 'package:photos_vault/photos/person_owner.dart';

PersonRelationship _to(String id, RelationshipType type) =>
    PersonRelationship(personId: 'them', relatedPersonId: id, type: type);

void main() {
  test('nothing to say when nobody has said who they are', () {
    expect(
      relationsToOwner(
        ownerId: null,
        relationships: [_to('me', RelationshipType.sibling)],
      ),
      isEmpty,
    );
  });

  test('only links pointing at the owner count', () {
    final relations = relationsToOwner(
      ownerId: 'me',
      relationships: [
        _to('me', RelationshipType.sibling),
        _to('someone-else', RelationshipType.colleague),
      ],
    );

    expect(relations, [RelationshipType.sibling]);
  });

  test('two ways of being related to you are both worth saying', () {
    final relations = relationsToOwner(
      ownerId: 'me',
      relationships: [
        _to('me', RelationshipType.sibling),
        _to('me', RelationshipType.colleague),
      ],
    );

    expect(
      relations,
      unorderedEquals([RelationshipType.sibling, RelationshipType.colleague]),
    );
  });

  test('the same relationship twice is said once', () {
    // A typed sibling link and a family group both reach you.
    final relations = relationsToOwner(
      ownerId: 'me',
      relationships: [
        _to('me', RelationshipType.family),
        _to('me', RelationshipType.family),
      ],
    );

    expect(relations, [RelationshipType.family]);
  });
}
