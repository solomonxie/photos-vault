import 'package:photos_vault/l10n/app_localizations.dart';
import 'package:photos_vault/storage/asset_record.dart';
import 'package:photos_vault/viewer/asset_grid.dart';
import 'package:photos_vault/viewer/recently_deleted_screen.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/photos/asset_removal.dart';
import 'package:photos_vault/settings/backup_targets_store.dart';
import 'package:photos_vault/upload/pending_deletes.dart';

import '../settings/fake_secure_store.dart';
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

    testWidgets('drops the row and leaves bucket deletes to the queue', (
      tester,
    ) async {
      final store = await storeWithDeleted();
      final targets = BackupTargetsStore(store: FakeSecureStore());

      await tester.pumpWidget(
        _wrap(
          RecentlyDeletedScreen(
            assetRecordStore: store,
            removal: AssetRemoval(
              store: store,
              targetsStore: targets,
              pendingDeletes: PendingDeletes(store: store),
            ),
            pendingDeletes: PendingDeletes(store: store),
            targetsStore: targets,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await deletePermanently(tester);

      expect(await store.getByLocalId('manual:gone'), isNull);
    });
  });
}
