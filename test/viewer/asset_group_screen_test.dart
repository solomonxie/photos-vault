import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/l10n/app_localizations.dart';
import 'package:photos_vault/storage/asset_record.dart';
import 'package:photos_vault/viewer/asset_group_screen.dart';

import '../support/fake_asset_record_store.dart';

void main() {
  testWidgets('a built-in album selects: all, then archive takes them out', (
    tester,
  ) async {
    final store = FakeAssetRecordStore();
    for (final id in ['manual:a', 'manual:b']) {
      await store.upsert(
        localId: id,
        contentHash: id,
        platform: 'ios',
        sourceType: AssetSourceType.manualFile,
        sourcePath: '/tmp/$id.jpg',
      );
    }
    final records = await store.listAll();
    await tester.pumpWidget(
      CupertinoApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: AssetGroupScreen(
          title: 'Favorites',
          records: records,
          assetRecordStore: store,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('groupSelect')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('selectAllButton')));
    await tester.pumpAndSettle();
    expect(find.text('2 Selected'), findsOne);
    await tester.tap(find.byKey(const ValueKey('groupArchiveSelected')));
    await tester.pumpAndSettle();

    for (final id in ['manual:a', 'manual:b']) {
      expect((await store.getByLocalId(id))!.isArchived, isTrue);
    }
    expect(find.byKey(const ValueKey('groupSelectionDone')), findsNothing);
  });
}
