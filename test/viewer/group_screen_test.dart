import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/l10n/app_localizations.dart';
import 'package:photos_vault/photos/person.dart';
import 'package:photos_vault/photos/person_store.dart';
import 'package:photos_vault/viewer/asset_group_screen.dart';
import 'package:photos_vault/viewer/group_screen.dart';

import '../support/fake_asset_record_store.dart';
import '../support/fake_person_store.dart';

Widget _wrap(Widget child) => CupertinoApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  locale: const Locale('en'),
  home: CupertinoPageScaffold(
    child: Builder(
      builder: (context) => Center(
        child: CupertinoButton(
          onPressed: () =>
              Navigator.of(context)
                  .push(CupertinoPageRoute<void>(builder: (_) => child)),
          child: const Text('open'),
        ),
      ),
    ),
  ),
);

void main() {
  const acme = PersonGroup(id: 'g1', name: 'Acme', kind: GroupKind.company);
  const club = PersonGroup(id: 'g2', name: 'Club', kind: GroupKind.circle);

  Future<(FakePersonStore, FakeAssetRecordStore, Person, Person)>
  seeded() async {
    final people = FakePersonStore();
    final photos = FakeAssetRecordStore();
    for (final id in ['a', 'b']) {
      await photos.upsert(localId: id, contentHash: id, platform: 'ios');
    }
    await photos.listAll();
    final mia = await people.create(name: 'Mia');
    final dan = await people.create(name: 'Dan');
    await people.addAssets(mia.id, ['a']);
    await people.addAssets(dan.id, ['a', 'b']);
    await people.joinGroup(mia.id, acme, scope: PersonScope.open);
    await people.joinGroup(dan.id, acme, scope: PersonScope.open);
    await people.joinGroup(dan.id, club, scope: PersonScope.open);
    return (people, photos, mia, dan);
  }

  Future<void> open(
    WidgetTester tester,
    FakePersonStore people,
    FakeAssetRecordStore photos,
  ) async {
    await tester.pumpWidget(
      _wrap(
        GroupScreen(group: acme, personStore: people, assetRecordStore: photos),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('Photos is everyone\'s photos once each', (tester) async {
    final (people, photos, _, _) = await seeded();
    await open(tester, people, photos);
    final row = find.byKey(const ValueKey('groupPhotos'));
    expect(find.descendant(of: row, matching: find.text('2')), findsOneWidget);
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(
      tester.widget<AssetGroupScreen>(find.byType(AssetGroupScreen)).records,
      hasLength(2),
    );
  });

  testWidgets('merge moves everyone into the other group and drops this', (
    tester,
  ) async {
    final (people, photos, mia, dan) = await seeded();
    await open(tester, people, photos);
    await tester.ensureVisible(find.byKey(const ValueKey('groupMergeInto')));
    await tester.tap(find.byKey(const ValueKey('groupMergeInto')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Club').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('groupMergeConfirm')));
    await tester.pumpAndSettle();

    final groups = await people.allGroups();
    expect([for (final g in groups.keys) g.id], ['g2']);
    expect(groups.values.single.toSet(), {mia.id, dan.id});
    expect(find.byType(GroupScreen), findsNothing);
  });
}
