import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/photos/person.dart';
import 'package:photos_vault/photos/profile_csv.dart';

void main() {
  test('reads the documented columns', () {
    final file = readProfileCsv('''
name,birthdate,gender,bio,hair,jobs,education,groups,places,tags,fields
Mia,1990-06-14,female,"Photographer, and a good one",black,Acme Ltd|Engineer|2015-01-01|2019-06-30,Kyoto University|Physics|2008,Acme Ltd|company; Book club,Kyoto; Osaka,organised,Phone|0700 900 123
''');

    expect(file.notes, isEmpty);
    final row = file.rows.single;
    expect(row.name, 'Mia');
    expect(row.birthDate, DateTime(1990, 6, 14));
    expect(row.gender, Gender.female);
    expect(row.bio, 'Photographer, and a good one');
    expect(row.traits, {'hair': 'black'});
    expect(row.jobs.single.title, 'Acme Ltd');
    expect(row.jobs.single.detail, 'Engineer');
    expect(row.jobs.single.start, DateTime(2015, 1, 1));
    expect(row.jobs.single.end, DateTime(2019, 6, 30));
    expect(row.education.single.start, DateTime(2008, 1, 1));
    expect(row.groups.map((g) => g.kind), [
      GroupKind.company,
      GroupKind.circle,
    ]);
    expect(row.places, ['Kyoto', 'Osaka']);
    expect(row.tags, ['organised']);
    expect(row.fields.single.value, '0700 900 123');
  });

  test('a header out of a spreadsheet still matches', () {
    final file = readProfileCsv('﻿"Name", Birth Date ,GENDER\nMia,1990,male');

    expect(file.rows.single.name, 'Mia');
    expect(file.rows.single.birthDate, DateTime(1990));
    expect(file.rows.single.gender, Gender.male);
  });

  test('unknown columns are ignored and missing ones are blank', () {
    final file = readProfileCsv('name,favourite colour\nMia,green');

    expect(file.rows.single.name, 'Mia');
    expect(file.rows.single.bio, isEmpty);
    expect(file.rows.single.itemCount, 0);
  });

  test('a row without a name is reported by line rather than guessed at', () {
    final file = readProfileCsv('name,bio\n,Nobody\nMia,Someone\n');

    expect(file.rows.single.name, 'Mia');
    expect(file.notes.single.line, 2);
    expect(file.notes.single.problem, ProfileCsvProblem.missingName);
  });

  test('a file with no name column is refused whole', () {
    expect(
      readProfileCsv('bio,tags\nSomeone,nice').notes.single.problem,
      ProfileCsvProblem.noNameColumn,
    );
    expect(readProfileCsv('').notes.single.problem, ProfileCsvProblem.noHeader);
  });

  test('an impossible date is left empty rather than rolled over', () {
    expect(parseProfileCsvDate('2019-02-31'), isNull);
    expect(parseProfileCsvDate('2019-13'), isNull);
    expect(parseProfileCsvDate('not a date'), isNull);
    expect(parseProfileCsvDate('2019/6/14'), DateTime(2019, 6, 14));
  });

  test('a written file reads back as what was written', () {
    final rows = [
      ProfileCsvRow(
        name: 'Mia',
        birthDate: DateTime(1990, 6, 14),
        gender: Gender.female,
        bio: 'Two lines,\nand a comma',
        traits: const {'hair': 'black', 'eyes': 'brown'},
        fields: const [PersonCustomField(label: 'Phone', value: '0700')],
        groups: const [ProfileCsvGroup('Acme Ltd', GroupKind.company)],
        jobs: [
          ProfileCsvHistory(
            title: 'Acme Ltd',
            detail: 'Engineer',
            start: DateTime(2015),
          ),
        ],
        places: const ['Kyoto'],
        tags: const ['organised'],
      ),
      const ProfileCsvRow(name: 'Daniel'),
    ];

    final back = readProfileCsv(writeProfileCsv(rows));

    expect(back.notes, isEmpty);
    expect(back.rows.length, 2);
    expect(back.rows.first.bio, 'Two lines,\nand a comma');
    expect(back.rows.first.traits, {'hair': 'black', 'eyes': 'brown'});
    expect(back.rows.first.jobs.single.end, isNull);
    expect(back.rows.first.groups.single.kind, GroupKind.company);
    expect(back.rows.last.name, 'Daniel');
    expect(back.rows.last.itemCount, 0);
  });

  test('a quote inside a cell survives the round trip', () {
    final text = writeProfileCsv([
      const ProfileCsvRow(name: 'Mia', bio: 'She said "hello"'),
    ]);

    expect(text, contains('"She said ""hello"""'));
    expect(readProfileCsv(text).rows.single.bio, 'She said "hello"');
  });
}
