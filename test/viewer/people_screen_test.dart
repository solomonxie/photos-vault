import 'package:photos_vault/l10n/app_localizations.dart';
import 'package:photos_vault/viewer/people_screen.dart';
import 'package:photos_vault/viewer/person_profile_screen.dart';
import 'package:photos_vault/viewer/person_page_screen.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';

import 'dart:typed_data';

import 'package:photos_vault/photos/face_identity.dart';
import 'package:photos_vault/photos/on_device_vision.dart';
import 'package:photos_vault/photos/person.dart';
import 'package:photos_vault/photos/person_detail.dart';

import '../support/fake_ai_analysis_store.dart';
import '../support/fake_asset_record_store.dart';
import '../support/fake_person_store.dart';

Widget _wrap(Widget child) => CupertinoApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: child,
);

const _face = FaceRect(0.3, 0.3, 0.4, 0.4);

void main() {
  /// A library with one photo, one face found in it, and — where [guess]
  /// is given — a name the matcher put to that face.
  Future<(FakeAiAnalysisStore, FakeAssetRecordStore)> seed({
    String? guess,
  }) async {
    final records = FakeAssetRecordStore();
    await records.upsert(localId: 'p1', contentHash: 'p1', platform: 'ios');
    final analyses = FakeAiAnalysisStore();
    await analyses.saveFaceCount(
      localId: 'p1',
      peopleCount: 1,
      analyzedAt: DateTime(2026),
      faces: const [_face],
    );
    await analyses.saveSuggestions('p1', {_face.encode(): guess});
    return (analyses, records);
  }

  testWidgets('a face the app has a guess about reads as that name', (
    tester,
  ) async {
    final personStore = FakePersonStore();
    final nina = await personStore.create(name: 'Nina');
    final (analyses, records) = await seed(guess: nina.id);

    await tester.pumpWidget(
      _wrap(
        PeopleScreen(
          personStore: personStore,
          assetRecordStore: records,
          aiAnalysisStore: analyses,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Nina?'), findsOneWidget);
    expect(find.text("Who's this?"), findsNothing);
    // The count answers "is the scan finding anything?", which the first
    // twenty rows can't.
    expect(find.text('1'), findsOneWidget);
  });

  testWidgets('faces that look alike are one circle, not three', (
    tester,
  ) async {
    // Three photos of the same stranger is one question, not three.
    final records = FakeAssetRecordStore();
    final analyses = FakeAiAnalysisStore();
    for (final (id, v) in [
      // Newest first in the list is 'p1'; the bigger pile is 'q*', which
      // is what makes this a test of ordering and not of arrival.
      ('p1', [1.0, 0.0, 0.0]),
      ('p2', [1.0, 0.02, 0.0]),
      ('q1', [0.0, 1.0, 0.0]),
      ('q2', [0.02, 1.0, 0.0]),
      ('q3', [0.03, 1.0, 0.0]),
    ]) {
      await records.upsert(localId: id, contentHash: id, platform: 'ios');
      await analyses.saveFaceCount(
        localId: id,
        peopleCount: 1,
        analyzedAt: DateTime(2026),
        faces: const [_face],
      );
      await analyses.saveDescriptor(
        localId: id,
        face: _face,
        descriptor: FaceDescriptor(
          vector: Float32List.fromList(v),
          revision: FaceDescriptor.combineRevision(
            1,
            FaceDescriptor.currentPipeline,
          ),
        ),
      );
    }

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

    // Two circles for five faces: two alike, and three alike.
    expect(find.text("Who's this?"), findsNWidgets(2));
    // The pile behind each circle says how big it is, and the biggest
    // comes first — naming it sorts three photos, not two.
    expect(find.text('3'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('3')).dy,
      lessThan(tester.getTopLeft(find.text('2')).dy),
    );
    // The heading still reports every face outstanding, not every circle.
    expect(find.text('5'), findsOneWidget);
  });

  testWidgets('a face with no guess still reads as a question', (tester) async {
    final (analyses, records) = await seed();

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

    expect(find.text("Who's this?"), findsOneWidget);
  });

  testWidgets('a guess for somebody since deleted is a question again', (
    tester,
  ) async {
    // The name is gone, so the guess can't be shown under it — and must
    // not be shown under nothing either.
    final (analyses, records) = await seed(guess: 'ghost');

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

    expect(find.text("Who's this?"), findsOneWidget);
  });

  testWidgets('one tap accepts the guess, and Undo takes it back', (
    tester,
  ) async {
    final personStore = FakePersonStore();
    final nina = await personStore.create(name: 'Nina');
    final (analyses, records) = await seed(guess: nina.id);
    final identity = FaceIdentityService(
      analysisStore: analyses,
      resolvePath: (_) async => null,
    );

    await tester.pumpWidget(
      _wrap(
        PeopleScreen(
          personStore: personStore,
          assetRecordStore: records,
          aiAnalysisStore: analyses,
          faceIdentity: identity,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(CupertinoIcons.checkmark_circle_fill));
    await tester.pumpAndSettle();

    expect(await personStore.localIdsIn(nina.id), ['p1']);
    // The row was the question; answering it takes the row away.
    expect(find.text('Nina?'), findsNothing);
    expect(find.text('Added to Nina'), findsOneWidget);

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();

    expect(await personStore.localIdsIn(nina.id), isEmpty);
    expect(find.text('Nina?'), findsOneWidget);
  });

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

  testWidgets('the most photographed person is first', (tester) async {
    final personStore = FakePersonStore();
    final few = await personStore.create(name: 'Ana');
    await personStore.addAssets(few.id, ['p1']);
    final many = await personStore.create(name: 'Bo');
    await personStore.addAssets(many.id, ['p2', 'p3', 'p4']);

    await tester.pumpWidget(
      _wrap(
        PeopleScreen(
          personStore: personStore,
          assetRecordStore: FakeAssetRecordStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Naming and reviewing both start at the top; the person you have
    // most photos of is the one you came here about.
    expect(
      tester.getTopLeft(find.text('Bo')).dy,
      lessThan(tester.getTopLeft(find.text('Ana')).dy),
    );
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
  testWidgets('chips narrow the list, and a group is one of them', (
    tester,
  ) async {
    final personStore = FakePersonStore();
    final mia = await personStore.create(name: 'Mia');
    final dan = await personStore.create(name: 'Daniel');
    await personStore.create(name: 'Zoe');
    await personStore.saveDetail(
      mia.id,
      const PersonDetail(gender: Gender.female),
    );
    await personStore.saveDetail(
      dan.id,
      const PersonDetail(gender: Gender.male),
    );
    const acme = PersonGroup(id: 'g1', name: 'Acme', kind: GroupKind.company);
    await personStore.joinGroup(mia.id, acme);
    await personStore.joinGroup(dan.id, acme);

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

    await tester.tap(find.byKey(const ValueKey('people-filter-female')));
    await tester.pumpAndSettle();
    expect(find.text('Mia'), findsOneWidget);
    expect(find.text('Daniel'), findsNothing);
    expect(find.text('Zoe'), findsNothing);

    // The group chip, and the group row, are the same filter.
    await tester.tap(find.byKey(const ValueKey('people-filter-g1')));
    await tester.pumpAndSettle();
    expect(find.text('Mia'), findsOneWidget);
    expect(find.text('Daniel'), findsOneWidget);
    expect(find.text('Zoe'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('people-filter-all')));
    await tester.pumpAndSettle();
    expect(find.text('Zoe'), findsOneWidget);
  });
}
