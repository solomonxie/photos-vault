import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:photos_vault/backup/app_snapshot.dart';
import 'package:photos_vault/backup/bucket_backup.dart';
import 'package:photos_vault/backup/icloud_backup.dart';
import 'package:photos_vault/l10n/app_localizations.dart';
import 'package:photos_vault/settings/backup_targets_store.dart';
import 'package:photos_vault/settings/s3_listing.dart';
import 'package:photos_vault/storage/asset_record.dart';
import 'package:photos_vault/upload/backup_verifier.dart';
import 'package:photos_vault/viewer/safety_screen.dart';

import '../settings/fake_secure_store.dart';
import '../support/fake_album_store.dart';
import '../support/fake_asset_record_store.dart';
import '../support/fake_person_store.dart';

Widget _wrap(Widget child) => CupertinoApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: child,
);

Future<BackupTargetsStore> _targets({bool withBucket = true}) async {
  final store = BackupTargetsStore(store: FakeSecureStore());
  if (withBucket) {
    await store.add(
      accessKeyId: 'a',
      secretAccessKey: 'b',
      region: 'ca-central-1',
      bucket: 'slmx-archives2',
      prefix: 'photos/',
    );
  }
  return store;
}

Future<void> _backedUp(
  FakeAssetRecordStore store, {
  required String localId,
  required String key,
}) async {
  await store.upsert(localId: localId, contentHash: localId, platform: 'ios');
  await store.updateDerivative(
    localId,
    DerivativeKind.original,
    DerivativeState(status: UploadStatus.uploaded, destinationKey: key),
  );
}

Widget _screen({
  required FakeAssetRecordStore assets,
  required BackupTargetsStore targets,
  required BackupVerifier verifier,
}) {
  final snapshots = AppSnapshotIo(
    assetRecordStore: assets,
    albumStore: FakeAlbumStore(),
    personStore: FakePersonStore(),
  );
  return _wrap(
    SafetyScreen(
      recordStore: assets,
      targetsStore: targets,
      verifier: verifier,
      // The real ones, with no platform channel and no network behind them:
      // iCloud reports `unsupported` off-device, and the bucket copy is only
      // read for its "last copied" line.
      icloudBackup: ICloudBackup(snapshots: snapshots, settings: assets),
      bucketBackup: BucketBackup(
        snapshots: snapshots,
        settings: assets,
        targetsStore: targets,
        put: (url, {body}) async => http.Response('', 200),
      ),
    ),
  );
}

void main() {
  testWidgets('says plainly when nothing has ever been confirmed', (
    tester,
  ) async {
    final assets = FakeAssetRecordStore();
    await _backedUp(assets, localId: 'photo:1', key: 'photos/originals/a');
    final targets = await _targets();

    await tester.pumpWidget(
      _screen(
        assets: assets,
        targets: targets,
        verifier: BackupVerifier(targetsStore: targets, recordStore: assets),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('This iPhone'), findsOneWidget);
    expect(find.text('slmx-archives2'), findsOneWidget);
    expect(find.text('1 of 1 originals backed up'), findsOneWidget);
    // The status line is never blank: "no idea" is the answer this page
    // came to give, so it gives it.
    expect(
      find.textContaining('Never checked with your bucket'),
      findsOneWidget,
    );
  });

  testWidgets('with no bucket, the warning row leads and the checks are dead', (
    tester,
  ) async {
    final assets = FakeAssetRecordStore();
    final targets = await _targets(withBucket: false);

    await tester.pumpWidget(
      _screen(
        assets: assets,
        targets: targets,
        verifier: BackupVerifier(targetsStore: targets, recordStore: assets),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No bucket yet'), findsOneWidget);
    expect(
      find.text('This phone is the only copy. Add a bucket you own.'),
      findsOneWidget,
    );
  });

  testWidgets('Check Now reports what the bucket said, and requeues', (
    tester,
  ) async {
    final assets = FakeAssetRecordStore();
    await _backedUp(assets, localId: 'photo:here', key: 'photos/originals/a');
    await _backedUp(assets, localId: 'photo:gone', key: 'photos/originals/b');
    final targets = await _targets();

    await tester.pumpWidget(
      _screen(
        assets: assets,
        targets: targets,
        verifier: BackupVerifier(
          targetsStore: targets,
          recordStore: assets,
          list: ({required target, prefix = '', continuationToken}) async =>
              S3ListingResult(
                S3ListingOutcome.ok,
                page: S3ListingPage(
                  folders: const [],
                  objects: [
                    S3Object(
                      key: 'photos/originals/a',
                      size: 10,
                      lastModified: DateTime(2026),
                    ),
                  ],
                ),
              ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Check Now'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('1 photo is missing from your bucket'),
      findsOneWidget,
    );
    // Reporting isn't enough: the record that claimed to be backed up is
    // back in the queue, so the next sync makes it true.
    final requeued = (await assets.getByLocalId('photo:gone'))!;
    expect(
      requeued.stateOf(DerivativeKind.original).status,
      UploadStatus.pending,
    );
  });

  testWidgets('Test Restore says the backup is real when it is', (
    tester,
  ) async {
    final assets = FakeAssetRecordStore();
    await _backedUp(assets, localId: 'photo:1', key: 'photos/originals/a');
    final targets = await _targets();

    await tester.pumpWidget(
      _screen(
        assets: assets,
        targets: targets,
        verifier: BackupVerifier(
          targetsStore: targets,
          recordStore: assets,
          get: (_) async => http.Response.bytes([1, 2, 3], 200),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Test Restore'));
    await tester.pumpAndSettle();

    expect(find.textContaining('The backup is real'), findsOneWidget);
  });

  testWidgets('the recovery steps name the user\'s own prefix', (tester) async {
    final assets = FakeAssetRecordStore();
    final targets = await _targets();

    await tester.pumpWidget(
      _screen(
        assets: assets,
        targets: targets,
        verifier: BackupVerifier(targetsStore: targets, recordStore: assets),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('IF THIS APP IS GONE'), findsOneWidget);
    expect(find.textContaining('photos/app-data/index.csv'), findsOneWidget);
  });
}
