import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/photos/merge_suggestions.dart';
import 'package:photos_vault/photos/person.dart';

Person _p(String id, String name) => Person(
  id: id,
  name: name,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
);

void main() {
  List<String> pairs(List<Person> people, {Set<String> dismissed = const {}}) =>
      [
        for (final s in MergeSuggestion.of(people, dismissed: dismissed))
          '${s.a.name}+${s.b.name}${s.sameName ? '=' : '~'}',
      ];

  test('same names first, then one name inside another', () {
    expect(
      pairs([
        _p('1', 'Mia Chen'),
        _p('2', 'mia'),
        _p('3', 'Mia  chen'),
        _p('4', '王小明'),
        _p('5', '小明'),
        _p('6', 'Tom'),
        _p('7', 'Tommy'),
      ]),
      [
        'Mia Chen+Mia  chen=',
        'Mia Chen+mia~',
        'mia+Mia  chen~',
        '王小明+小明~',
        'Tom+Tommy~',
      ],
    );
  });

  test('short Latin names and dismissed pairs are left alone', () {
    expect(pairs([_p('1', 'Li'), _p('2', 'Lily'), _p('3', 'Emily')]), isEmpty);
    expect(
      pairs([_p('1', 'Ann'), _p('2', 'Ann')], dismissed: {'1|2'}),
      isEmpty,
    );
  });
}
