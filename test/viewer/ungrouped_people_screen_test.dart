import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/l10n/app_localizations.dart';
import 'package:photos_vault/photos/person.dart';
import 'package:photos_vault/photos/person_store.dart';
import 'package:photos_vault/viewer/search_picker_sheet.dart';
import 'package:photos_vault/viewer/ungrouped_people_screen.dart';

import '../support/fake_asset_record_store.dart';
import '../support/fake_person_store.dart';

Widget _wrap(Widget child) => CupertinoApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  locale: const Locale('en'),
  home: child,
);

void main() {
  test('ungrouped: no group, not locked, most photos first', () async {
    final people = FakePersonStore();
    final few = await people.create(name: 'Few');
    final many = await people.create(name: 'Many');
    final grouped = await people.create(name: 'Grouped');
    final locked = await people.create(name: 'Locked');
    await people.update(locked.copyWith(locked: true));
    await people.addAssets(many.id, ['a', 'b']);
    await people.joinGroup(
      grouped.id,
      const PersonGroup(id: 'g', name: 'Work', kind: GroupKind.company),
      scope: PersonScope.open,
    );
    expect(
      [for (final p in await ungroupedPeople(people)) p.id],
      [many.id, few.id],
    );
  });

  testWidgets('tick, add to a new group, and they leave the list', (
    tester,
  ) async {
    final people = FakePersonStore();
    final mia = await people.create(name: 'Mia');
    final tom = await people.create(name: 'Tom');
    await tester.pumpWidget(
      _wrap(
        UngroupedPeopleScreen(
          people: [mia, tom],
          personStore: people,
          assetRecordStore: FakeAssetRecordStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final add = find.byKey(const ValueKey('ungroupedAddToGroup'));
    expect(tester.widget<CupertinoButton>(add).onPressed, isNull);

    await tester.tap(find.byKey(ValueKey('ungrouped-${mia.id}')));
    await tester.pump();
    await tester.tap(add);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(searchPickerFieldKey), 'Family');
    await tester.pumpAndSettle();
    await tester.tap(find.text('New Group "Family"'));
    await tester.pumpAndSettle();

    expect(find.text('Mia'), findsNothing);
    expect(find.text('Tom'), findsOneWidget);
    final groups = await people.allGroups();
    expect(groups.values.single, [mia.id]);
  });
}
