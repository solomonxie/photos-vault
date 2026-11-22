import 'package:photos_vault/l10n/app_localizations.dart';
import 'package:photos_vault/photos/person.dart';
import 'package:photos_vault/storage/passcode_hash.dart';
import 'package:photos_vault/vault/passcode_tags.dart';
import 'package:photos_vault/viewer/custom_fields_editor.dart';
import 'package:photos_vault/viewer/person_profile_screen.dart';
import 'package:photos_vault/viewer/private_album_gate.dart';
import 'package:photos_vault/viewer/person_traits_editor.dart';
import 'package:photos_vault/viewer/search_picker_sheet.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/photos/person_store.dart';
import 'package:photos_vault/photos/travel.dart';

import 'package:photos_vault/photos/person_detail.dart';
import 'package:photos_vault/photos/person_owner.dart';
import 'package:photos_vault/vault/keys.dart';

import '../settings/fake_secure_store.dart';
import '../support/fake_asset_record_store.dart';
import '../support/fake_person_store.dart';
import '../support/fake_travel_store.dart';

Widget _wrap(Widget child) => CupertinoApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: child,
);

/// A surface tall enough that the whole profile builds at once.
///
/// For the tests that compare where sections sit, or assert across several of
/// them: the page is a lazy `ListView`, so on a phone-sized surface the
/// sections below the fold do not exist to be measured.
Future<void> _useTallSurface(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(800, 3000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
}

/// Scrolls the profile until [finder] exists *and* is on screen.
///
/// `ensureVisible` is not enough: the page is a lazy `ListView`, so a section
/// far enough down has not been built yet and there is no element to make
/// visible. This is the difference between a test that fails and a test that
/// cannot see what it is testing.
Future<void> _scrollTo(WidgetTester tester, Finder finder) async {
  // The outer one: the page has more than one Scrollable, and
  // `scrollUntilVisible` will not guess between them.
  await tester.scrollUntilVisible(
    finder,
    200,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
}

/// Opens [tab] ('about', 'life' or 'people').
Future<void> _tab(WidgetTester tester, String tab) async {
  await tester.tap(find.byKey(ValueKey('profileTab:$tab')));
  await tester.pumpAndSettle();
}

/// An empty section is reached through its tab's Add button.
Future<void> _add(WidgetTester tester, String tab, String title) async {
  await _tab(tester, tab);
  final add = find.byKey(const ValueKey('profileAddMissing'));
  await _scrollTo(tester, add);
  await tester.tap(add);
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(profileSectionAddKey(title)));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Travels lists the routes and entries the person is linked to', (
    tester,
  ) async {
    await _useTallSurface(tester);
    final personStore = FakePersonStore();
    final person = await personStore.create(name: 'Mia');
    final travel = FakeTravelStore();
    final kyoto = await travel.findOrCreateCity(
      name: 'Kyoto',
      lat: 35,
      lng: 135.7,
    );
    final route = await travel.createRoute(title: 'Japan');
    final entry = await travel.saveEntry(
      travel.newEntry(placeId: kyoto.id, kind: EntryKind.diary),
    );
    final mia = TravelLink(LinkTarget.person, person.id);
    await travel.setLinks(LinkOwner.route, route.id, [mia]);
    await travel.setLinks(LinkOwner.entry, entry.id, [mia]);
    await tester.pumpWidget(
      _wrap(
        PersonProfileScreen(
          person: person,
          personStore: personStore,
          assetRecordStore: FakeAssetRecordStore(),
          travelStore: travel,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _tab(tester, 'life');
    await _scrollTo(tester, find.text('Travels'));
    expect(find.byKey(ValueKey('travelsRoute-${route.id}')), findsOne);
    expect(find.byKey(ValueKey('travelsEntry-${entry.id}')), findsOne);
    expect(find.text('Kyoto'), findsOne, reason: 'untitled: the place');
  });

  testWidgets('editing the About field persists it to the store', (
    tester,
  ) async {
    final personStore = FakePersonStore();
    final person = await personStore.create(name: 'Mia');

    await tester.pumpWidget(
      _wrap(
        PersonProfileScreen(
          person: person,
          personStore: personStore,
          assetRecordStore: FakeAssetRecordStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(CupertinoTextField, 'No bio yet.'),
      'Loves hiking.',
    );
    await tester.pump();

    expect((await personStore.detailFor(person.id)).bio, 'Loves hiking.');
  });

  testWidgets('tapping age sets a birth date, tapping gender sets a gender', (
    tester,
  ) async {
    final personStore = FakePersonStore();
    final person = await personStore.create(name: 'Mia');

    await tester.pumpWidget(
      _wrap(
        PersonProfileScreen(
          person: person,
          personStore: personStore,
          assetRecordStore: FakeAssetRecordStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Unset state: plain placeholder text, no box.
    expect(find.text('Age'), findsOneWidget);
    expect(find.text('Gender'), findsOneWidget);

    await tester.tap(find.text('Gender'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Female'));
    await tester.pumpAndSettle();

    expect((await personStore.detailFor(person.id)).gender, Gender.female);
    expect(find.text('Female'), findsOneWidget);

    await tester.tap(find.text('Age'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final saved = await personStore.detailFor(person.id);
    expect(saved.birthDate, isNotNull);
    expect(find.textContaining('years old'), findsOneWidget);
  });

  testWidgets(
    '+ on Education opens a pick-or-type screen, creates an entry, and opens its details',
    (tester) async {
      final personStore = FakePersonStore();
      final person = await personStore.create(name: 'Mia');

      await tester.pumpWidget(
        _wrap(
          PersonProfileScreen(
            person: person,
            personStore: personStore,
            assetRecordStore: FakeAssetRecordStore(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await _add(tester, 'life', 'Education');
      await tester.enterText(find.byKey(searchPickerFieldKey), 'UC Berkeley');
      await tester.pump();
      await tester.tap(find.text('Use “UC Berkeley”'));
      await tester.pumpAndSettle();

      // Lands on the new entry's detail page.
      expect(find.text('UC Berkeley'), findsOneWidget);
      final education = await personStore.historyFor(
        person.id,
        HistoryCategory.education,
      );
      expect(education.single.title, 'UC Berkeley');

      await tester.tap(find.byType(CupertinoNavigationBarBackButton));
      await tester.pumpAndSettle();

      await _scrollTo(tester, find.text('UC Berkeley'));
      expect(find.text('UC Berkeley'), findsOneWidget);
    },
  );

  testWidgets(
    'Education offers an existing title from another person to pick',
    (tester) async {
      final personStore = FakePersonStore();
      final daniel = await personStore.create(name: 'Daniel');
      await personStore.addHistoryEntry(
        PersonHistoryEntry(
          id: 'e1',
          personId: daniel.id,
          category: HistoryCategory.education,
          title: 'MIT',
        ),
        scope: PersonScope.open,
      );
      final mia = await personStore.create(name: 'Mia');

      await tester.pumpWidget(
        _wrap(
          PersonProfileScreen(
            person: mia,
            personStore: personStore,
            assetRecordStore: FakeAssetRecordStore(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await _add(tester, 'life', 'Education');
      await tester.tap(find.text('MIT'));
      await tester.pumpAndSettle();

      final education = await personStore.historyFor(
        mia.id,
        HistoryCategory.education,
      );
      expect(education.single.title, 'MIT');
    },
  );

  testWidgets('first, middle and last fill in from the name', (tester) async {
    final personStore = FakePersonStore();
    final mia = await personStore.create(name: 'Mia Jane Wu');
    await tester.binding.setSurfaceSize(const Size(400, 3000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _wrap(
        PersonProfileScreen(
          person: mia,
          personStore: personStore,
          assetRecordStore: FakeAssetRecordStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('personNamePart-first')),
      findsNothing,
      reason: 'the parts stay out of sight until the name is edited',
    );
    await tester.tap(find.text('Mia Jane Wu'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('personNamePartsSuggest')));
    await tester.pumpAndSettle();
    final saved = (await personStore.getById(mia.id))!;
    expect(
      [saved.firstName, saved.middleName, saved.lastName],
      ['Mia', 'Jane', 'Wu'],
    );
    expect(saved.name, 'Mia Jane Wu', reason: 'the display name stays');
    expect(find.byKey(const ValueKey('personNamePartsSuggest')), findsNothing);
  });

  testWidgets('a former name shows, and the change history lists it', (
    tester,
  ) async {
    final personStore = FakePersonStore();
    var mia = await personStore.create(name: 'Mia Chen');
    mia = mia.copyWith(name: 'Mia Wu');
    await personStore.update(mia);
    await tester.binding.setSurfaceSize(const Size(400, 3000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _wrap(
        PersonProfileScreen(
          person: mia,
          personStore: personStore,
          assetRecordStore: FakeAssetRecordStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Also known as Mia Chen'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('profileMore')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('personChangesRow')));
    await tester.pumpAndSettle();
    expect(find.text('Renamed'), findsOneWidget);
    expect(find.text('Mia Chen → Mia Wu'), findsOneWidget);
  });

  testWidgets('four digits open their own set, and only theirs', (
    tester,
  ) async {
    final personStore = FakePersonStore();
    final keychain = FakeSecureStore();
    final vaultKeys = VaultKeys(store: keychain, derive: deriveOnThisIsolate);
    // The passphrase is the app's, shared with the private album. With one
    // already set, the keypad goes straight up rather than through setup.
    await vaultKeys.add('a good long passphrase');
    final mia = await personStore.create(name: 'Mia');
    await personStore.saveDetail(
      mia.id,
      const PersonDetail(bio: 'open bio'),
      scope: PersonScope.open,
    );
    // Sealed sets are the owner's, under their folder's code.
    final assets = FakeAssetRecordStore();
    await PersonOwner(assets).set(mia.id);

    await tester.pumpWidget(
      _wrap(
        PersonProfileScreen(
          person: mia,
          personStore: personStore,
          assetRecordStore: assets,
          vaultKeys: vaultKeys,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('open bio'), findsOneWidget);

    await tester.tap(find.byIcon(CupertinoIcons.number));
    await tester.pumpAndSettle();
    for (final digit in '1234'.split('')) {
      await tester.tap(find.text(digit));
      await tester.pump();
    }
    await tester.pumpAndSettle();

    // Nothing has been kept under 1234, so there is nothing here — which is
    // exactly what a passcode that opens nothing looks like. No error, no
    // "locked" notice, nothing to tell the two apart.
    expect(find.text('open bio'), findsNothing);
    expect(find.text('Incorrect passcode.'), findsNothing);

    // By placeholder, not by index: inside a set there is a hint field above
    // About, and counting would silently target the wrong one.
    await tester.enterText(
      find.widgetWithText(CupertinoTextField, 'No bio yet.'),
      'the other bio',
    );
    await tester.pump();

    // Saved under the owner's 1234 tag and nowhere else.
    final tag = await PasscodeTags(
      records: FakeAssetRecordStore(),
      people: personStore,
      vaultKeys: vaultKeys,
    ).tagFor(personAlbumCode(mia.id, '1234'));
    expect(tag, isNot(hashPasscode(personAlbumCode(mia.id, '1234'))));
    expect(
      (await personStore.detailFor(mia.id, passcodeHash: tag)).bio,
      'the other bio',
    );
    expect((await personStore.detailFor(mia.id)).bio, 'open bio');

    // And back out again, with no confirmation to get through.
    await tester.tap(find.byIcon(CupertinoIcons.number_circle_fill));
    await tester.pumpAndSettle();
    expect(find.text('open bio'), findsOneWidget);
  });

  testWidgets('an impression is picked, cleared, and tagged', (tester) async {
    final personStore = FakePersonStore();
    final mia = await personStore.create(name: 'Mia');

    await tester.pumpWidget(
      _wrap(
        PersonProfileScreen(
          person: mia,
          personStore: personStore,
          assetRecordStore: FakeAssetRecordStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await _add(tester, 'about', 'Impression');
    final social = find.text('Social energy');
    await _scrollTo(tester, social);
    await tester.tap(social);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Very outgoing').last);
    await tester.pumpAndSettle();

    expect(
      (await personStore.detailFor(mia.id)).impression.socialEnergy,
      ImpressionLevel.veryHigh,
    );

    // Recorded by accident is worse than not recorded: it has to be
    // clearable.
    await tester.tap(social);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Not set').last);
    await tester.pumpAndSettle();

    expect(
      (await personStore.detailFor(mia.id)).impression.socialEnergy,
      isNull,
    );

    final tag = find.text('funny');
    await _scrollTo(tester, tag);
    await tester.tap(tag);
    await tester.pumpAndSettle();
    expect((await personStore.detailFor(mia.id)).impression.tags, ['funny']);

    await tester.tap(tag);
    await tester.pumpAndSettle();
    expect((await personStore.detailFor(mia.id)).impression.tags, isEmpty);
  });

  testWidgets('empty sections wait behind one Add button', (tester) async {
    await _useTallSurface(tester);
    final personStore = FakePersonStore();
    final mia = await personStore.create(name: 'Mia');

    await tester.pumpWidget(
      _wrap(
        PersonProfileScreen(
          person: mia,
          personStore: personStore,
          assetRecordStore: FakeAssetRecordStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await _tab(tester, 'life');
    expect(find.byKey(profileSectionHeaderKey('Education')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('profileAddMissing')));
    await tester.pumpAndSettle();
    for (final title in ['Work', 'Education', 'Places Lived', 'Events']) {
      expect(find.byKey(profileSectionAddKey(title)), findsOneWidget);
    }
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    // More details offers its fields in the add sheet, never as empty rows
    // or chips on the page.
    await _add(tester, 'about', 'More Details');
    expect(find.byKey(traitRowKey('add-hair')), findsOneWidget);
    expect(find.byKey(traitRowKey('add-eyes')), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byKey(traitRowKey('hair')), findsNothing);
  });

  testWidgets('hair is a menu, height is typed', (tester) async {
    await _useTallSurface(tester);
    final personStore = FakePersonStore();
    final mia = await personStore.create(name: 'Mia');

    await tester.pumpWidget(
      _wrap(
        PersonProfileScreen(
          person: mia,
          personStore: personStore,
          assetRecordStore: FakeAssetRecordStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await _add(tester, 'about', 'More Details');
    await tester.tap(find.byKey(traitRowKey('add-hair')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('blonde').last);
    await tester.pumpAndSettle();
    expect((await personStore.detailFor(mia.id)).traits['hair'], 'blonde');
    expect(find.byKey(traitRowKey('hair')), findsOneWidget);

    await tester.tap(find.byKey(customFieldsAddKey));
    await tester.pumpAndSettle();
    expect(find.byKey(traitRowKey('add-hair')), findsNothing);
    await tester.tap(find.byKey(traitRowKey('add-height')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(CupertinoTextField).last, '178 cm');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect((await personStore.detailFor(mia.id)).traits['height'], '178 cm');

    // Cleared rather than stored blank, so a profile carries only what was
    // actually written.
    await tester.tap(find.byKey(traitRowKey('hair')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Not set').last);
    await tester.pumpAndSettle();
    expect(
      (await personStore.detailFor(mia.id)).traits.containsKey('hair'),
      isFalse,
    );
    expect(find.byKey(traitRowKey('hair')), findsNothing);
  });

  testWidgets('a tag can be typed, and shows as typed', (tester) async {
    await _useTallSurface(tester);
    final personStore = FakePersonStore();
    final mia = await personStore.create(name: 'Mia');

    await tester.pumpWidget(
      _wrap(
        PersonProfileScreen(
          person: mia,
          personStore: personStore,
          assetRecordStore: FakeAssetRecordStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await _add(tester, 'about', 'Impression');
    await tester.tap(find.byKey(const ValueKey('impression-tag-add')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(CupertinoTextField).last, 'Sardonic');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect((await personStore.detailFor(mia.id)).impression.tags, ['sardonic']);
    // Not "intense", which is what the old catch-all in the label lookup
    // would have shown for anything it did not recognise.
    expect(find.text('sardonic'), findsOneWidget);
    expect(find.text('intense'), findsOneWidget);
  });

  testWidgets('the keypad asks for the passphrase rather than doing nothing', (
    tester,
  ) async {
    await _useTallSurface(tester);
    final personStore = FakePersonStore();
    final keychain = FakeSecureStore();
    final vaultKeys = VaultKeys(store: keychain, derive: deriveOnThisIsolate);
    await vaultKeys.add('a good long passphrase', hint: 'the usual');
    // Exactly what Remove All App Data leaves behind: the entry is known,
    // the master key it derives is not.
    await vaultKeys.forgetOnThisDevice();
    final mia = await personStore.create(name: 'Mia');
    final assets = FakeAssetRecordStore();
    await PersonOwner(assets).set(mia.id);

    await tester.pumpWidget(
      _wrap(
        PersonProfileScreen(
          person: mia,
          personStore: personStore,
          assetRecordStore: assets,
          vaultKeys: vaultKeys,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(CupertinoIcons.number));
    await tester.pumpAndSettle();
    for (final digit in '1234'.split('')) {
      await tester.tap(find.text(digit));
      await tester.pump();
    }
    await tester.pumpAndSettle();

    // Before this it took the four digits and silently did nothing, which
    // reads as a broken button.
    expect(find.textContaining('the usual'), findsWidgets);
    await tester.enterText(
      find.byType(CupertinoTextField).last,
      'a good long passphrase',
    );
    await tester.pump();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    // Inside a set now, and it says so.
    expect(find.byIcon(CupertinoIcons.number_circle_fill), findsOneWidget);
  });

  testWidgets('the first-met row is a prompt until it is dated', (
    tester,
  ) async {
    await _useTallSurface(tester);
    final personStore = FakePersonStore();
    final mia = await personStore.create(name: 'Mia');

    await tester.pumpWidget(
      _wrap(
        PersonProfileScreen(
          person: mia,
          personStore: personStore,
          assetRecordStore: FakeAssetRecordStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await _add(tester, 'life', 'Events');
    // Always first, and nothing written until it is filled in.
    expect(find.text('First met'), findsOneWidget);
    expect(await personStore.eventsFor(mia.id), isEmpty);
    // No delete button on it, unlike every other event.
    expect(find.byIcon(CupertinoIcons.xmark_circle), findsNothing);

    await tester.tap(find.text('First met'));
    await tester.pumpAndSettle();
    // The type is not offered: there is exactly one of these.
    expect(find.text('Type'), findsNothing);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final saved = await personStore.eventsFor(mia.id);
    expect(saved.single.type, PersonEventType.firstMet);
    expect(saved.single.at, isNotNull);
  });

  testWidgets('an event carries a type, tags and notes', (tester) async {
    await _useTallSurface(tester);
    final personStore = FakePersonStore();
    final mia = await personStore.create(name: 'Mia');

    await tester.pumpWidget(
      _wrap(
        PersonProfileScreen(
          person: mia,
          personStore: personStore,
          assetRecordStore: FakeAssetRecordStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await _add(tester, 'life', 'Events');
    await tester.tap(find.byKey(profileSectionAddKey('Events')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Type'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Trip').last);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(CupertinoTextField, 'Separate with commas'),
      'kyoto, autumn',
    );
    await tester.enterText(
      find.widgetWithText(CupertinoTextField, 'Notes'),
      'the maple one',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final saved = (await personStore.eventsFor(mia.id)).single;
    expect(saved.type, PersonEventType.trip);
    expect(saved.tags, ['kyoto', 'autumn']);
    expect(saved.notes, 'the maple one');
  });

  testWidgets('linking two people creates a mirrored relationship', (
    tester,
  ) async {
    final personStore = FakePersonStore();
    final mia = await personStore.create(name: 'Mia');
    await personStore.create(name: 'Daniel');

    await tester.pumpWidget(
      _wrap(
        PersonProfileScreen(
          person: mia,
          personStore: personStore,
          assetRecordStore: FakeAssetRecordStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await _add(tester, 'people', 'Relationships');
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

  testWidgets('someone in the family group can still be made a spouse', (
    tester,
  ) async {
    await _useTallSurface(tester);
    final personStore = FakePersonStore();
    final mia = await personStore.create(name: 'Mia');
    final daniel = await personStore.create(name: 'Daniel');
    const smiths = PersonGroup(id: 'g', name: 'Smiths', kind: GroupKind.family);
    for (final p in [mia, daniel]) {
      await personStore.joinGroup(p.id, smiths, scope: PersonScope.open);
    }

    await tester.pumpWidget(
      _wrap(
        PersonProfileScreen(
          person: mia,
          personStore: personStore,
          assetRecordStore: FakeAssetRecordStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The family link alone isn't a relationship, so it is added from Add.
    await _tab(tester, 'people');
    expect(find.text('1 person', skipOffstage: false), findsOneWidget);
    await _add(tester, 'people', 'Relationships');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Daniel').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Spouse'));
    await tester.pumpAndSettle();

    final relationships = await personStore.relationshipsFor(mia.id);
    expect(relationships.single.type, RelationshipType.spouse);
    expect(find.text('via Smiths', skipOffstage: false), findsNothing);
  });

  testWidgets('a long relationship group shows every one, unfolded', (
    tester,
  ) async {
    final personStore = FakePersonStore();
    final mia = await personStore.create(name: 'Mia');
    for (var i = 0; i < 7; i++) {
      final f = await personStore.create(name: 'Friend $i');
      await personStore.addRelationship(
        mia.id,
        f.id,
        RelationshipType.friend,
        scope: PersonScope.open,
      );
    }

    await tester.pumpWidget(
      _wrap(
        PersonProfileScreen(
          person: mia,
          personStore: personStore,
          assetRecordStore: FakeAssetRecordStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _tab(tester, 'people');

    expect(
      find.textContaining('Friend ', skipOffstage: false),
      findsNWidgets(7),
    );
    expect(find.text('Show All (7)', skipOffstage: false), findsNothing);
  });

  testWidgets('typing a name and tapping create is the whole flow', (
    tester,
  ) async {
    final personStore = FakePersonStore();
    final mia = await personStore.create(name: 'Mia');

    await tester.pumpWidget(
      _wrap(
        PersonProfileScreen(
          person: mia,
          personStore: personStore,
          assetRecordStore: FakeAssetRecordStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await _add(tester, 'people', 'Relationships');
    await tester.enterText(find.byKey(searchPickerFieldKey), 'Ada');
    await tester.pumpAndSettle();

    // The row says what it will do, and doing it doesn't ask again — the
    // name has already been typed once.
    expect(find.text('New Person “Ada”'), findsOneWidget);
    await tester.tap(find.text('New Person “Ada”'));
    await tester.pumpAndSettle();

    expect(
      find.text('Add').hitTestable(),
      findsNothing,
      reason: 'no second prompt',
    );
    await tester.tap(find.text('Family'));
    await tester.pumpAndSettle();

    expect(
      (await personStore.listAll()).map((p) => p.name),
      containsAll(['Mia', 'Ada']),
    );
  });

  testWidgets('the keyboard\'s Done key creates and links them too', (
    tester,
  ) async {
    final personStore = FakePersonStore();
    final mia = await personStore.create(name: 'Mia');

    await tester.pumpWidget(
      _wrap(
        PersonProfileScreen(
          person: mia,
          personStore: personStore,
          assetRecordStore: FakeAssetRecordStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await _add(tester, 'people', 'Relationships');
    await tester.enterText(find.byKey(searchPickerFieldKey), 'Grandma Lily');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Family'));
    await tester.pumpAndSettle();

    expect(
      (await personStore.listAll()).map((p) => p.name),
      containsAll(['Mia', 'Grandma Lily']),
    );
    final relationships = await personStore.relationshipsFor(mia.id);
    expect(relationships.single.type, RelationshipType.family);
  });

  testWidgets('Done on a name already in the list picks that one', (
    tester,
  ) async {
    final personStore = FakePersonStore();
    final mia = await personStore.create(name: 'Mia');
    await personStore.create(name: 'Daniel');

    await tester.pumpWidget(
      _wrap(
        PersonProfileScreen(
          person: mia,
          personStore: personStore,
          assetRecordStore: FakeAssetRecordStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await _add(tester, 'people', 'Relationships');
    await tester.enterText(find.byKey(searchPickerFieldKey), 'daniel');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Family'));
    await tester.pumpAndSettle();

    // One Daniel, not a second one spelled differently.
    expect((await personStore.listAll()), hasLength(2));
  });

  testWidgets(
    'picking Colleague prompts for a company, saved with the relationship',
    (tester) async {
      final personStore = FakePersonStore();
      final mia = await personStore.create(name: 'Mia');
      await personStore.create(name: 'Daniel');

      await tester.pumpWidget(
        _wrap(
          PersonProfileScreen(
            person: mia,
            personStore: personStore,
            assetRecordStore: FakeAssetRecordStore(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await _add(tester, 'people', 'Relationships');
      await tester.tap(find.text('Daniel'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Colleague'));
      await tester.pumpAndSettle();

      // The organization prompt is labeled "Company" for colleagues.
      expect(find.text('Company'), findsWidgets);
      await tester.enterText(find.byKey(searchPickerFieldKey), 'Acme Corp');
      await tester.pump();
      await tester.tap(find.text('Use “Acme Corp”'));
      await tester.pumpAndSettle();

      final relationships = await personStore.relationshipsFor(mia.id);
      expect(relationships.single.type, RelationshipType.colleague);
      expect(relationships.single.organization, 'Acme Corp');
      expect(
        find.textContaining('Acme Corp', skipOffstage: false),
        findsOneWidget,
      );
    },
  );

  testWidgets('tapping a relationship row\'s name opens that person\'s page', (
    tester,
  ) async {
    final personStore = FakePersonStore();
    final mia = await personStore.create(name: 'Mia');
    final daniel = await personStore.create(name: 'Daniel');
    await personStore.addRelationship(
      mia.id,
      daniel.id,
      RelationshipType.friend,
      scope: PersonScope.open,
    );

    await tester.pumpWidget(
      _wrap(
        PersonProfileScreen(
          person: mia,
          personStore: personStore,
          assetRecordStore: FakeAssetRecordStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _tab(tester, 'people');

    await _scrollTo(tester, find.text('Daniel', skipOffstage: false));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Daniel'));
    await tester.pumpAndSettle();

    // Lands on Daniel's own page, not an edit sheet — the navigation bar's
    // back button is the giveaway there's a new page, and Daniel's name now
    // appears twice (his page's title plus the row still underneath).
    expect(find.text('Daniel'), findsWidgets);
    expect(find.byType(CupertinoNavigationBarBackButton), findsOneWidget);
  });

  testWidgets('in Edit, tapping a relationship re-opens the picker', (
    tester,
  ) async {
    final personStore = FakePersonStore();
    final mia = await personStore.create(name: 'Mia');
    final daniel = await personStore.create(name: 'Daniel');
    await personStore.addRelationship(
      mia.id,
      daniel.id,
      RelationshipType.friend,
      scope: PersonScope.open,
    );

    await tester.pumpWidget(
      _wrap(
        PersonProfileScreen(
          person: mia,
          personStore: personStore,
          assetRecordStore: FakeAssetRecordStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _tab(tester, 'people');

    final edit = find.byKey(profileSectionEditKey('Relationships'));
    await _scrollTo(tester, edit);
    await tester.tap(edit);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(CupertinoListTile, 'Daniel'));
    await tester.pumpAndSettle();
    // The picker is a sheet over the page; the row behind it still carries
    // a "Daniel" of its own — `.last` is the sheet's.
    await tester.tap(find.text('Daniel').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sibling'));
    await tester.pumpAndSettle();

    final relationships = await personStore.relationshipsFor(mia.id);
    expect(relationships.single.type, RelationshipType.sibling);
  });

  testWidgets('a relationship swiped away is gone, and Undo brings it back', (
    tester,
  ) async {
    final personStore = FakePersonStore();
    final mia = await personStore.create(name: 'Mia');
    final daniel = await personStore.create(name: 'Daniel');
    await personStore.addRelationship(
      mia.id,
      daniel.id,
      RelationshipType.friend,
      scope: PersonScope.open,
    );

    await tester.pumpWidget(
      _wrap(
        PersonProfileScreen(
          person: mia,
          personStore: personStore,
          assetRecordStore: FakeAssetRecordStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _tab(tester, 'people');

    final row = find.widgetWithText(CupertinoListTile, 'Daniel');
    await _scrollTo(tester, row);
    await tester.drag(row, const Offset(-600, 0));
    await tester.pumpAndSettle();

    expect(await personStore.relationshipsFor(mia.id), isEmpty);
    expect(find.text('Removed Daniel'), findsOneWidget);
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(
      (await personStore.relationshipsFor(mia.id)).single.type,
      RelationshipType.friend,
    );
  });

  testWidgets('relationships are grouped into subsections by type', (
    tester,
  ) async {
    await _useTallSurface(tester);
    final personStore = FakePersonStore();
    final mia = await personStore.create(name: 'Mia');
    final daniel = await personStore.create(name: 'Daniel');
    final lily = await personStore.create(name: 'Grandma Lily');
    await personStore.addRelationship(
      mia.id,
      daniel.id,
      RelationshipType.friend,
      scope: PersonScope.open,
    );
    await personStore.addRelationship(
      mia.id,
      lily.id,
      RelationshipType.family,
      scope: PersonScope.open,
    );

    await tester.pumpWidget(
      _wrap(
        PersonProfileScreen(
          person: mia,
          personStore: personStore,
          assetRecordStore: FakeAssetRecordStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _tab(tester, 'people');

    // One subsection header per type in use, each above only that type's rows.
    expect(find.text('Friend', skipOffstage: false), findsOneWidget);
    expect(find.text('Family', skipOffstage: false), findsOneWidget);
    expect(find.text('Colleague', skipOffstage: false), findsNothing);
  });

  testWidgets('places lived show a year range, most recent one open-ended', (
    tester,
  ) async {
    final personStore = FakePersonStore();
    final mia = await personStore.create(name: 'Mia');
    await personStore.addLocation(
      PersonLocation(
        id: 'loc-1',
        personId: mia.id,
        kind: LocationKind.origin,
        place: 'Shanghai',
        since: DateTime(1995),
      ),
      scope: PersonScope.open,
    );
    await personStore.addLocation(
      PersonLocation(
        id: 'loc-2',
        personId: mia.id,
        kind: LocationKind.relocation,
        place: 'Beijing',
        since: DateTime(2010),
      ),
      scope: PersonScope.open,
    );

    await tester.pumpWidget(
      _wrap(
        PersonProfileScreen(
          person: mia,
          personStore: personStore,
          assetRecordStore: FakeAssetRecordStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _tab(tester, 'life');

    // Shanghai: 1995, the year Beijing (the next stop) starts. Beijing is
    // still current, so it's open-ended.
    expect(find.text('1995 – 2010', skipOffstage: false), findsOneWidget);
    expect(find.text('2010 – Present', skipOffstage: false), findsOneWidget);
    expect(find.text('Hometown', skipOffstage: false), findsNothing);
    expect(find.text('Moved To', skipOffstage: false), findsNothing);
  });

  testWidgets(
    'a job entry shows its latest title on top, employer as subtitle',
    (tester) async {
      final personStore = FakePersonStore();
      final mia = await personStore.create(name: 'Mia');
      await personStore.addHistoryEntry(
        PersonHistoryEntry(
          id: 'e1',
          personId: mia.id,
          category: HistoryCategory.job,
          title: 'Acme Corp',
          titles: const [TimelineEntry(id: 't1', title: 'Senior Engineer')],
        ),
        scope: PersonScope.open,
      );

      await tester.pumpWidget(
        _wrap(
          PersonProfileScreen(
            person: mia,
            personStore: personStore,
            assetRecordStore: FakeAssetRecordStore(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _tab(tester, 'life');

      expect(find.text('Senior Engineer', skipOffstage: false), findsOneWidget);
      expect(find.text('Acme Corp', skipOffstage: false), findsOneWidget);
    },
  );

  testWidgets('tapping a location row edits it in place, without duplicating', (
    tester,
  ) async {
    final personStore = FakePersonStore();
    final mia = await personStore.create(name: 'Mia');
    await personStore.addLocation(
      PersonLocation(
        id: 'loc-1',
        personId: mia.id,
        kind: LocationKind.origin,
        place: 'Shanghai',
        since: DateTime(1995),
      ),
      scope: PersonScope.open,
    );

    await tester.pumpWidget(
      _wrap(
        PersonProfileScreen(
          person: mia,
          personStore: personStore,
          assetRecordStore: FakeAssetRecordStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _tab(tester, 'life');

    final row = find.widgetWithText(CupertinoListTile, 'Shanghai');
    await _scrollTo(tester, row);
    await tester.tap(row);
    await tester.pumpAndSettle();
    // Pre-filled from the existing entry.
    expect(find.text('Edit Location'), findsOneWidget);
    expect(find.widgetWithText(CupertinoTextField, 'Shanghai'), findsOneWidget);

    await tester.enterText(
      find.widgetWithText(CupertinoTextField, 'Shanghai'),
      'Beijing',
    );
    await tester.pump();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final locations = await personStore.locationsFor(mia.id);
    expect(locations, hasLength(1));
    expect(locations.single.place, 'Beijing');
  });

  testWidgets('a place swiped away can be put back', (tester) async {
    final personStore = FakePersonStore();
    final mia = await personStore.create(name: 'Mia');
    await personStore.addLocation(
      PersonLocation(
        id: 'loc-1',
        personId: mia.id,
        kind: LocationKind.origin,
        place: 'Shanghai',
        since: DateTime(1995),
      ),
      scope: PersonScope.open,
    );
    await tester.pumpWidget(
      _wrap(
        PersonProfileScreen(
          person: mia,
          personStore: personStore,
          assetRecordStore: FakeAssetRecordStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _tab(tester, 'life');
    final row = find.widgetWithText(CupertinoListTile, 'Shanghai');
    await _scrollTo(tester, row);
    await tester.drag(row, const Offset(-600, 0));
    await tester.pumpAndSettle();
    expect(await personStore.locationsFor(mia.id), isEmpty);

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect((await personStore.locationsFor(mia.id)).single.place, 'Shanghai');
  });

  testWidgets(
    'Relationships under People, Places Lived under Life, More details through Add',
    (tester) async {
      await _useTallSurface(tester);
      final personStore = FakePersonStore();
      final mia = await personStore.create(name: 'Mia');
      final dan = await personStore.create(name: 'Daniel');
      await personStore.addRelationship(
        mia.id,
        dan.id,
        RelationshipType.friend,
        scope: PersonScope.open,
      );
      await personStore.addLocation(
        PersonLocation(
          id: 'loc-1',
          personId: mia.id,
          kind: LocationKind.origin,
          place: 'Shanghai',
          since: DateTime(1995),
        ),
        scope: PersonScope.open,
      );

      await tester.pumpWidget(
        _wrap(
          PersonProfileScreen(
            person: mia,
            personStore: personStore,
            assetRecordStore: FakeAssetRecordStore(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Relationships'), findsNothing);
      await _tab(tester, 'people');
      expect(find.text('Relationships'), findsOneWidget);
      expect(find.text('Places Lived'), findsNothing);
      await _tab(tester, 'life');
      expect(find.text('Places Lived'), findsOneWidget);

      await _add(tester, 'about', 'More Details');
      // The usual labels are offered first; Other asks for a label.
      expect(find.text('WeChat'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('customFieldOther')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(CupertinoTextField).last, 'Nickname');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(CupertinoTextField).last, 'Mimi');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final saved = await personStore.detailFor(mia.id);
      expect(saved.customFields.single.label, 'Nickname');
      expect(saved.customFields.single.value, 'Mimi');
    },
  );

  testWidgets('a profile says how its person stands to you', (tester) async {
    await _useTallSurface(tester);
    final personStore = FakePersonStore();
    final assets = FakeAssetRecordStore();
    final me = await personStore.create(name: 'Solomon');
    final mia = await personStore.create(name: 'Mia');
    await personStore.addRelationship(
      mia.id,
      me.id,
      RelationshipType.sibling,
      scope: PersonScope.open,
    );
    await assets.setAppState(PersonOwner.key, me.id);

    await tester.pumpWidget(
      _wrap(
        PersonProfileScreen(
          person: mia,
          personStore: personStore,
          assetRecordStore: assets,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Your sibling'), findsOneWidget);
  });

  testWidgets('with nobody marked as you, it says nothing', (tester) async {
    await _useTallSurface(tester);
    final personStore = FakePersonStore();
    final me = await personStore.create(name: 'Solomon');
    final mia = await personStore.create(name: 'Mia');
    await personStore.addRelationship(
      mia.id,
      me.id,
      RelationshipType.sibling,
      scope: PersonScope.open,
    );

    await tester.pumpWidget(
      _wrap(
        PersonProfileScreen(
          person: mia,
          personStore: personStore,
          assetRecordStore: FakeAssetRecordStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Your sibling'), findsNothing);
  });

  testWidgets('group links stay under Groups, as a row that opens the group', (
    tester,
  ) async {
    await _useTallSurface(tester);
    final personStore = FakePersonStore();
    final mia = await personStore.create(name: 'Mia');
    await personStore.create(name: 'Daniel');
    const acme = PersonGroup(id: 'g1', name: 'Acme', kind: GroupKind.company);
    await personStore.joinGroup(mia.id, acme, scope: PersonScope.open);
    for (final p in await personStore.listAll()) {
      await personStore.joinGroup(p.id, acme, scope: PersonScope.open);
    }

    await tester.pumpWidget(
      _wrap(
        PersonProfileScreen(
          person: mia,
          personStore: personStore,
          assetRecordStore: FakeAssetRecordStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _tab(tester, 'people');

    // Not repeated as relationships: those are only the ones added by hand.
    expect(find.byKey(profileSectionHeaderKey('Relationships')), findsNothing);
    expect(find.text('via Acme', skipOffstage: false), findsNothing);
    expect(find.text('1 person'), findsOneWidget);
    await tester.tap(find.text('Colleagues at Acme'));
    await tester.pumpAndSettle();
    expect(find.text('Daniel'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('profilePeopleSearch')),
      'zzz',
    );
    await tester.pump();
    expect(find.text('Daniel'), findsNothing);
  });

  testWidgets('deleting a person says their photos and hidden folder go '
      'with them', (tester) async {
    final personStore = FakePersonStore();
    final records = FakeAssetRecordStore();
    final mia = await personStore.create(name: 'Mia');
    await records.upsert(localId: 'h1', contentHash: 'c', platform: 'ios');
    await records.setPasscodeHash(
      'h1',
      hashPasscode(personAlbumCode(mia.id, '0420')),
    );

    await tester.pumpWidget(
      _wrap(
        PersonProfileScreen(
          person: mia,
          personStore: personStore,
          assetRecordStore: records,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('profileMore')));
    await tester.pumpAndSettle();
    final delete = find.text('Delete Person');
    // The codes are tried on another isolate, which only answers on the
    // real clock.
    await tester.tap(delete);
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(seconds: 2)),
    );
    await tester.pumpAndSettle();

    expect(find.text('Delete this person?'), findsOneWidget);
    expect(
      find.textContaining(
        'Their hidden folder and the 1 photo in it are deleted',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(await personStore.getById(mia.id), isNotNull);
  });

  test('only this person\'s codes count as their hidden folder', () async {
    final records = FakeAssetRecordStore();
    await records.upsert(localId: 'h1', contentHash: 'c', platform: 'ios');
    await records.setPasscodeHash(
      'h1',
      hashPasscode(personAlbumCode('someone-else', '0420')),
    );
    expect(await personHasHiddenFolder(records, 'mia'), isFalse);

    await records.setPasscodeHash(
      'h1',
      hashPasscode(personAlbumCode('mia', '9999')),
    );
    expect(await personHasHiddenFolder(records, 'mia'), isTrue);
  });
}
