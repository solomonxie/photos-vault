import 'dart:convert';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/photos/person_store.dart';
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
    expect(find.text('2 people added.'), findsOne);
  });

  testWidgets('opened from the People menu, import picks the file at once', (
    tester,
  ) async {
    var picked = 0;
    await tester.pumpWidget(
      _wrap(
        ProfileTransferScreen(
          personStore: FakePersonStore(),
          start: ProfileTransferStart.import,
          pickFile: () async {
            picked++;
            return (name: 'profiles.csv', bytes: utf8.encode(_csv));
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(picked, 1);
    expect(find.text('2 people in this file'), findsOne);
  });

  testWidgets('a name two people share waits for a choice', (tester) async {
    final store = FakePersonStore();
    final older = await store.create(name: 'Mia');
    await store.create(name: 'Mia');
    await tester.pumpWidget(
      _wrap(
        ProfileTransferScreen(
          personStore: store,
          start: ProfileTransferStart.import,
          pickFile: () async =>
              (name: 'p.csv', bytes: utf8.encode('name,bio\nMia,Painter\n')),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final apply = find.widgetWithText(CupertinoButton, 'Import 1 person');
    expect(tester.widget<CupertinoButton>(apply).onPressed, isNull);
    expect(find.text('Already in People — tap to merge or add new'), findsOne);

    await tester.tap(find.byKey(const ValueKey('profile-row-0')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('importMergeInto-0')));
    await tester.pumpAndSettle();
    expect(tester.widget<CupertinoButton>(apply).onPressed, isNotNull);

    await tester.tap(apply);
    await tester.pumpAndSettle();
    expect((await store.detailFor(older.id)).bio, 'Painter');
  });

  testWidgets('a name already in People merges into them by default', (
    tester,
  ) async {
    final store = FakePersonStore();
    final mia = await store.create(name: 'Mia');
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

    // Merging by default, said in orange; no tap needed.
    expect(
      find.text(
        'Merging into the existing person — tap to add as new or change the name',
      ),
      findsOne,
    );
    await tester.tap(find.text('Import 2 people'));
    await tester.pumpAndSettle();

    final people = await store.listAll();
    expect(people.map((p) => p.name), ['Mia', 'Daniel']);
    expect((await store.detailFor(mia.id)).bio, 'Photographer');
  });

  testWidgets('every one-person name merges without a tap', (tester) async {
    final store = FakePersonStore();
    await store.create(name: 'Mia');
    await store.create(name: 'Daniel');
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
    expect(find.byKey(const ValueKey('profileCsvMergeAll')), findsNothing);
    await tester.tap(find.text('Import 2 people'));
    await tester.pumpAndSettle();
    expect(await store.listAll(), hasLength(2));
  });

  testWidgets('a default merge can be turned into a new person', (
    tester,
  ) async {
    final store = FakePersonStore();
    await store.create(name: 'Mia');
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
    await tester.tap(find.text('Mia'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('importAsNew')));
    await tester.pumpAndSettle();
    expect(find.text('Adds a new person'), findsOne);
    await tester.tap(find.text('Import 2 people'));
    await tester.pumpAndSettle();
    expect(await store.listAll(), hasLength(3));
  });

  testWidgets('a similar name asks too, and can be a new person', (
    tester,
  ) async {
    final store = FakePersonStore();
    await store.create(name: 'Mia Chen');
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
    await tester.tap(find.text('Similar to Mia Chen — tap to choose'));
    await tester.pumpAndSettle();
    expect(find.text('Merge into Mia Chen'), findsOne);
    await tester.tap(find.byKey(const ValueKey('importAsNew')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Import 2 people'));
    await tester.pumpAndSettle();
    expect((await store.listAll()).map((p) => p.name), [
      'Mia Chen',
      'Mia',
      'Daniel',
    ]);
  });

  testWidgets('a row renamed by hand merges into, or becomes, that name', (
    tester,
  ) async {
    final store = FakePersonStore();
    final mia = await store.create(name: 'Mia Wu');
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

    Future<void> rename(String from, String to) async {
      await tester.tap(find.text(from));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('importRename')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('importRenameField')),
        to,
      );
      await tester.tap(find.byKey(const ValueKey('importRenameSave')));
      await tester.pumpAndSettle();
    }

    // "Mia" is like "Mia Wu"; typed as exactly that, it merges by default.
    await rename('Mia', 'Mia Wu');
    // A name nobody has: a new person under it, no question.
    await rename('Daniel', 'Dan Park');
    expect(find.text('Importing as “Dan Park”'), findsOne);

    await tester.tap(find.text('Import 2 people'));
    await tester.pumpAndSettle();
    expect((await store.listAll()).map((p) => p.name), ['Mia Wu', 'Dan Park']);
    expect((await store.detailFor(mia.id)).bio, 'Photographer');
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
      scope: PersonScope.open,
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
