import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/l10n/app_localizations.dart';
import 'package:photos_vault/storage/asset_record.dart';
import 'package:photos_vault/viewer/asset_picker_screen.dart';

import '../support/fake_asset_record_store.dart';

void main() {
  testWidgets('a tapped tile shows as checked', (tester) async {
    final store = FakeAssetRecordStore();
    await store.upsert(
      localId: 'manual:a',
      contentHash: 'a',
      platform: 'test',
      sourceType: AssetSourceType.manualFile,
      sourcePath: '/tmp/a.jpg',
      createdAt: DateTime.now().subtract(const Duration(hours: 1)),
    );
    await tester.pumpWidget(
      CupertinoApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: AssetPickerScreen(title: 'Pick', assetRecordStore: store),
      ),
    );
    await tester.pumpAndSettle();
    final checked = find.byIcon(CupertinoIcons.checkmark_circle_fill);
    expect(checked, findsNothing);

    await tester.tap(find.byKey(const ValueKey('manual:a')));
    await tester.pumpAndSettle();
    expect(checked, findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('manual:a')));
    await tester.pumpAndSettle();
    expect(checked, findsNothing);
  });
}
