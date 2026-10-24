import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/photos/people_order.dart';
import 'package:photos_vault/photos/person.dart';

Person _p(String id, String name) => Person(
  id: id,
  name: name,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
);

void main() {
  test('days to a birthday: today, later this year, next year, 29 Feb', () {
    final today = DateTime(2026, 10, 24, 15);
    expect(daysToBirthday(DateTime(1990, 10, 24), today), 0);
    expect(daysToBirthday(DateTime(1990, 10, 25), today), 1);
    expect(daysToBirthday(DateTime(1990, 10, 23), today), 364);
    expect(daysToBirthday(DateTime(2000, 2, 29), today), 128);
  });

  test('Chinese names file under their pinyin initial', () {
    expect(nameInitial('王小明'), 'W');
    expect(nameInitial('wendy'), 'W');
    expect(nameInitial('9 Lives'), '#');
    final people = [_p('1', 'Zoe'), _p('2', '王小明'), _p('3', 'Amy')];
    sortPeople(people, PeopleSort.name);
    expect([for (final p in people) p.name], ['Amy', '王小明', 'Zoe']);
  });

  test('birthday sort: soonest first, unknown last', () {
    final people = [_p('a', 'A'), _p('b', 'B'), _p('c', 'C')];
    sortPeople(
      people,
      PeopleSort.birthday,
      born: {'a': DateTime(1990, 1, 2), 'b': DateTime(1985, 11, 1)},
      today: DateTime(2026, 10, 24),
    );
    expect([for (final p in people) p.id], ['b', 'a', 'c']);
  });
}
