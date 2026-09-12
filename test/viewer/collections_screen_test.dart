import 'package:back_your_own_photos/l10n/app_localizations.dart';
import 'package:back_your_own_photos/settings/backup_targets_store.dart';
import 'package:back_your_own_photos/storage/asset_record.dart';
import 'package:back_your_own_photos/viewer/backup_screen.dart';
import 'package:back_your_own_photos/viewer/collections_screen.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';

import '../settings/fake_secure_store.dart';
import '../support/fake_asset_record_store.dart';

Widget _wrap(Widget child) => CupertinoApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: child,
);

void main() {
  testWidgets('shows Utilities with our Backup Status and S3 Settings rows', (tester) async {
    await tester.pumpWidget(
      _wrap(
        CollectionsScreen(
          assetRecordStore: FakeAssetRecordStore(),
          backupTargetsStore: BackupTargetsStore(store: FakeSecureStore()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Utilities'), findsOneWidget);
    expect(find.text('Backup Status'), findsOneWidget);
    expect(find.text('S3 Settings'), findsOneWidget);
  });

  testWidgets('shows Media Types with real photo/video counts once something exists', (tester) async {
    final store = FakeAssetRecordStore();
    await store.upsert(
      localId: 'manual:a',
      contentHash: 'a',
      platform: 'ios',
      sourceType: AssetSourceType.manualFile,
      sourcePath: '/tmp/a.jpg',
    );
    await store.upsert(
      localId: 'manual:b',
      contentHash: 'b',
      platform: 'ios',
      sourceType: AssetSourceType.manualFile,
      sourcePath: '/tmp/b.mp4',
    );

    await tester.pumpWidget(
      _wrap(
        CollectionsScreen(assetRecordStore: store, backupTargetsStore: BackupTargetsStore(store: FakeSecureStore())),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Media Types'), findsOneWidget);
    expect(find.text('Photos'), findsOneWidget);
    expect(find.text('Videos'), findsOneWidget);
    expect(find.text('1'), findsNWidgets(2));
  });

  testWidgets('tapping Backup Status pushes the backup screen', (tester) async {
    await tester.pumpWidget(
      _wrap(
        CollectionsScreen(
          assetRecordStore: FakeAssetRecordStore(),
          backupTargetsStore: BackupTargetsStore(store: FakeSecureStore()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Backup Status'));
    await tester.pumpAndSettle();

    expect(find.byType(BackupScreen), findsOneWidget);
  });
}
