import 'package:photos_vault/l10n/app_localizations.dart';
import 'package:photos_vault/viewer/people_screen.dart';
import 'package:photos_vault/viewer/person_profile_screen.dart';
import 'package:photos_vault/viewer/person_page_screen.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_asset_record_store.dart';
import '../support/fake_person_store.dart';

Widget _wrap(Widget child) => CupertinoApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: child,
);

void main() {
  testWidgets('shows the empty state with no people yet', (tester) async {
    await tester.pumpWidget(
      _wrap(
        PeopleScreen(
          personStore: FakePersonStore(),
          assetRecordStore: FakeAssetRecordStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No people yet. Tap + to add someone.'), findsOneWidget);
  });

  testWidgets('lists existing people with their photo count', (tester) async {
    final personStore = FakePersonStore();
    final person = await personStore.create(name: 'Mia');
    await personStore.addAssets(person.id, ['p1', 'p2']);

    await tester.pumpWidget(
      _wrap(
        PeopleScreen(
          personStore: personStore,
          assetRecordStore: FakeAssetRecordStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Mia'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
  });

  testWidgets('+ opens a profile, and a typed name is the save', (
    tester,
  ) async {
    final personStore = FakePersonStore();

    await tester.pumpWidget(
      _wrap(
        PeopleScreen(
          personStore: personStore,
          assetRecordStore: FakeAssetRecordStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(CupertinoIcons.add));
    await tester.pumpAndSettle();

    // Straight onto the profile page, in the name field.
    expect(find.byType(PersonProfileScreen), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(CupertinoTextField, 'Name'),
      'Daniel',
    );
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(find.text('Daniel'), findsOneWidget);
    expect((await personStore.listAll()).map((p) => p.name), ['Daniel']);
  });

  testWidgets('a person left unnamed is not kept', (tester) async {
    final personStore = FakePersonStore();

    await tester.pumpWidget(
      _wrap(
        PeopleScreen(
          personStore: personStore,
          assetRecordStore: FakeAssetRecordStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(CupertinoIcons.add));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(await personStore.listAll(), isEmpty);
  });

  testWidgets('the search field filters the list by name and autofocuses', (
    tester,
  ) async {
    final personStore = FakePersonStore();
    await personStore.create(name: 'Mia Chen');
    await personStore.create(name: 'Daniel Wong');

    await tester.pumpWidget(
      _wrap(
        PeopleScreen(
          personStore: personStore,
          assetRecordStore: FakeAssetRecordStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final searchField = tester.widget<CupertinoSearchTextField>(
      find.byType(CupertinoSearchTextField),
    );
    expect(searchField.autofocus, isTrue);

    await tester.enterText(find.byType(CupertinoSearchTextField), 'Mia');
    await tester.pump();

    expect(find.text('Mia Chen'), findsOneWidget);
    expect(find.text('Daniel Wong'), findsNothing);
  });

  testWidgets('deleting a person lands back on the People list', (
    tester,
  ) async {
    final personStore = FakePersonStore();
    await personStore.create(name: 'Mia');

    await tester.pumpWidget(
      _wrap(
        PeopleScreen(
          personStore: personStore,
          assetRecordStore: FakeAssetRecordStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Mia'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(PersonPageScreen.nameLineKey));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Delete Person', skipOffstage: false));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete Person'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete').last);
    await tester.pumpAndSettle();

    // Both screens above it pop, and no more than that — popping one route
    // too many emptied the navigator and left a frozen black screen.
    expect(find.byType(PeopleScreen), findsOneWidget);
    expect(find.text('No people yet. Tap + to add someone.'), findsOneWidget);
  });
}
