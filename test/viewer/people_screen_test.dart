import 'package:photos_vault/l10n/app_localizations.dart';
import 'package:photos_vault/viewer/people_screen.dart';
import 'package:photos_vault/viewer/person_profile_screen.dart';
import 'package:photos_vault/viewer/person_page_screen.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/photos/conversation_file.dart';
import 'package:photos_vault/viewer/search_picker_sheet.dart';
import 'package:photos_vault/photos/person_store.dart';

import 'package:photos_vault/photos/person.dart';
import 'package:photos_vault/photos/person_detail.dart';

import '../support/fake_ai_analysis_store.dart';
import '../support/fake_asset_record_store.dart';
import '../support/fake_conversation_store.dart';
import '../support/fake_person_store.dart';

Widget _wrap(Widget child) => CupertinoApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: child,
);

const _face = FaceRect(0.3, 0.3, 0.4, 0.4);

/// A record per id, as a library that has the photos would.
Future<FakeAssetRecordStore> _withPhotos(Iterable<String> ids) async {
  final store = FakeAssetRecordStore();
  for (final id in ids) {
    await store.upsert(localId: id, contentHash: id, platform: 'ios');
  }
  return store;
}

/// Faces to Name is one row on People; its faces are a tap in.
Future<void> _openFaces(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('people-faces-row')));
  await tester.pumpAndSettle();
}

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

  testWidgets('sorted by most photos, the most photographed is first', (
    tester,
  ) async {
    final personStore = FakePersonStore();
    final few = await personStore.create(name: 'Ana');
    await personStore.addAssets(few.id, ['p1']);
    final many = await personStore.create(name: 'Bo');
    await personStore.addAssets(many.id, ['p2', 'p3', 'p4']);
    final photos = await _withPhotos(['p1', 'p2', 'p3', 'p4']);
    await photos.setAppState('people_sort_v1', 'photos');

    await tester.pumpWidget(
      _wrap(PeopleScreen(personStore: personStore, assetRecordStore: photos)),
    );
    await tester.pumpAndSettle();

    // Naming and reviewing both start at the top; the person you have
    // most photos of is the one you came here about.
    expect(
      tester.getTopLeft(find.text('Bo')).dy,
      lessThan(tester.getTopLeft(find.text('Ana')).dy),
    );
  });

  testWidgets('by default the most recently seen is first; undated last', (
    tester,
  ) async {
    final personStore = FakePersonStore();
    final old = await personStore.create(name: 'Ana');
    final recent = await personStore.create(name: 'Bo');
    await personStore.create(name: 'Cy');
    for (final (person, year) in [(old, 2009), (recent, 2018)]) {
      await personStore.saveEvent(
        PersonEvent(
          id: 'e-${person.id}',
          personId: person.id,
          type: PersonEventType.lastSeen,
          at: DateTime(year),
        ),
        scope: PersonScope.open,
      );
    }

    await tester.pumpWidget(
      _wrap(
        PeopleScreen(
          personStore: personStore,
          assetRecordStore: await _withPhotos(const []),
        ),
      ),
    );
    await tester.pumpAndSettle();

    double y(String name) => tester.getTopLeft(find.text(name)).dy;
    expect(y('Bo'), lessThan(y('Ana')));
    expect(y('Ana'), lessThan(y('Cy')));
    expect(find.textContaining('seen'), findsNWidgets(2));
  });

  testWidgets('lists existing people with their photo count', (tester) async {
    final personStore = FakePersonStore();
    final person = await personStore.create(name: 'Mia');
    await personStore.addAssets(person.id, ['p1', 'p2']);
    final photos = await _withPhotos(['p1', 'p2']);

    await tester.pumpWidget(
      _wrap(PeopleScreen(personStore: personStore, assetRecordStore: photos)),
    );
    await tester.pumpAndSettle();

    expect(find.text('Mia'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
  });

  testWidgets('a count never includes hidden, binned or purged photos', (
    tester,
  ) async {
    final personStore = FakePersonStore();
    final person = await personStore.create(name: 'Mia');
    await personStore.addAssets(person.id, [
      'shown',
      'locked',
      'hidden',
      'binned',
      'purged',
    ]);
    final photos = await _withPhotos(['shown', 'locked', 'hidden', 'binned']);
    await photos.setPasscodeHash('locked', 'hash');
    await photos.setHidden('hidden', true);
    await photos.softDelete('binned');

    await tester.pumpWidget(
      _wrap(PeopleScreen(personStore: personStore, assetRecordStore: photos)),
    );
    await tester.pumpAndSettle();

    expect(find.text('Mia'), findsOneWidget);
    final row = find.ancestor(
      of: find.text('Mia'),
      matching: find.byType(CupertinoListTile),
    );
    expect(find.descendant(of: row, matching: find.text('1')), findsOneWidget);
    expect(find.text('5'), findsNothing);
  });

  testWidgets('Add Person opens a profile, and a typed name is the save', (
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

    await tester.tap(find.byKey(const ValueKey('peopleAddPerson')));
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

    await tester.tap(find.byKey(const ValueKey('peopleAddPerson')));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(await personStore.listAll(), isEmpty);
  });

  testWidgets('the search field filters the list, without grabbing focus', (
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
    // The page is a list you came to read. A keyboard covering half of it
    // on arrival is a dismissal to do before you can look at anything.
    expect(searchField.autofocus, isFalse);

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
    // Bottom of the profile, and the page is a lazy `ListView` — below the
    // fold it has not been built, so there is nothing to make visible yet.
    await tester.scrollUntilVisible(
      find.text('Delete Person', skipOffstage: false),
      200,
      scrollable: find.byType(Scrollable).first,
    );
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
  testWidgets('people with no photos fold into one row', (tester) async {
    final personStore = FakePersonStore();
    final mia = await personStore.create(name: 'Mia');
    await personStore.addAssets(mia.id, ['p1']);
    await personStore.create(name: 'Zoe');
    final photos = await _withPhotos(['p1']);
    await tester.pumpWidget(
      _wrap(PeopleScreen(personStore: personStore, assetRecordStore: photos)),
    );
    await tester.pumpAndSettle();

    expect(find.text('Mia'), findsOneWidget);
    expect(find.text('Zoe'), findsNothing);
    expect(find.text('People with no photos'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('people-no-photos-row')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('people-bare-page')), findsOneWidget);
    expect(find.text('Zoe'), findsOneWidget);
  });

  testWidgets('no-photos and groups rows sit above the named list', (
    tester,
  ) async {
    final personStore = FakePersonStore();
    final mia = await personStore.create(name: 'Mia');
    await personStore.addAssets(mia.id, ['p1']);
    await personStore.create(name: 'Zoe');
    final photos = await _withPhotos(['p1']);
    await tester.pumpWidget(
      _wrap(PeopleScreen(personStore: personStore, assetRecordStore: photos)),
    );
    await tester.pumpAndSettle();

    double top(Finder f) => tester.getTopLeft(f).dy;
    final mias = top(find.text('Mia'));
    final groups = top(find.byKey(const ValueKey('people-groups-row')));
    final bare = top(find.byKey(const ValueKey('people-no-photos-row')));
    final ungrouped = top(find.byKey(const ValueKey('people-ungrouped-row')));
    expect(groups, lessThan(bare));
    expect(bare, lessThan(ungrouped));
    expect(ungrouped, lessThan(mias));
  });

  testWidgets('New Group names a group and adds its first people', (
    tester,
  ) async {
    final personStore = FakePersonStore();
    final mia = await personStore.create(name: 'Mia');
    await personStore.create(name: 'Zoe');
    await tester.pumpWidget(
      _wrap(
        PeopleScreen(
          personStore: personStore,
          assetRecordStore: FakeAssetRecordStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('people-groups-row')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('people-groups-page')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('people-new-group')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(CupertinoTextField).last, 'Climbing');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mia').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(searchPickerDoneKey));
    await tester.pumpAndSettle();

    final groups = await personStore.allGroups();
    expect(groups.keys.single.name, 'Climbing');
    expect(groups.values.single, [mia.id]);
    expect(
      find.byKey(ValueKey('people-group-${groups.keys.single.id}')),
      findsOneWidget,
    );
  });

  testWidgets('hiding all of someone\'s photos keeps their profile photo', (
    tester,
  ) async {
    final personStore = FakePersonStore();
    final mia = await personStore.create(name: 'Mia');
    await personStore.addAssets(mia.id, ['p1']);
    final photos = await _withPhotos(['p1']);
    await tester.pumpWidget(
      _wrap(PeopleScreen(personStore: personStore, assetRecordStore: photos)),
    );
    await tester.pumpAndSettle();

    await tester.longPress(find.text('Mia'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('peopleBatchHide')));
    await tester.pumpAndSettle();
    expect(
      find.text('Only their profile photo is left, and it stays.'),
      findsOneWidget,
    );
  });

  testWidgets('held, a row is picked to rename, merge or delete', (
    tester,
  ) async {
    final personStore = FakePersonStore();
    final mia = await personStore.create(name: 'Mia');
    final zoe = await personStore.create(name: 'Zoe');
    await personStore.addAssets(zoe.id, ['p1']);
    await tester.pumpWidget(
      _wrap(
        PeopleScreen(
          personStore: personStore,
          assetRecordStore: FakeAssetRecordStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.longPress(find.text('Mia'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('peopleBatchMore')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('peopleBatchRename')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('peopleRenameField')),
      'Mia Wu',
    );
    await tester.tap(find.byKey(const ValueKey('peopleRenameSave')));
    await tester.pumpAndSettle();
    expect((await personStore.getById(mia.id))!.name, 'Mia Wu');

    await tester.longPress(find.text('Zoe'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mia Wu'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('peopleBatchMerge')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('peopleMergeKeep-${mia.id}')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Moves 1 photo.'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('mergePeopleConfirm')));
    await tester.pumpAndSettle();
    expect(await personStore.getById(zoe.id), isNull);
    expect((await personStore.getById(mia.id))!.name, 'Mia Wu');
    expect((await personStore.allMemberships())[mia.id], ['p1']);
    expect(await personStore.aliasesOf(mia.id), [zoe.id]);

    await tester.longPress(find.text('Mia Wu'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('peopleBatchMore')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('peopleBatchDelete')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('peopleBatchDeleteConfirm')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('peopleBatchDeleteConfirmAgain')),
    );
    await tester.pumpAndSettle();
    expect(await personStore.listAll(), isEmpty);
  });

  testWidgets('backing out of a merge at any step changes nothing', (
    tester,
  ) async {
    final personStore = FakePersonStore();
    final mia = await personStore.create(name: 'Mia');
    final zoe = await personStore.create(name: 'Zoe');
    await personStore.addAssets(zoe.id, ['p1']);
    await tester.pumpWidget(
      _wrap(
        PeopleScreen(
          personStore: personStore,
          assetRecordStore: FakeAssetRecordStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    Future<void> startMerge() async {
      await tester.longPress(find.text('Zoe'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mia'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('peopleBatchMerge')));
      await tester.pumpAndSettle();
    }

    // At "keep which one", and at the confirm.
    for (final steps in [0, 1]) {
      await startMerge();
      if (steps >= 1) {
        await tester.tap(find.byKey(ValueKey('peopleMergeKeep-${mia.id}')));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text('Cancel').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('peopleSelectionDone')));
      await tester.pumpAndSettle();
      expect(await personStore.getById(zoe.id), isNotNull);
      expect((await personStore.allMemberships())[zoe.id], ['p1']);
      expect(await personStore.aliasesOf(mia.id), isEmpty);
    }
  });

  testWidgets('a locked profile is never merged', (tester) async {
    final personStore = FakePersonStore();
    final mia = await personStore.create(name: 'Mia');
    final zoe = await personStore.create(name: 'Zoe');
    await personStore.update(zoe.copyWith(locked: true));
    await tester.pumpWidget(
      _wrap(
        PeopleScreen(
          personStore: personStore,
          assetRecordStore: FakeAssetRecordStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.longPress(find.text('Mia'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Zoe'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('peopleBatchMerge')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('peopleMergeKeep-${mia.id}')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('mergePeopleConfirm')), findsNothing);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(await personStore.getById(zoe.id), isNotNull);
  });

  testWidgets('deleting several takes two confirms; backing out keeps all', (
    tester,
  ) async {
    final personStore = FakePersonStore();
    await personStore.create(name: 'Mia');
    await personStore.create(name: 'Zoe');
    await personStore.create(name: 'Ann');
    await tester.pumpWidget(
      _wrap(
        PeopleScreen(
          personStore: personStore,
          assetRecordStore: FakeAssetRecordStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.longPress(find.text('Mia'));
    await tester.tap(find.text('Zoe'));
    await tester.pumpAndSettle();

    // Out at the second ask: nobody goes.
    await tester.tap(find.byKey(const ValueKey('peopleBatchMore')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('peopleBatchDelete')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('peopleBatchDeleteConfirm')));
    await tester.pumpAndSettle();
    expect(find.text('Really delete these 2 people?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(await personStore.listAll(), hasLength(3));

    await tester.tap(find.byKey(const ValueKey('peopleBatchMore')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('peopleBatchDelete')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('peopleBatchDeleteConfirm')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('peopleBatchDeleteConfirmAgain')),
    );
    await tester.pumpAndSettle();
    expect((await personStore.listAll()).map((p) => p.name), ['Ann']);
    expect(find.byKey(const ValueKey('peopleBatchMore')), findsNothing);
  });

  testWidgets('holding a row can start select mode with it picked', (
    tester,
  ) async {
    final personStore = FakePersonStore();
    final mia = await personStore.create(name: 'Mia');
    await personStore.create(name: 'Zoe');
    await tester.pumpWidget(
      _wrap(
        PeopleScreen(
          personStore: personStore,
          assetRecordStore: FakeAssetRecordStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.longPress(find.text('Mia'));
    await tester.pumpAndSettle();
    expect(find.text('1 Selected'), findsOneWidget);
    expect(find.byKey(ValueKey('people-pick-${mia.id}')), findsOneWidget);
    await tester.tap(find.text('Zoe'));
    await tester.pumpAndSettle();
    expect(find.text('2 Selected'), findsOneWidget);
  });

  testWidgets('search finds a person by a name they used to have', (
    tester,
  ) async {
    final personStore = FakePersonStore();
    final mia = await personStore.create(name: 'Mia Chen');
    await personStore.update(mia.copyWith(name: 'Mia Wu'));
    await personStore.create(name: 'Zoe');
    await tester.pumpWidget(
      _wrap(
        PeopleScreen(
          personStore: personStore,
          assetRecordStore: FakeAssetRecordStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(CupertinoSearchTextField), 'chen');
    await tester.pumpAndSettle();
    expect(find.text('Mia Wu'), findsOneWidget);
    expect(find.text('Zoe'), findsNothing);
  });

  testWidgets('batch edit sets Last seen and a group on everyone picked', (
    tester,
  ) async {
    final personStore = FakePersonStore();
    final mia = await personStore.create(name: 'Mia');
    final zoe = await personStore.create(name: 'Zoe');
    await tester.pumpWidget(
      _wrap(
        PeopleScreen(
          personStore: personStore,
          assetRecordStore: FakeAssetRecordStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    Future<void> pickBoth() async {
      await tester.longPress(find.text('Mia'));
      await tester.tap(find.text('Zoe'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('peopleBatchEdit')));
      await tester.pumpAndSettle();
    }

    await pickBoth();
    await tester.tap(find.byKey(const ValueKey('peopleEdit-lastSeen')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('peopleEditDateDone')));
    await tester.pumpAndSettle();
    for (final p in [mia, zoe]) {
      final events = await personStore.eventsFor(p.id);
      expect(events.where((e) => e.isLastSeen).single.at, isNotNull);
    }

    await pickBoth();
    await tester.tap(find.byKey(const ValueKey('peopleEdit-group')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(searchPickerFieldKey), 'Choir');
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Choir').last);
    await tester.pumpAndSettle();
    final groups = await personStore.allGroups();
    expect(groups.values.single.toSet(), {mia.id, zoe.id});
  });

  testWidgets('Merge in select mode keeps the one chosen', (tester) async {
    final personStore = FakePersonStore();
    final mia = await personStore.create(name: 'Mia');
    final zoe = await personStore.create(name: 'Zoe');
    await tester.pumpWidget(
      _wrap(
        PeopleScreen(
          personStore: personStore,
          assetRecordStore: FakeAssetRecordStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.longPress(find.text('Mia'));
    await tester.tap(find.text('Zoe'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('peopleBatchMerge')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('peopleMergeKeep-${zoe.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mergePeopleConfirm')));
    await tester.pumpAndSettle();
    expect(await personStore.getById(mia.id), isNull);
    expect(await personStore.getById(zoe.id), isNotNull);
    expect(find.byKey(const ValueKey('peopleBatchMerge')), findsNothing);
  });

  testWidgets('Merge with one picked chooses who merges into them', (
    tester,
  ) async {
    final personStore = FakePersonStore();
    final mia = await personStore.create(name: 'Mia');
    final zoe = await personStore.create(name: 'Zoe');
    await tester.pumpWidget(
      _wrap(
        PeopleScreen(
          personStore: personStore,
          assetRecordStore: FakeAssetRecordStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.longPress(find.text('Mia'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('peopleBatchMerge')));
    await tester.pumpAndSettle();
    expect(find.text('Merge into Mia'), findsOneWidget);
    await tester.tap(find.text('Zoe').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mergePeopleConfirm')));
    await tester.pumpAndSettle();
    expect(await personStore.getById(zoe.id), isNull);
    expect(await personStore.getById(mia.id), isNotNull);
  });

  testWidgets('Select People picks several for the batch bar', (tester) async {
    final personStore = FakePersonStore();
    final mia = await personStore.create(name: 'Mia');
    await personStore.create(name: 'Zoe');
    await tester.pumpWidget(
      _wrap(
        PeopleScreen(
          personStore: personStore,
          assetRecordStore: FakeAssetRecordStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.longPress(find.text('Mia'));
    await tester.pumpAndSettle();

    expect(find.text('1 Selected'), findsOneWidget);
    expect(find.byKey(ValueKey('people-pick-${mia.id}')), findsOneWidget);
    expect(find.byKey(const ValueKey('peopleBatchHide')), findsOneWidget);
    expect(find.byKey(const ValueKey('peopleBatchUnhide')), findsOneWidget);
    expect(find.byType(PersonPageScreen), findsNothing, reason: 'a tap picks');

    await tester.tap(find.text('Select All'));
    await tester.pumpAndSettle();
    expect(find.text('2 Selected'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('peopleSelectionDone')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('peopleBatchHide')), findsNothing);
  });

  Future<FakePersonStore> grouped() async {
    final personStore = FakePersonStore();
    final mia = await personStore.create(name: 'Mia');
    final dan = await personStore.create(name: 'Daniel');
    await personStore.create(name: 'Zoe');
    const acme = PersonGroup(id: 'g1', name: 'Acme', kind: GroupKind.company);
    await personStore.joinGroup(mia.id, acme, scope: PersonScope.open);
    await personStore.joinGroup(dan.id, acme, scope: PersonScope.open);
    return personStore;
  }

  Future<void> show(WidgetTester tester, FakePersonStore people) async {
    await tester.pumpWidget(
      _wrap(
        PeopleScreen(
          personStore: people,
          assetRecordStore: FakeAssetRecordStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('somebody with chats shows a chat mark', (tester) async {
    final people = FakePersonStore();
    final mia = await people.create(name: 'Mia');
    final zoe = await people.create(name: 'Zoe');
    final chats = FakeConversationStore();
    await chats.insert(mia.id, [
      ConversationMessage(
        chat: 'qq:1',
        source: 'qq',
        at: DateTime(2020),
        fromMe: true,
        sender: '',
        text: 'hi',
        kind: 'text',
        hash: 'h',
      ),
    ]);
    await tester.pumpWidget(
      _wrap(
        PeopleScreen(
          personStore: people,
          assetRecordStore: FakeAssetRecordStore(),
          conversationStore: chats,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('people-chats-${mia.id}')), findsOneWidget);
    expect(find.byKey(ValueKey('people-chats-${zoe.id}')), findsNothing);
  });

  testWidgets('a rename can be undone from the toast', (tester) async {
    final people = FakePersonStore();
    final mia = await people.create(name: 'Mia');
    await show(tester, people);
    await tester.longPress(find.text('Mia'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('peopleBatchMore')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('peopleBatchRename')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('peopleRenameField')),
      'Mia Wu',
    );
    await tester.tap(find.byKey(const ValueKey('peopleRenameSave')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect((await people.getById(mia.id))!.name, 'Mia');
    await tester.pump(const Duration(seconds: 6));
  });

  testWidgets('a group filter holds over a reload', (tester) async {
    final people = await grouped();
    await show(tester, people);

    await tester.tap(find.byKey(const ValueKey('people-filter-group')));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Acme').last);
    await tester.pumpAndSettle();
    expect(find.text('Zoe'), findsNothing);
    expect(find.text('Mia'), findsOneWidget);

    // A rename reloads; the filter must still be Acme, not nobody.
    await tester.longPress(find.text('Mia'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('peopleBatchMore')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('peopleBatchRename')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('peopleRenameField')),
      'Mia Wu',
    );
    await tester.tap(find.byKey(const ValueKey('peopleRenameSave')));
    await tester.pumpAndSettle();
    expect(find.text('Mia Wu'), findsOneWidget);
    expect(find.text('Daniel'), findsOneWidget);
  });

  testWidgets('Remove from Group takes the picked out of a group', (
    tester,
  ) async {
    final people = await grouped();
    await show(tester, people);
    await tester.longPress(find.text('Mia'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('peopleBatchMore')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('peopleBatchLeaveGroup')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Acme').last);
    await tester.pumpAndSettle();
    final members = (await people.allGroups()).values.single;
    expect(members, hasLength(1), reason: 'Daniel stays');
  });

  testWidgets('by name: initial headings, pinyin included, and an index', (
    tester,
  ) async {
    final people = FakePersonStore();
    for (var i = 0; i < 24; i++) {
      await people.create(name: '${String.fromCharCode(65 + i)}name');
    }
    await people.create(name: '王小明');
    await tester.binding.setSurfaceSize(const Size(393, 852));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await show(tester, people);
    await tester.ensureVisible(find.byKey(const ValueKey('peopleSortMenu')));
    await tester.tap(find.byKey(const ValueKey('peopleSortMenu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('peopleSort-name')));
    await tester.pumpAndSettle();
    // Not folded behind "Show all": the index needs everyone listed.
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('people-show-all')),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const ValueKey('people-show-all')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('people-index')), findsOneWidget);
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('people-index')),
        matching: find.text('W'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('王小明'), findsOneWidget);
    expect(find.text('Wname'), findsOneWidget);
  });

  testWidgets('dropdowns narrow the list, and a group is one of them', (
    tester,
  ) async {
    final personStore = FakePersonStore();
    final mia = await personStore.create(name: 'Mia');
    final dan = await personStore.create(name: 'Daniel');
    await personStore.create(name: 'Zoe');
    const acme = PersonGroup(id: 'g1', name: 'Acme', kind: GroupKind.company);
    await personStore.joinGroup(mia.id, acme, scope: PersonScope.open);
    await personStore.joinGroup(dan.id, acme, scope: PersonScope.open);

    await tester.pumpWidget(
      _wrap(
        PeopleScreen(
          personStore: personStore,
          assetRecordStore: FakeAssetRecordStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Zoe'), findsOneWidget);

    // One Group dropdown, then the group picked from a searchable list.
    await tester.tap(find.byKey(const ValueKey('people-filter-group')));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Acme').last);
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('people-filter-group')),
        matching: find.text('Acme'),
      ),
      findsOneWidget,
    );
    expect(find.text('Mia'), findsOneWidget);
    expect(find.text('Daniel'), findsOneWidget);
    expect(find.text('Zoe'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('people-filter-group')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Any'));
    await tester.pumpAndSettle();
    expect(find.text('Zoe'), findsOneWidget);
  });

  testWidgets('the top right is one + that adds a person', (tester) async {
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

    expect(find.byKey(const ValueKey('peopleAddPerson')), findsOneWidget);
    expect(find.byIcon(CupertinoIcons.ellipsis_circle), findsNothing);
  });

  testWidgets('imported groups make up Faces to Name', (tester) async {
    final records = await _withPhotos(['p1']);
    final analyses = FakeAiAnalysisStore();
    await analyses.importNamedFaces(
      const [],
      grouped: [(localId: 'p1', face: _face, groupId: 'g1')],
      groups: const {'g1': 'Mia'},
    );

    await tester.pumpWidget(
      _wrap(
        PeopleScreen(
          personStore: FakePersonStore(),
          assetRecordStore: records,
          aiAnalysisStore: analyses,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _openFaces(tester);

    expect(find.byKey(const ValueKey('people-imported-g1')), findsOneWidget);
    expect(find.text('Mia?'), findsOneWidget);
  });
}
