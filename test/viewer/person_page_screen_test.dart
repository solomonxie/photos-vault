import 'package:back_your_own_photos/l10n/app_localizations.dart';
import 'package:back_your_own_photos/storage/asset_record.dart';
import 'package:back_your_own_photos/viewer/person_page_screen.dart';
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
  testWidgets('shows only this person\'s tagged photos', (tester) async {
    final assetStore = FakeAssetRecordStore();
    final personStore = FakePersonStore();
    await assetStore.upsert(
      localId: 'manual:tagged',
      contentHash: 'tagged',
      platform: 'ios',
      sourceType: AssetSourceType.manualFile,
      sourcePath: '/tmp/tagged.jpg',
    );
    await assetStore.upsert(
      localId: 'manual:other',
      contentHash: 'other',
      platform: 'ios',
      sourceType: AssetSourceType.manualFile,
      sourcePath: '/tmp/other.jpg',
    );
    final person = await personStore.create(name: 'Mia');
    await personStore.addAssets(person.id, ['manual:tagged']);

    await tester.pumpWidget(
      _wrap(PersonPageScreen(person: person, personStore: personStore, assetRecordStore: assetStore)),
    );
    await tester.pumpAndSettle();

    expect(find.text('Mia'), findsWidgets);
    expect(find.byKey(const ValueKey('manual:tagged')), findsOneWidget);
    expect(find.byKey(const ValueKey('manual:other')), findsNothing);
  });

  testWidgets('shows the empty state with nothing tagged', (tester) async {
    final personStore = FakePersonStore();
    final person = await personStore.create(name: 'Mia');

    await tester.pumpWidget(
      _wrap(PersonPageScreen(person: person, personStore: personStore, assetRecordStore: FakeAssetRecordStore())),
    );
    await tester.pumpAndSettle();

    expect(find.text('No photos tagged yet.'), findsOneWidget);
  });
}
