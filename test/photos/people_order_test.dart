import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/photos/people_order.dart';
import 'package:photos_vault/photos/person.dart';
import 'package:photos_vault/photos/person_store.dart';
import 'package:photos_vault/storage/asset_record.dart';

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

  test('Last seen is the latest of what is known now, never a stored '
      'photo date', () {
    AssetRecord photo(String id, DateTime at) => AssetRecord(
      localId: id,
      contentHash: id,
      platform: 'ios',
      createdAt: at,
      updatedAt: at,
    );
    final mia = _p('m', 'Mia');
    final photos = {
      'old': photo('old', DateTime(2019)),
      'new': photo('new', DateTime(2024)),
    };
    DateTime? last(
      List<String> ids, {
      DateTime? set,
      Map<String, DateTime> chats = const {},
    }) => knownDates([mia], {'m': ids}, photos, {
      if (set != null) 'm': PersonSpan(lastSeen: set, latest: set),
    }, chats: chats).last['m'];

    expect(last(['old', 'new']), DateTime(2024));
    expect(last(['old']), DateTime(2019), reason: 'a removed photo drops out');
    expect(last(['old'], set: DateTime(2021)), DateTime(2021));
    expect(
      last(['old'], set: DateTime(2021), chats: {'m': DateTime(2023)}),
      DateTime(2023),
    );
  });
}
