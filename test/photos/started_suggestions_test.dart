import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/photos/person.dart';
import 'package:photos_vault/photos/started_suggestions.dart';

PersonGroup _g(String id, {DateTime? start}) =>
    PersonGroup(id: id, name: id, kind: GroupKind.school, start: start);

void main() {
  final school = _g('school', start: DateTime(2010, 9, 1));
  final club = _g('club', start: DateTime(2005, 3, 1));
  final undated = _g('undated');

  Map<String, StartedSuggestion> run(
    Map<PersonGroup, List<String>> groups, {
    String? owner = 'me',
    Map<String, DateTime> started = const {},
  }) => {
    for (final s in startedSuggestions(
      ownerId: owner,
      groups: groups,
      started: started,
    ))
      s.personId: s,
  };

  test('only groups shared with the owner suggest a date', () {
    final out = run({
      school: ['me', 'mia'],
      club: ['dan'],
    });
    expect(out.keys, ['mia']);
    expect(out['mia']!.suggested, DateTime(2010, 9, 1));
    expect(out['mia']!.current, isNull);
    expect(out['mia']!.group.id, 'school');
  });

  test('no owner, no suggestions', () {
    expect(
      run({
        school: ['me', 'mia'],
      }, owner: null),
      isEmpty,
    );
  });

  test('an earlier Started already there is not suggested; a later one is', () {
    final out = run(
      {
        school: ['me', 'mia', 'dan'],
      },
      started: {'mia': DateTime(2008), 'dan': DateTime(2015)},
    );
    expect(out.keys, ['dan']);
    expect(out['dan']!.current, DateTime(2015));
  });

  test('the earliest of several shared groups wins', () {
    final out = run({
      school: ['me', 'mia'],
      club: ['mia', 'me'],
    });
    expect(out['mia']!.suggested, DateTime(2005, 3, 1));
    expect(out['mia']!.group.id, 'club');
  });

  test('a group without a start is ignored, and the owner is never listed', () {
    expect(
      run({
        undated: ['me', 'mia'],
      }),
      isEmpty,
    );
    expect(
      run({
        school: ['me'],
      }),
      isEmpty,
    );
  });
}
