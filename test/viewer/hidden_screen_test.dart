import 'package:back_your_own_photos/l10n/app_localizations.dart';
import 'package:back_your_own_photos/storage/asset_record.dart';
import 'package:back_your_own_photos/viewer/hidden_screen.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_asset_record_store.dart';

Widget _wrap(Widget child) => CupertinoApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: child,
);

void main() {
  testWidgets('shows only hidden, non-deleted items', (tester) async {
    final store = FakeAssetRecordStore();
    await store.upsert(
      localId: 'manual:hidden',
      contentHash: 'h',
      platform: 'ios',
      sourceType: AssetSourceType.manualFile,
      sourcePath: '/tmp/h.jpg',
    );
    await store.setHidden('manual:hidden', true);
    await store.upsert(
      localId: 'manual:visible',
      contentHash: 'v',
      platform: 'ios',
      sourceType: AssetSourceType.manualFile,
      sourcePath: '/tmp/v.jpg',
    );

    await tester.pumpWidget(_wrap(HiddenScreen(assetRecordStore: store)));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('manual:hidden')), findsOneWidget);
    expect(find.byKey(const ValueKey('manual:visible')), findsNothing);
  });

  testWidgets('shows the empty state with nothing hidden', (tester) async {
    await tester.pumpWidget(_wrap(HiddenScreen(assetRecordStore: FakeAssetRecordStore())));
    await tester.pumpAndSettle();

    expect(find.text('Nothing hidden.'), findsOneWidget);
  });
}
