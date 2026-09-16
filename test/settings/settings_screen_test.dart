import 'package:bring_your_own_photos/l10n/app_localizations.dart';
import 'package:bring_your_own_photos/settings/add_s3_backup_screen.dart';
import 'package:bring_your_own_photos/settings/backup_targets_store.dart';
import 'package:bring_your_own_photos/settings/bucket_browser_screen.dart';
import 'package:bring_your_own_photos/settings/settings_screen.dart';
import 'package:bring_your_own_photos/storage/asset_record.dart';
import 'package:bring_your_own_photos/upload/sync_job.dart';
import 'package:bring_your_own_photos/upload/sync_queue.dart';
import 'package:bring_your_own_photos/viewer/sync_queue_sheet.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_asset_record_store.dart';
import '../support/fake_sync_job_store.dart';
import 'fake_secure_store.dart';

Widget _wrap(Widget child) {
  return CupertinoApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: child,
  );
}

/// The page is one long scroll — every section has to be built for finders
/// to reach the ones below the fold.
Future<void> _useTallSurface(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(800, 1600));
  addTearDown(() => tester.binding.setSurfaceSize(null));
}

Future<BackupTargetsStore> _storeWithBucket({String prefix = 'p/'}) async {
  final store = BackupTargetsStore(store: FakeSecureStore());
  await store.addS3(
    accessKeyId: 'a',
    secretAccessKey: 'b',
    region: 'us-east-1',
    bucket: 'my-bucket',
    prefix: prefix,
  );
  return store;
}

void main() {
  testWidgets('shows the empty state with the add action right there', (tester) async {
    await _useTallSurface(tester);
    final store = BackupTargetsStore(store: FakeSecureStore());
    await tester.pumpWidget(_wrap(SettingsScreen(store: store)));
    await tester.pumpAndSettle();

    expect(find.text('Add one to start backing up your photos and videos.'), findsOneWidget);
    expect(find.text('Add Cloud Bucket'), findsOneWidget);
  });

  testWidgets('a bucket row shows the full s3 path, not just the region', (tester) async {
    await _useTallSurface(tester);
    final store = await _storeWithBucket();

    await tester.pumpWidget(_wrap(SettingsScreen(store: store)));
    await tester.pumpAndSettle();

    expect(find.text('my-bucket'), findsOneWidget);
    // Two connections to the same bucket differ only by prefix, so the
    // path is what tells them apart.
    expect(find.text('s3://my-bucket/p/'), findsOneWidget);
  });

  testWidgets('tapping a bucket opens the browser rooted at its own prefix', (tester) async {
    await _useTallSurface(tester);
    final store = await _storeWithBucket(prefix: 'bring-your-own-photos/');

    await tester.pumpWidget(_wrap(SettingsScreen(store: store)));
    await tester.pumpAndSettle();

    // Single pump, not pumpAndSettle: BucketBrowserScreen's own default
    // listBucketFn is a real network call with nothing to fake it here —
    // this only needs the pushed widget's constructor args, not its load
    // to finish.
    await tester.tap(find.text('my-bucket'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final browser = tester.widget<BucketBrowserScreen>(find.byType(BucketBrowserScreen));
    expect(browser.prefix, 'bring-your-own-photos/');
  });

  testWidgets('tapping add navigates to the add-backup screen', (tester) async {
    await _useTallSurface(tester);
    final store = BackupTargetsStore(store: FakeSecureStore());
    await tester.pumpWidget(_wrap(SettingsScreen(store: store)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Add Cloud Bucket'));
    await tester.pumpAndSettle();

    expect(find.byType(AddS3BackupScreen), findsOneWidget);
  });

  testWidgets('delete lives in the row menu, behind a confirmation', (tester) async {
    await _useTallSurface(tester);
    final store = await _storeWithBucket(prefix: '');

    await tester.pumpWidget(_wrap(SettingsScreen(store: store)));
    await tester.pumpAndSettle();

    // No second tap target beside the row — it's in the row's own menu.
    await tester.tap(find.byIcon(CupertinoIcons.ellipsis_circle));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete Connection'));
    await tester.pumpAndSettle();

    expect(find.text('Remove this backup target?'), findsOneWidget);
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(find.text('my-bucket'), findsNothing);
    expect(await store.loadAll(), isEmpty);
  });

  testWidgets('the queue is one status line that opens a sheet, not a page', (tester) async {
    await _useTallSurface(tester);
    final store = await _storeWithBucket();
    final recordStore = FakeAssetRecordStore();
    await recordStore.upsert(localId: 'a', contentHash: 'a', platform: 'ios');
    final b = await recordStore.upsert(localId: 'b', contentHash: 'b', platform: 'ios');
    await recordStore.updateDerivative(
      b.localId,
      DerivativeKind.original,
      const DerivativeState(status: UploadStatus.uploaded, destinationKey: 'originals/b.jpg'),
    );

    final queue = SyncQueue(
      store: FakeSyncJobStore(),
      settings: store,
      process: (_) async {},
    );
    await queue.store.enqueue(localId: 'a', kind: SyncJobKind.uploadOriginal, displayName: 'a.jpg');
    await queue.refresh();

    await tester.pumpWidget(
      _wrap(SettingsScreen(store: store, assetRecordStore: recordStore, syncQueue: queue)),
    );
    await tester.pumpAndSettle();

    // Counts outstanding *jobs* — one photo can be several units of work.
    expect(find.text('Sync queue: 1 pending · 2 at a time'), findsOneWidget);

    await tester.tap(find.text('Sync queue: 1 pending · 2 at a time'));
    await tester.pumpAndSettle();

    expect(find.byType(SyncQueueSheet), findsOneWidget);
  });

  testWidgets('stats ride on one footer line under the bucket list', (tester) async {
    await _useTallSurface(tester);
    final store = await _storeWithBucket();
    final recordStore = FakeAssetRecordStore();
    await recordStore.upsert(localId: 'a', contentHash: 'a', platform: 'ios');
    final b = await recordStore.upsert(localId: 'b', contentHash: 'b', platform: 'ios');
    await recordStore.updateDerivative(
      b.localId,
      DerivativeKind.original,
      const DerivativeState(status: UploadStatus.uploaded, destinationKey: 'originals/b.jpg'),
    );

    await tester.pumpWidget(_wrap(SettingsScreen(store: store, assetRecordStore: recordStore)));
    await tester.pumpAndSettle();

    expect(find.text('1 bucket · 1 of 2 photos backed up'), findsOneWidget);
  });

  testWidgets('sync frequency is a heading control, and Sync Now is dead with no bucket', (tester) async {
    await _useTallSurface(tester);
    final store = BackupTargetsStore(store: FakeSecureStore());

    await tester.pumpWidget(_wrap(SettingsScreen(store: store, assetRecordStore: FakeAssetRecordStore())));
    await tester.pumpAndSettle();

    expect(find.text('Manual Only'), findsOneWidget);
    expect(find.text('Never synced'), findsOneWidget);

    // Present but disabled rather than missing — a manual action must never
    // be a silent no-op.
    final syncNow = tester.widget<CupertinoButton>(
      find.ancestor(of: find.text('Sync Now'), matching: find.byType(CupertinoButton)),
    );
    expect(syncNow.onPressed, isNull);
  });

  testWidgets('picking a sync frequency persists it', (tester) async {
    await _useTallSurface(tester);
    final store = await _storeWithBucket();

    await tester.pumpWidget(_wrap(SettingsScreen(store: store, assetRecordStore: FakeAssetRecordStore())));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Manual Only'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Every Hour'));
    await tester.pumpAndSettle();

    expect(await store.getSyncFrequency(), SyncFrequency.everyHour);
  });

  testWidgets('backup format options each carry their own pro/con line', (tester) async {
    await _useTallSurface(tester);
    final store = await _storeWithBucket();

    await tester.pumpWidget(_wrap(SettingsScreen(store: store, assetRecordStore: FakeAssetRecordStore())));
    await tester.pumpAndSettle();

    expect(find.textContaining('Full quality, byte-identical'), findsOneWidget);
    expect(find.textContaining('Re-encodes photos as WebP'), findsOneWidget);

    await tester.tap(find.text('Optimized (WebP)'));
    await tester.pumpAndSettle();

    expect(await store.getBackupFormat(), BackupFormat.optimized);
  });
}
