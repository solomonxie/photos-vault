import 'package:bring_your_own_photos/l10n/app_localizations.dart';
import 'package:bring_your_own_photos/storage/asset_record.dart';
import 'package:bring_your_own_photos/viewer/favorites_screen.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_asset_record_store.dart';

Widget _wrap(Widget child) => CupertinoApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: child,
);

void main() {
  testWidgets('shows only favorited, non-deleted items', (tester) async {
    final store = FakeAssetRecordStore();
    await store.upsert(
      localId: 'manual:fav',
      contentHash: 'fav',
      platform: 'ios',
      sourceType: AssetSourceType.manualFile,
      sourcePath: '/tmp/fav.jpg',
    );
    await store.setFavorite('manual:fav', true);
    await store.upsert(
      localId: 'manual:not-fav',
      contentHash: 'nf',
      platform: 'ios',
      sourceType: AssetSourceType.manualFile,
      sourcePath: '/tmp/nf.jpg',
    );
    await store.upsert(
      localId: 'manual:fav-deleted',
      contentHash: 'fd',
      platform: 'ios',
      sourceType: AssetSourceType.manualFile,
      sourcePath: '/tmp/fd.jpg',
    );
    await store.setFavorite('manual:fav-deleted', true);
    await store.softDelete('manual:fav-deleted');

    await tester.pumpWidget(_wrap(FavoritesScreen(assetRecordStore: store)));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('manual:fav')), findsOneWidget);
    expect(find.byKey(const ValueKey('manual:not-fav')), findsNothing);
    expect(find.byKey(const ValueKey('manual:fav-deleted')), findsNothing);
  });

  testWidgets('shows the empty state with no favorites', (tester) async {
    await tester.pumpWidget(
      _wrap(FavoritesScreen(assetRecordStore: FakeAssetRecordStore())),
    );
    await tester.pumpAndSettle();

    expect(find.text('No favorites yet.'), findsOneWidget);
  });
}
