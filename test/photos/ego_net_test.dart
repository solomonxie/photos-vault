import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/photos/ego_net.dart';
import 'package:photos_vault/photos/person.dart';

PersonRelationship _r(String a, String b, RelationshipType t) =>
    PersonRelationship(personId: a, relatedPersonId: b, type: t);

void main() {
  final company = List.generate(1500, (i) => 'c$i');
  final names = {
    'me': 'Me',
    'wife': 'Wife',
    'mum': 'Mum',
    'pal': 'Pal',
    'palpal': 'Pal of Pal',
    for (final id in company) id: 'Colleague $id',
  };
  final index = EgoIndex(
    relationships: [
      _r('me', 'wife', RelationshipType.spouse),
      _r('mum', 'me', RelationshipType.parent),
      _r('me', 'pal', RelationshipType.friend),
      _r('pal', 'palpal', RelationshipType.friend),
      _r('me', 'c7', RelationshipType.friend),
    ],
    groups: {
      const PersonGroup(id: 'g', name: 'Acme', kind: GroupKind.company): [
        'me',
        ...company,
      ],
    },
    photosByPerson: {
      'me': ['p1', 'p2', 'p3'],
      'c900': ['p1', 'p2', 'p3'],
      'c5': ['p1'],
    },
    names: names,
  );

  test('a thousand-strong group is a dozen and a "+N", closest first', () {
    final net = index.around('me');
    expect(
      [for (final g in net.groups) g.sector],
      [EgoSector.family, EgoSector.friend, EgoSector.colleague],
    );
    final family = net.groups[0];
    expect([for (final t in family.shown) t.personId], ['wife', 'mum']);
    final colleagues = net.groups[2];
    expect(colleagues.shown, hasLength(12));
    expect(colleagues.total, 1499, reason: 'c7 is a friend, drawn once');
    expect(colleagues.shown.first.personId, 'c900', reason: 'most photos');
    expect(colleagues.shown[1].personId, 'c5');
    expect(colleagues.shown.first.organization, 'Acme');
  });

  test('an explicit link outranks the group', () {
    final friends = index.around('me').groups[1];
    expect({for (final t in friends.shown) t.personId}, {'pal', 'c7'});
  });

  test('second hop is explicit links only, never the group again', () {
    final net = index.around('me');
    expect(net.second, [('pal', 'palpal')]);
    final fromColleague = index.around('c3');
    expect(fromColleague.second, isEmpty);
  });

  test('nobody linked is an empty net; busiest has most links', () {
    final lonely = EgoIndex(
      relationships: const [],
      groups: const {},
      photosByPerson: const {},
      names: const {'a': 'A'},
    );
    expect(lonely.around('a').isEmpty, isTrue);
    expect(lonely.busiest, isNull);
    expect(index.busiest, 'me');
  });

  test('layout keeps ring neighbours a full slot apart', () {
    final net = index.around('me');
    final layout = EgoLayout.of(net);
    final ring = [
      for (final g in net.groups) ...[
        for (final t in g.shown) layout.positions[t.personId]!,
        ?layout.more[g.sector],
      ],
    ];
    for (var i = 0; i < ring.length; i++) {
      for (var j = i + 1; j < ring.length; j++) {
        final d = math.sqrt(
          math.pow(ring[i].x - ring[j].x, 2) +
              math.pow(ring[i].y - ring[j].y, 2),
        );
        expect(d, greaterThan(EgoLayout.slot * 0.95));
      }
    }
    final c = layout.positions['me']!;
    expect(c.x, closeTo(layout.side / 2, 0.01));
  });
}
