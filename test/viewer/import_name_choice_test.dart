import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/photos/person.dart';
import 'package:photos_vault/viewer/import_name_choice.dart';

Person _p(String id, String name) => Person(
  id: id,
  name: name,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
);

void main() {
  final people = [
    _p('1', 'Mia Chen'),
    _p('2', '晓明'),
    _p('3', 'Katherine'),
    _p('4', 'Tom'),
  ];

  test('the same name wins over anything similar', () {
    expect([for (final p in importCandidates('tom', people)) p.id], ['4']);
  });

  test('inside, then sounding or spelt alike, pinyin included', () {
    expect([for (final p in importCandidates('Mia', people)) p.id], ['1']);
    expect(
      [for (final p in importCandidates('Xiao Ming', people)) p.id],
      ['2'],
    );
    expect(
      [for (final p in importCandidates('Catherine', people)) p.id],
      ['3'],
    );
    expect(importCandidates('Daniel', people), isEmpty);
  });
}
