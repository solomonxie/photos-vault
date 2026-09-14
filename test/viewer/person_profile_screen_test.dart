import 'package:back_your_own_photos/l10n/app_localizations.dart';
import 'package:back_your_own_photos/photos/person.dart';
import 'package:back_your_own_photos/storage/passcode_hash.dart';
import 'package:back_your_own_photos/viewer/person_profile_screen.dart';
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
  testWidgets('editing the About field persists it to the store', (tester) async {
    final personStore = FakePersonStore();
    final person = await personStore.create(name: 'Mia');

    await tester.pumpWidget(
      _wrap(PersonProfileScreen(person: person, personStore: personStore, assetRecordStore: FakeAssetRecordStore())),
    );
    await tester.pumpAndSettle();

    // Fields render in order: Name, About.
    await tester.enterText(find.byType(CupertinoTextField).at(1), 'Loves hiking.');
    await tester.pump();

    expect((await personStore.getById(person.id))!.bio, 'Loves hiking.');
  });

  testWidgets('+ on Education opens a pick-or-type screen, creates an entry, and opens its details', (tester) async {
    final personStore = FakePersonStore();
    final person = await personStore.create(name: 'Mia');

    await tester.pumpWidget(
      _wrap(PersonProfileScreen(person: person, personStore: personStore, assetRecordStore: FakeAssetRecordStore())),
    );
    await tester.pumpAndSettle();

    // add_circled buttons appear in order: Education, Job, Relationships,
    // Places Lived — Education's is first.
    await tester.tap(find.byIcon(CupertinoIcons.add_circled).first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(CupertinoSearchTextField), 'UC Berkeley');
    await tester.pump();
    await tester.tap(find.text('Use "UC Berkeley"'));
    await tester.pumpAndSettle();

    // Lands on the new entry's detail page.
    expect(find.text('UC Berkeley'), findsOneWidget);
    final education = await personStore.historyFor(person.id, HistoryCategory.education);
    expect(education.single.title, 'UC Berkeley');

    await tester.tap(find.byType(CupertinoNavigationBarBackButton));
    await tester.pumpAndSettle();

    expect(find.text('UC Berkeley'), findsOneWidget);
  });

  testWidgets('Education offers an existing title from another person to pick', (tester) async {
    final personStore = FakePersonStore();
    final daniel = await personStore.create(name: 'Daniel');
    await personStore.addHistoryEntry(
      PersonHistoryEntry(id: 'e1', personId: daniel.id, category: HistoryCategory.education, title: 'MIT'),
    );
    final mia = await personStore.create(name: 'Mia');

    await tester.pumpWidget(
      _wrap(PersonProfileScreen(person: mia, personStore: personStore, assetRecordStore: FakeAssetRecordStore())),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(CupertinoIcons.add_circled).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('MIT'));
    await tester.pumpAndSettle();

    final education = await personStore.historyFor(mia.id, HistoryCategory.education);
    expect(education.single.title, 'MIT');
  });

  testWidgets('locked profile hides sections until the correct passcode is entered', (tester) async {
    final personStore = FakePersonStore();
    final locked = await personStore.create(name: 'Mia');
    await personStore.update(
      locked.copyWith(
        locked: true,
        passcodeHash: () => hashPasscode('secret'),
        passcodeHint: () => 'pet name',
      ),
    );
    await personStore.addHistoryEntry(
      PersonHistoryEntry(id: 'e1', personId: locked.id, category: HistoryCategory.education, title: 'MIT'),
    );
    final reloaded = (await personStore.getById(locked.id))!;

    await tester.pumpWidget(
      _wrap(PersonProfileScreen(person: reloaded, personStore: personStore, assetRecordStore: FakeAssetRecordStore())),
    );
    await tester.pumpAndSettle();

    expect(find.text("This profile's details are locked."), findsOneWidget);
    expect(find.text('Hint: pet name'), findsOneWidget);
    // Only the Name field renders while locked — Education isn't reachable.
    expect(find.byType(CupertinoTextField), findsOneWidget);
    expect(find.text('Education'), findsNothing);

    await tester.tap(find.widgetWithText(CupertinoButton, 'Unlock'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(CupertinoTextField).last, 'wrong');
    await tester.pump();
    await tester.tap(find.widgetWithText(CupertinoDialogAction, 'Unlock'));
    await tester.pumpAndSettle();

    expect(find.text('Incorrect passcode.'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(CupertinoButton, 'Unlock'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(CupertinoTextField).last, 'secret');
    await tester.pump();
    await tester.tap(find.widgetWithText(CupertinoDialogAction, 'Unlock'));
    await tester.pumpAndSettle();

    expect(find.text('Education'), findsOneWidget);
    expect(find.text('MIT'), findsOneWidget);
  });

  testWidgets('linking two people creates a mirrored relationship', (tester) async {
    final personStore = FakePersonStore();
    final mia = await personStore.create(name: 'Mia');
    await personStore.create(name: 'Daniel');

    await tester.pumpWidget(
      _wrap(PersonProfileScreen(person: mia, personStore: personStore, assetRecordStore: FakeAssetRecordStore())),
    );
    await tester.pumpAndSettle();

    // add_circled buttons: Education, Job, Relationships, Places Lived —
    // Relationships' is the third.
    await tester.tap(find.byIcon(CupertinoIcons.add_circled).at(2));
    await tester.pumpAndSettle();
    expect(find.text('Daniel'), findsOneWidget);
    await tester.tap(find.text('Daniel'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Friend'));
    await tester.pumpAndSettle();

    // The new relationship row lands below the fold in the profile's
    // ListView, so it's offstage rather than absent.
    expect(find.text('Daniel', skipOffstage: false), findsOneWidget);
    final relationships = await personStore.relationshipsFor(mia.id);
    expect(relationships.single.type, RelationshipType.friend);
  });

  testWidgets('"New Person…" creates and links someone not in the registry', (tester) async {
    final personStore = FakePersonStore();
    final mia = await personStore.create(name: 'Mia');

    await tester.pumpWidget(
      _wrap(PersonProfileScreen(person: mia, personStore: personStore, assetRecordStore: FakeAssetRecordStore())),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(CupertinoIcons.add_circled).at(2));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New Person…'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(CupertinoTextField).last, 'Grandma Lily');
    await tester.pump();
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Family'));
    await tester.pumpAndSettle();

    expect(find.text('Grandma Lily', skipOffstage: false), findsOneWidget);
    final all = await personStore.listAll();
    expect(all.map((p) => p.name), containsAll(['Mia', 'Grandma Lily']));
    final relationships = await personStore.relationshipsFor(mia.id);
    expect(relationships.single.type, RelationshipType.family);
  });

  testWidgets('picking Colleague prompts for a company, saved with the relationship', (tester) async {
    final personStore = FakePersonStore();
    final mia = await personStore.create(name: 'Mia');
    await personStore.create(name: 'Daniel');

    await tester.pumpWidget(
      _wrap(PersonProfileScreen(person: mia, personStore: personStore, assetRecordStore: FakeAssetRecordStore())),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(CupertinoIcons.add_circled).at(2));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Daniel'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Colleague'));
    await tester.pumpAndSettle();

    // The organization prompt is labeled "Company" for colleagues.
    expect(find.text('Company'), findsWidgets);
    await tester.enterText(find.byType(CupertinoSearchTextField), 'Acme Corp');
    await tester.pump();
    await tester.tap(find.text('Use "Acme Corp"'));
    await tester.pumpAndSettle();

    final relationships = await personStore.relationshipsFor(mia.id);
    expect(relationships.single.type, RelationshipType.colleague);
    expect(relationships.single.organization, 'Acme Corp');
    expect(find.textContaining('Acme Corp', skipOffstage: false), findsOneWidget);
  });

  testWidgets('tapping an existing relationship row re-opens the picker to edit it', (tester) async {
    final personStore = FakePersonStore();
    final mia = await personStore.create(name: 'Mia');
    final daniel = await personStore.create(name: 'Daniel');
    await personStore.addRelationship(mia.id, daniel.id, RelationshipType.friend);

    await tester.pumpWidget(
      _wrap(PersonProfileScreen(person: mia, personStore: personStore, assetRecordStore: FakeAssetRecordStore())),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Daniel', skipOffstage: false));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Daniel'));
    await tester.pumpAndSettle();
    // Re-opens the searchable person picker (Daniel is still selectable —
    // editing doesn't exclude the relationship's own current target).
    await tester.tap(find.text('Daniel'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sibling'));
    await tester.pumpAndSettle();

    final relationships = await personStore.relationshipsFor(mia.id);
    expect(relationships.single.type, RelationshipType.sibling);
  });

  testWidgets('relationships are grouped into subsections by type', (tester) async {
    final personStore = FakePersonStore();
    final mia = await personStore.create(name: 'Mia');
    final daniel = await personStore.create(name: 'Daniel');
    final lily = await personStore.create(name: 'Grandma Lily');
    await personStore.addRelationship(mia.id, daniel.id, RelationshipType.friend);
    await personStore.addRelationship(mia.id, lily.id, RelationshipType.family);

    await tester.pumpWidget(
      _wrap(PersonProfileScreen(person: mia, personStore: personStore, assetRecordStore: FakeAssetRecordStore())),
    );
    await tester.pumpAndSettle();

    // One subsection header per type in use, each above only that type's rows.
    expect(find.text('Friend', skipOffstage: false), findsOneWidget);
    expect(find.text('Family', skipOffstage: false), findsOneWidget);
    expect(find.text('Colleague', skipOffstage: false), findsNothing);
  });

  testWidgets('tapping a location row edits it in place, without duplicating', (tester) async {
    final personStore = FakePersonStore();
    final mia = await personStore.create(name: 'Mia');
    await personStore.addLocation(
      PersonLocation(id: 'loc-1', personId: mia.id, kind: LocationKind.origin, place: 'Shanghai', since: DateTime(1995)),
    );

    await tester.pumpWidget(
      _wrap(PersonProfileScreen(person: mia, personStore: personStore, assetRecordStore: FakeAssetRecordStore())),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Shanghai', skipOffstage: false));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Shanghai'));
    await tester.pumpAndSettle();
    // Pre-filled from the existing entry.
    expect(find.text('Edit Location'), findsOneWidget);
    expect(find.widgetWithText(CupertinoTextField, 'Shanghai'), findsOneWidget);

    await tester.enterText(find.widgetWithText(CupertinoTextField, 'Shanghai'), 'Beijing');
    await tester.pump();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final locations = await personStore.locationsFor(mia.id);
    expect(locations, hasLength(1));
    expect(locations.single.place, 'Beijing');
  });
}
