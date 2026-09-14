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
  testWidgets('editing a field persists it to the store', (tester) async {
    final personStore = FakePersonStore();
    final person = await personStore.create(name: 'Mia');

    await tester.pumpWidget(
      _wrap(PersonProfileScreen(person: person, personStore: personStore, assetRecordStore: FakeAssetRecordStore())),
    );
    await tester.pumpAndSettle();

    // Fields render in order: Name, Education, Job, About, Family/Relatives.
    await tester.enterText(find.byType(CupertinoTextField).at(1), 'MIT');
    await tester.pump();

    expect((await personStore.getById(person.id))!.education, 'MIT');
  });

  testWidgets('locked profile hides fields until the correct passcode is entered', (tester) async {
    final personStore = FakePersonStore();
    final locked = await personStore.create(name: 'Mia');
    await personStore.update(
      locked.copyWith(
        locked: true,
        education: 'MIT',
        passcodeHash: () => hashPasscode('secret'),
        passcodeHint: () => 'pet name',
      ),
    );
    final reloaded = (await personStore.getById(locked.id))!;

    await tester.pumpWidget(
      _wrap(PersonProfileScreen(person: reloaded, personStore: personStore, assetRecordStore: FakeAssetRecordStore())),
    );
    await tester.pumpAndSettle();

    expect(find.text("This profile's details are locked."), findsOneWidget);
    expect(find.text('Hint: pet name'), findsOneWidget);
    // Only the Name field renders while locked.
    expect(find.byType(CupertinoTextField), findsOneWidget);

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

    // Name + Education + Job + About + Family/Relatives, all unlocked now.
    expect(find.byType(CupertinoTextField), findsNWidgets(5));
  });

  testWidgets('linking two people creates a mirrored relationship', (tester) async {
    final personStore = FakePersonStore();
    final mia = await personStore.create(name: 'Mia');
    await personStore.create(name: 'Daniel');

    await tester.pumpWidget(
      _wrap(PersonProfileScreen(person: mia, personStore: personStore, assetRecordStore: FakeAssetRecordStore())),
    );
    await tester.pumpAndSettle();

    // The "+" next to the Relationships header (the first of two —
    // Location History has its own further down).
    await tester.tap(find.byIcon(CupertinoIcons.add_circled).first);
    await tester.pumpAndSettle();
    expect(find.text('Daniel'), findsOneWidget);
    await tester.tap(find.text('Daniel'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Friend'));
    await tester.pumpAndSettle();

    // The new relationship row lands below the fold in the profile's
    // ListView (Education/Job/About/Relatives push it down), so it's
    // offstage rather than absent.
    expect(find.text('Daniel', skipOffstage: false), findsOneWidget);
    final relationships = await personStore.relationshipsFor(mia.id);
    expect(relationships.single.type, RelationshipType.friend);
  });
}
