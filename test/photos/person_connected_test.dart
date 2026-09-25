import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/photos/person.dart';

PersonRelationship _edge(String from, String to) => PersonRelationship(
  personId: from,
  relatedPersonId: to,
  type: RelationshipType.friend,
);

void main() {
  test('alone with nobody is a net of one', () {
    expect(peopleConnectedTo('mia', const []), {'mia'});
  });

  test('reaches across a chain, in either direction', () {
    // Written as mia→dan and eve→dan: Eve is only reachable if the walk
    // ignores which profile each row was added from.
    final net = peopleConnectedTo('mia', [
      _edge('mia', 'dan'),
      _edge('eve', 'dan'),
    ]);

    expect(net, {'mia', 'dan', 'eve'});
  });

  test('a separate net is not reachable', () {
    final net = peopleConnectedTo('mia', [
      _edge('mia', 'dan'),
      _edge('ben', 'zoe'),
    ]);

    expect(net, {'mia', 'dan'});
    expect(net, isNot(contains('ben')));
  });

  test('a cycle terminates', () {
    final net = peopleConnectedTo('a', [
      _edge('a', 'b'),
      _edge('b', 'c'),
      _edge('c', 'a'),
    ]);

    expect(net, {'a', 'b', 'c'});
  });
}
