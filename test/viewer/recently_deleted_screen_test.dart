import 'package:bring_your_own_photos/l10n/app_localizations.dart';
import 'package:bring_your_own_photos/storage/asset_record.dart';
import 'package:bring_your_own_photos/viewer/asset_grid.dart';
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

    await tester.pumpWidget(
      _wrap(RecentlyDeletedScreen(assetRecordStore: store)),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('manual:deleted')), findsOneWidget);
    expect(find.byKey(const ValueKey('manual:active')), findsNothing);
  });

  testWidgets('shows the empty state with nothing deleted', (tester) async {
    await tester.pumpWidget(
      _wrap(RecentlyDeletedScreen(assetRecordStore: FakeAssetRecordStore())),
    );
    await tester.pumpAndSettle();

    expect(find.text('No recently deleted items.'), findsOneWidget);
  });

  group('deleting permanently', () {
    Future<FakeAssetRecordStore> storeWithDeleted() async {
      final store = FakeAssetRecordStore();
      await store.upsert(
        localId: 'manual:gone',
        contentHash: 'g',
        platform: 'ios',
        sourceType: AssetSourceType.manualFile,
        sourcePath: '/tmp/g.jpg',
      );
      await store.softDelete('manual:gone');
      return store;
    }

    /// Invokes the tile's own "Delete Permanently" action rather than
    /// driving `CupertinoContextMenu`'s hold-and-release animation — the
    /// menu isn't what's under test, and the action it fires is.
    Future<void> deletePermanently(WidgetTester tester) async {
      final tile = tester.widget<AssetTile>(
        find.byKey(const ValueKey('manual:gone')),
      );
      tile.actions.firstWhere((a) => a.isDestructive).onPressed();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
    }

    testWidgets('takes the backed-up copy with it', (tester) async {
      final store = await storeWithDeleted();
      AssetRecord? purged;

      await tester.pumpWidget(
        _wrap(
          RecentlyDeletedScreen(
            assetRecordStore: store,
            deleteBackup: (record) async {
              purged = record;
              return true;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await deletePermanently(tester);

      expect(purged?.localId, 'manual:gone');
      expect(await store.getByLocalId('manual:gone'), isNull);
    });

    testWidgets('keeps the record when the bucket cannot be reached', (
      tester,
    ) async {
      final store = await storeWithDeleted();

      await tester.pumpWidget(
        _wrap(
          RecentlyDeletedScreen(
            assetRecordStore: store,
            deleteBackup: (record) async => false,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await deletePermanently(tester);

      // Dropping it locally would orphan the objects with nothing left
      // pointing at them.
      expect(await store.getByLocalId('manual:gone'), isNotNull);
      expect(find.textContaining("Couldn't remove"), findsOneWidget);
    });
  });
}
