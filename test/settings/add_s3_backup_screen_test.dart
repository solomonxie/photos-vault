import 'package:back_your_own_photos/l10n/app_localizations.dart';
import 'package:back_your_own_photos/settings/add_s3_backup_screen.dart';
import 'package:back_your_own_photos/settings/backup_targets_store.dart';
import 'package:back_your_own_photos/settings/s3_connectivity.dart';
import 'package:back_your_own_photos/settings/s3_region_detection.dart';
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
      _wrap(AddS3BackupScreen(store: store, checkAccess: _okAccess, detectRegion: _okRegion)),
    );

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('Required'), findsWidgets);
  });

  testWidgets('prefills the key prefix with a sensible default', (tester) async {
    final store = BackupTargetsStore(store: FakeSecureStore());
    await tester.pumpWidget(
      _wrap(AddS3BackupScreen(store: store, checkAccess: _okAccess, detectRegion: _okRegion)),
    );

    expect(find.text(defaultS3Prefix), findsOneWidget);
  });

  testWidgets('detects the region from the bucket name, then validates access, then saves', (tester) async {
    final store = BackupTargetsStore(store: FakeSecureStore());
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
  });

  testWidgets('shows an inline error and does not save when region detection fails', (tester) async {
    final store = BackupTargetsStore(store: FakeSecureStore());
    await tester.pumpWidget(
      _wrap(
        AddS3BackupScreen(
          store: store,
          checkAccess: _okAccess,
          detectRegion: (bucket) async => const S3RegionDetectionResult(S3RegionDetectionOutcome.networkError),
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
}
