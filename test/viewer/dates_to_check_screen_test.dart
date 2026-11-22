import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/l10n/app_localizations.dart';
import 'package:photos_vault/storage/asset_record.dart';
import 'package:photos_vault/viewer/dates_to_check_screen.dart';

import '../support/fake_asset_record_store.dart';

void main() {
  testWidgets('file name dates are used in one tap; no-date files are listed', (
    tester,
  ) async {
    final store = FakeAssetRecordStore();
    final added = DateTime(2026, 5, 1, 9);
    await store.upsert(
      localId: 'named',
      contentHash: 'n',
      platform: 'ios',
      sourceType: AssetSourceType.manualFile,
      sourcePath: '/x/IMG_20120304_101112.jpg',
      createdAt: added,
      addedAt: added,
    );
    await store.upsert(
      localId: 'bare',
      contentHash: 'b',
      platform: 'ios',
      sourceType: AssetSourceType.manualFile,
      sourcePath: '/x/scan.jpg',
      createdAt: added,
      addedAt: added,
    );
    await tester.pumpWidget(
      CupertinoApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: DatesToCheckScreen(store: store),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('dateCheck:named')), findsOneWidget);
    expect(find.byKey(const ValueKey('dateCheck:bare')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('datesUseAll')));
    await tester.pumpAndSettle();
    expect(
      (await store.getByLocalId('named'))!.createdAt,
      DateTime(2012, 3, 4, 10, 11, 12),
    );
    expect(find.byKey(const ValueKey('dateCheck:named')), findsNothing);
    expect(find.byKey(const ValueKey('dateCheck:bare')), findsOneWidget);
  });
}
