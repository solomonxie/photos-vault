import 'package:bring_your_own_photos/l10n/app_localizations.dart';
import 'package:bring_your_own_photos/storage/asset_record.dart';
import 'package:bring_your_own_photos/viewer/recently_deleted_screen.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_asset_record_store.dart';

Widget _wrap(Widget child) => CupertinoApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: child,
);

void main() {
  testWidgets('shows only deleted items', (tester) async {
    final store = FakeAssetRecordStore();
    await store.upsert(
      localId: 'manual:deleted',
      contentHash: 'd',
      platform: 'ios',
      sourceType: AssetSourceType.manualFile,
      sourcePath: '/tmp/d.jpg',
    );
    await store.softDelete('manual:deleted');
    await store.upsert(
      localId: 'manual:active',
      contentHash: 'a',
      platform: 'ios',
      sourceType: AssetSourceType.manualFile,
      sourcePath: '/tmp/a.jpg',
    );

    await tester.pumpWidget(_wrap(RecentlyDeletedScreen(assetRecordStore: store)));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('manual:deleted')), findsOneWidget);
    expect(find.byKey(const ValueKey('manual:active')), findsNothing);
  });

  testWidgets('shows the empty state with nothing deleted', (tester) async {
    await tester.pumpWidget(_wrap(RecentlyDeletedScreen(assetRecordStore: FakeAssetRecordStore())));
    await tester.pumpAndSettle();

    expect(find.text('No recently deleted items.'), findsOneWidget);
  });
}
