import 'package:photos_vault/backup/app_snapshot.dart';
import 'package:photos_vault/backup/bucket_backup.dart';
import 'package:photos_vault/backup/snapshot_archive.dart';
import 'package:photos_vault/l10n/app_localizations.dart';
import 'package:photos_vault/settings/add_backup_screen.dart';
import 'package:photos_vault/settings/backup_targets_store.dart';
import 'package:photos_vault/settings/bucket_browser_screen.dart';
import 'package:photos_vault/settings/settings_screen.dart';
import 'package:photos_vault/storage/asset_record.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import '../support/fake_album_store.dart';
import '../support/fake_asset_record_store.dart';
import '../support/fake_local_vault.dart';
import '../support/fake_person_store.dart';
import '../support/fake_snapshot_file.dart';
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
  await store.add(
    accessKeyId: 'a',
    secretAccessKey: 'b',
    region: 'us-east-1',
    bucket: 'my-bucket',
    prefix: prefix,
  );
  return store;
}

/// An app-data backup pointed at a map instead of a bucket.
({BucketBackup backup, Map<String, List<int>> objects}) _bucketBackup(
  BackupTargetsStore targets,
  FakeAssetRecordStore assets,
) {
  final objects = <String, List<int>>{};
  return (
    objects: objects,
    backup: BucketBackup(
      snapshots: AppSnapshotIo(
        assetRecordStore: assets,
        albumStore: FakeAlbumStore(),
        personStore: FakePersonStore(),
      ),
      settings: assets,
      targetsStore: targets,
      put: (url, {body}) async {
        objects[url.path] = body! as List<int>;
        return http.Response('', 200);
      },
    ),
  );
}

/// One snapshot, and the fake pair the screen drives it through.
({FakeSnapshotFile file, FakeLocalVault vault}) _pickedFile(
  AppSnapshot snapshot,
) {
  final vault = FakeLocalVault();
  return (vault: vault, file: FakeSnapshotFile(vault: vault, picked: snapshot));
}

void main() {
  testWidgets('removing app data names the copy it takes first', (
    tester,
  ) async {
    await _useTallSurface(tester);
    await tester.pumpWidget(
      _wrap(
        SettingsScreen(store: BackupTargetsStore(store: FakeSecureStore())),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Remove All App Data'));
    await tester.pumpAndSettle();

    expect(find.text('Remove all app data?'), findsOneWidget);
    // No prompt and no share sheet: the dialog's job is to say that a copy
    // is taken anyway, and to name it well enough to find afterwards.
    expect(find.textContaining('photos-vault-pre-deletion'), findsOneWidget);
  });

  testWidgets('restoring a file says what it will do before it does it', (
    tester,
  ) async {
    await _useTallSurface(tester);
    final assets = FakeAssetRecordStore();
    final (:file, :vault) = _pickedFile(
      AppSnapshot(
        version: AppSnapshot.currentVersion,
        exportedAt: DateTime(2026, 9, 12),
        assets: const [
          {'localId': 'a', 'contentHash': 'h', 'platform': 'ios'},
        ],
        albums: const [],
        people: const [],
      ),
    );

    await tester.pumpWidget(
      _wrap(
        SettingsScreen(
          store: BackupTargetsStore(store: FakeSecureStore()),
          assetRecordStore: assets,
          vault: vault,
          snapshotFile: file,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Restore from File'));
    await tester.pumpAndSettle();

    // The date in the file, and the two facts the user can't see for
    // themselves: nothing here is overwritten, and a copy goes first.
    expect(find.text('Restore this backup?'), findsOneWidget);
    expect(find.textContaining('Sep 12, 2026'), findsOneWidget);
    expect(
      find.textContaining('Nothing you already have is changed'),
      findsOne,
    );

    await tester.tap(find.text('Restore'));
    await tester.pumpAndSettle();

    expect(vault.guards, ['restore']);
    expect(file.restored.single.assets.single['localId'], 'a');
    expect(find.textContaining("Restored details for 1 photo"), findsOneWidget);
  });

  testWidgets('backing out of the confirmation restores nothing', (
    tester,
  ) async {
    await _useTallSurface(tester);
    final assets = FakeAssetRecordStore();
    final (:file, :vault) = _pickedFile(
      AppSnapshot(
        version: AppSnapshot.currentVersion,
        exportedAt: DateTime(2026, 9, 12),
        assets: const [
          {'localId': 'a', 'contentHash': 'h', 'platform': 'ios'},
        ],
        albums: const [],
        people: const [],
      ),
    );

    await tester.pumpWidget(
      _wrap(
        SettingsScreen(
          store: BackupTargetsStore(store: FakeSecureStore()),
          assetRecordStore: assets,
          vault: vault,
          snapshotFile: file,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Restore from File'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(vault.guards, isEmpty);
    expect(file.restored, isEmpty);
  });

  testWidgets('app data offers the bucket as a second destination', (
    tester,
  ) async {
    await _useTallSurface(tester);
    final store = await _storeWithBucket();
    final assets = FakeAssetRecordStore();
    final bucket = _bucketBackup(store, assets);

    await tester.pumpWidget(
      _wrap(
        SettingsScreen(
          store: store,
          assetRecordStore: assets,
          bucketBackup: bucket.backup,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Your Cloud Bucket'), findsOneWidget);
    // Flipping it on writes the copy at once, rather than waiting for the
    // next change — which could be days off.
    await tester.tap(find.byType(CupertinoSwitch));
    await tester.pumpAndSettle();

    expect(
      bucket.objects.keys.single,
      '/p/app-data/${dailyArchiveName(DateTime.now())}',
    );
    expect(await bucket.backup.isEnabled(), isTrue);
  });

  testWidgets('with no bucket, the app data switch says so and stays dead', (
    tester,
  ) async {
    await _useTallSurface(tester);
    final store = BackupTargetsStore(store: FakeSecureStore());
    final assets = FakeAssetRecordStore();

    await tester.pumpWidget(
      _wrap(
        SettingsScreen(
          store: store,
          assetRecordStore: assets,
          bucketBackup: _bucketBackup(store, assets).backup,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Add a bucket below first'), findsOneWidget);
    final toggle = tester.widget<CupertinoSwitch>(find.byType(CupertinoSwitch));
    expect(toggle.onChanged, isNull);
  });

  testWidgets('shows the empty state with the add action right there', (
    tester,
  ) async {
    await _useTallSurface(tester);
    final store = BackupTargetsStore(store: FakeSecureStore());
    await tester.pumpWidget(_wrap(SettingsScreen(store: store)));
    await tester.pumpAndSettle();

    expect(
      find.text('Add one to start backing up your photos and videos.'),
      findsOneWidget,
    );
    expect(find.text('Add Cloud Bucket'), findsOneWidget);
  });

  testWidgets('a bucket row shows the full s3 path, not just the region', (
    tester,
  ) async {
    await _useTallSurface(tester);
    final store = await _storeWithBucket();

    await tester.pumpWidget(_wrap(SettingsScreen(store: store)));
    await tester.pumpAndSettle();

    expect(find.text('my-bucket'), findsOneWidget);
    // Two connections to the same bucket differ only by prefix, so the
    // path is what tells them apart.
    expect(find.text('s3://my-bucket/p/'), findsOneWidget);
  });

  testWidgets('tapping a bucket opens the browser rooted at its own prefix', (
    tester,
  ) async {
    await _useTallSurface(tester);
    final store = await _storeWithBucket(prefix: 'photos-vault/');

    await tester.pumpWidget(_wrap(SettingsScreen(store: store)));
    await tester.pumpAndSettle();

    // Single pump, not pumpAndSettle: BucketBrowserScreen's own default
    // listBucketFn is a real network call with nothing to fake it here —
    // this only needs the pushed widget's constructor args, not its load
    // to finish.
    await tester.tap(find.text('my-bucket'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final browser = tester.widget<BucketBrowserScreen>(
      find.byType(BucketBrowserScreen),
    );
    expect(browser.prefix, 'photos-vault/');
  });

  testWidgets('tapping add navigates to the add-backup screen', (tester) async {
    await _useTallSurface(tester);
    final store = BackupTargetsStore(store: FakeSecureStore());
    await tester.pumpWidget(_wrap(SettingsScreen(store: store)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Add Cloud Bucket'));
    await tester.pumpAndSettle();

    expect(find.byType(AddBackupScreen), findsOneWidget);
  });

  testWidgets('a bucket row is one tap target: the bucket itself', (
    tester,
  ) async {
    await _useTallSurface(tester);
    final store = await _storeWithBucket(prefix: '');

    await tester.pumpWidget(_wrap(SettingsScreen(store: store)));
    await tester.pumpAndSettle();

    // The row's old menu held Sync Now and Sync Queue — both already on
    // this page — plus Browse Files, which is what tapping the row does.
    // Delete Connection moved to the connection's own screen.
    expect(find.byIcon(CupertinoIcons.ellipsis_circle), findsNothing);
    expect(find.text('my-bucket'), findsOneWidget);
  });

  testWidgets('stats ride on one footer line under the bucket list', (
    tester,
  ) async {
    await _useTallSurface(tester);
    final store = await _storeWithBucket();
    final recordStore = FakeAssetRecordStore();
    await recordStore.upsert(localId: 'a', contentHash: 'a', platform: 'ios');
    final b = await recordStore.upsert(
      localId: 'b',
      contentHash: 'b',
      platform: 'ios',
    );
    await recordStore.updateDerivative(
      b.localId,
      DerivativeKind.original,
      const DerivativeState(
        status: UploadStatus.uploaded,
        destinationKey: 'originals/b.jpg',
      ),
    );

    await tester.pumpWidget(
      _wrap(SettingsScreen(store: store, assetRecordStore: recordStore)),
    );
    await tester.pumpAndSettle();

    expect(find.text('1 bucket · 1 of 2 photos backed up'), findsOneWidget);
  });

  testWidgets('one bucket shows the order, dimmed, and says when it counts', (
    tester,
  ) async {
    await _useTallSurface(tester);
    final store = await _storeWithBucket();

    await tester.pumpWidget(_wrap(SettingsScreen(store: store)));
    await tester.pumpAndSettle();

    // Visible so it can be found before the second bucket exists — but
    // not a live choice between two identical outcomes.
    expect(find.text('Photo by Photo'), findsOneWidget);
    expect(
      find.text('This only matters once you have more than one bucket.'),
      findsOneWidget,
    );

    await tester.tap(find.text('Photo by Photo'));
    await tester.pumpAndSettle();

    expect(find.text('Bucket by Bucket'), findsNothing);
  });

  testWidgets('a second bucket brings the order menu, and it sticks', (
    tester,
  ) async {
    await _useTallSurface(tester);
    final store = await _storeWithBucket();
    await store.add(
      accessKeyId: 'a',
      secretAccessKey: 'b',
      region: 'us-east-1',
      bucket: 'other-bucket',
      prefix: 'p/',
    );

    await tester.pumpWidget(_wrap(SettingsScreen(store: store)));
    await tester.pumpAndSettle();

    // The pill carries the current value, like the queue's own settings,
    // and the one-bucket note is gone with the reason for it.
    expect(find.text('Photo by Photo'), findsOneWidget);
    expect(
      find.text('This only matters once you have more than one bucket.'),
      findsNothing,
    );

    await tester.tap(find.text('Photo by Photo'));
    await tester.pumpAndSettle();

    // Leads with the part that doesn't change: both orders still put
    // every photo in every bucket.
    expect(
      find.textContaining('is backed up to every bucket either way'),
      findsOneWidget,
    );

    await tester.tap(find.text('Bucket by Bucket'));
    await tester.pumpAndSettle();

    expect(find.text('Bucket by Bucket'), findsOneWidget);
    expect(await store.getOrderStrategy(), BackupOrderStrategy.bucketByBucket);
  });
}
