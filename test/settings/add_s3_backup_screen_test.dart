import 'package:bring_your_own_photos/l10n/app_localizations.dart';
import 'package:bring_your_own_photos/settings/add_s3_backup_screen.dart';
import 'package:bring_your_own_photos/settings/backup_targets_store.dart';
import 'package:bring_your_own_photos/settings/s3_connectivity.dart';
import 'package:bring_your_own_photos/settings/s3_region_detection.dart';
import 'package:bring_your_own_photos/settings/s3_target_drafts_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_secure_store.dart';

Widget _wrap(Widget child) {
  return MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: child,
  );
}

S3TargetDraftsStore _fakeDraftsStore() => S3TargetDraftsStore(store: FakeSecureStore());

Future<S3AccessCheckResult> _okAccess({
  required String accessKeyId,
  required String secretAccessKey,
  required String region,
  required String bucket,
}) async => const S3AccessCheckResult(S3AccessCheckOutcome.ok);

Future<S3RegionDetectionResult> _okRegion(String bucket) async =>
    const S3RegionDetectionResult(S3RegionDetectionOutcome.ok, region: 'us-east-1');

Future<void> _fillForm(WidgetTester tester) async {
  await tester.enterText(find.widgetWithText(TextFormField, 'Access key ID'), 'AKIA123');
  await tester.enterText(find.widgetWithText(TextFormField, 'Secret access key'), 'topsecret');
  await tester.enterText(find.widgetWithText(TextFormField, 'Bucket'), 'my-bucket');
}

void main() {
  testWidgets('shows a validation error when saving with empty required fields', (tester) async {
    final store = BackupTargetsStore(store: FakeSecureStore());
    await tester.pumpWidget(
      _wrap(
        AddS3BackupScreen(store: store, checkAccess: _okAccess, detectRegion: _okRegion, draftsStore: _fakeDraftsStore()),
      ),
    );

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('Required'), findsWidgets);
  });

  testWidgets('prefills the key prefix with a sensible default', (tester) async {
    final store = BackupTargetsStore(store: FakeSecureStore());
    await tester.pumpWidget(
      _wrap(
        AddS3BackupScreen(store: store, checkAccess: _okAccess, detectRegion: _okRegion, draftsStore: _fakeDraftsStore()),
      ),
    );

    expect(find.text(defaultS3Prefix), findsOneWidget);
  });

  testWidgets('detects the region from the bucket name, then validates access, then saves', (tester) async {
    final store = BackupTargetsStore(store: FakeSecureStore());
    final draftsStore = _fakeDraftsStore();
    var checkedRegion = '';
    var detectedForBucket = '';
    await tester.pumpWidget(
      _wrap(
        Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => AddS3BackupScreen(
                  store: store,
                  draftsStore: draftsStore,
                  detectRegion: (bucket) async {
                    detectedForBucket = bucket;
                    return const S3RegionDetectionResult(S3RegionDetectionOutcome.ok, region: 'eu-west-1');
                  },
                  checkAccess:
                      ({required accessKeyId, required secretAccessKey, required region, required bucket}) async {
                        checkedRegion = region;
                        return const S3AccessCheckResult(S3AccessCheckOutcome.ok);
                      },
                ),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await _fillForm(tester);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(detectedForBucket, 'my-bucket');
    expect(checkedRegion, 'eu-west-1');
    expect(find.byType(AddS3BackupScreen), findsNothing);
    final saved = await store.loadAll();
    expect(saved, hasLength(1));
    final target = saved.single;
    expect(target.bucket, 'my-bucket');
    expect(target.region, 'eu-west-1');
    expect(target.prefix, defaultS3Prefix);

    // The draft from this attempt graduated into a real target, so it
    // shouldn't also linger in the draft list.
    expect(await draftsStore.loadAll(), isEmpty);
  });

  testWidgets('shows an inline error and does not save when region detection fails', (tester) async {
    final store = BackupTargetsStore(store: FakeSecureStore());
    await tester.pumpWidget(
      _wrap(
        AddS3BackupScreen(
          store: store,
          checkAccess: _okAccess,
          detectRegion: (bucket) async => const S3RegionDetectionResult(S3RegionDetectionOutcome.networkError),
          draftsStore: _fakeDraftsStore(),
        ),
      ),
    );

    await _fillForm(tester);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.textContaining("Couldn't detect"), findsOneWidget);
    expect(await store.loadAll(), isEmpty);
  });

  testWidgets('shows an inline error and does not save when access is forbidden', (tester) async {
    final store = BackupTargetsStore(store: FakeSecureStore());
    await tester.pumpWidget(
      _wrap(
        AddS3BackupScreen(
          store: store,
          detectRegion: _okRegion,
          draftsStore: _fakeDraftsStore(),
          checkAccess: ({
            required accessKeyId,
            required secretAccessKey,
            required region,
            required bucket,
          }) async => const S3AccessCheckResult(S3AccessCheckOutcome.forbidden),
        ),
      ),
    );

    await _fillForm(tester);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Access denied'), findsOneWidget);
    expect(await store.loadAll(), isEmpty);
    // Screen stays open so the user can fix and retry.
    expect(find.byType(AddS3BackupScreen), findsOneWidget);
  });

  testWidgets('a failed save keeps what was typed as a draft, shown on screen', (tester) async {
    final store = BackupTargetsStore(store: FakeSecureStore());
    final draftsStore = _fakeDraftsStore();
    await tester.pumpWidget(
      _wrap(
        AddS3BackupScreen(
          store: store,
          detectRegion: _okRegion,
          draftsStore: draftsStore,
          checkAccess: ({
            required accessKeyId,
            required secretAccessKey,
            required region,
            required bucket,
          }) async => const S3AccessCheckResult(S3AccessCheckOutcome.forbidden),
        ),
      ),
    );

    await _fillForm(tester);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final drafts = await draftsStore.loadAll();
    expect(drafts, hasLength(1));
    expect(drafts.single.bucket, 'my-bucket');
    expect(find.text('Drafts'), findsOneWidget);
    // "my-bucket" appears twice: once still in the bucket field, once in
    // the new draft list entry below — the latter is below the fold once
    // the length-hint text makes the form taller, hence skipOffstage: false.
    expect(find.text('my-bucket', skipOffstage: false), findsNWidgets(2));
  });

  testWidgets('tapping a draft fills the form from it', (tester) async {
    final store = BackupTargetsStore(store: FakeSecureStore());
    final draftsStore = _fakeDraftsStore();
    await draftsStore.save(accessKeyId: 'AKIA999', secretAccessKey: 'old-secret', bucket: 'drafted-bucket', prefix: 'p/');

    await tester.pumpWidget(
      _wrap(AddS3BackupScreen(store: store, checkAccess: _okAccess, detectRegion: _okRegion, draftsStore: draftsStore)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('drafted-bucket'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(TextFormField, 'AKIA999'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, 'drafted-bucket'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, 'p/'), findsOneWidget);
  });

  testWidgets('deleting a draft removes it from the list', (tester) async {
    final store = BackupTargetsStore(store: FakeSecureStore());
    final draftsStore = _fakeDraftsStore();
    await draftsStore.save(accessKeyId: 'AKIA999', secretAccessKey: 'old-secret', bucket: 'drafted-bucket', prefix: '');

    await tester.pumpWidget(
      _wrap(AddS3BackupScreen(store: store, checkAccess: _okAccess, detectRegion: _okRegion, draftsStore: draftsStore)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Delete draft'));
    await tester.pumpAndSettle();

    expect(find.text('drafted-bucket'), findsNothing);
    expect(await draftsStore.loadAll(), isEmpty);
  });
}
