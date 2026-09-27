import 'dart:convert';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/l10n/app_localizations.dart';
import 'package:photos_vault/photos/person.dart';
import 'package:photos_vault/photos/person_detail.dart';
import 'package:photos_vault/photos/profile_csv.dart';
import 'package:photos_vault/viewer/profile_transfer_screen.dart';

import '../support/fake_person_store.dart';

Widget _wrap(Widget child) => CupertinoApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: child,
);

const _csv = '''
name,bio,jobs
Mia,Photographer,Acme Ltd|Engineer|2015
Daniel,Cellist,
''';

void main() {
  testWidgets('nothing is written until the import is applied', (tester) async {
    final store = FakePersonStore();

    await tester.pumpWidget(
      _wrap(
        ProfileTransferScreen(
          personStore: store,
          pickFile: () async =>
              (name: 'profiles.csv', bytes: utf8.encode(_csv)),
        ),
      ),
    );

    await tester.tap(find.text('Import from a file'));
    await tester.pumpAndSettle();

    expect(find.text('2 people in this file'), findsOne);
    expect(find.text('Mia'), findsOne);
    expect(await store.listAll(), isEmpty);

    await tester.tap(find.text('Import 2 people'));
    await tester.pumpAndSettle();

    final people = await store.listAll();
    expect(people.map((p) => p.name), ['Mia', 'Daniel']);
    expect((await store.detailFor(people.first.id)).bio, 'Photographer');
    expect(find.text('2 people added'), findsOne);
  });

  testWidgets('a row switched off is left out', (tester) async {
    final store = FakePersonStore();

    await tester.pumpWidget(
      _wrap(
        ProfileTransferScreen(
          personStore: store,
          pickFile: () async =>
              (name: 'profiles.csv', bytes: utf8.encode(_csv)),
        ),
      ),
    );

    await tester.tap(find.text('Import from a file'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('profile-row-1')),
        matching: find.byType(CupertinoSwitch),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Import 1 person'));
    await tester.pumpAndSettle();

    expect((await store.listAll()).map((p) => p.name), ['Mia']);
  });

  testWidgets('a file with no name column says so and writes nothing', (
    tester,
  ) async {
    final store = FakePersonStore();

    await tester.pumpWidget(
      _wrap(
        ProfileTransferScreen(
          personStore: store,
          pickFile: () async =>
              (name: 'wrong.csv', bytes: utf8.encode('bio\nSomeone')),
        ),
      ),
    );

    await tester.tap(find.text('Import from a file'));
    await tester.pumpAndSettle();

    expect(find.textContaining('no'), findsWidgets);
    expect(find.byType(CupertinoSwitch), findsNothing);
    expect(await store.listAll(), isEmpty);
  });

  testWidgets('export hands a readable file to the share sheet', (
    tester,
  ) async {
    final store = FakePersonStore();
    final mia = await store.create(name: 'Mia');
    await store.saveDetail(
      mia.id,
      const PersonDetail(bio: 'Photographer', gender: Gender.female),
    );
    File? shared;
    final dir = Directory.systemTemp.createTempSync('profile-csv');
    addTearDown(() => dir.deleteSync(recursive: true));

    await tester.pumpWidget(
      _wrap(
        ProfileTransferScreen(
          personStore: store,
          temporaryDirectory: () async => dir,
          share: (file) async => shared = file,
        ),
      ),
    );

    // The write is a real file, so the export has to run on the real event
    // loop — a widget test's fake clock never delivers dart:io's completion.
    await tester.runAsync(() async {
      await tester.tap(find.text('Export profiles'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();

    expect(shared, isNotNull);
    final rows = readProfileCsv(shared!.readAsStringSync()).rows;
    expect(rows.single.name, 'Mia');
    expect(rows.single.bio, 'Photographer');
    expect(rows.single.gender, Gender.female);
    expect(find.text('1 profile written to profiles.csv'), findsOne);
  });

  testWidgets('nobody to export says so rather than sharing an empty file', (
    tester,
  ) async {
    var shared = false;

    await tester.pumpWidget(
      _wrap(
        ProfileTransferScreen(
          personStore: FakePersonStore(),
          temporaryDirectory: () async =>
              Directory.systemTemp.createTempSync('profile-csv-empty'),
          share: (_) async => shared = true,
        ),
      ),
    );

    await tester.runAsync(() async {
      await tester.tap(find.text('Export profiles'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();

    expect(shared, isFalse);
    expect(find.text('There are no named people to export yet.'), findsOne);
  });
}
