import 'package:back_your_own_photos/l10n/app_localizations.dart';
import 'package:back_your_own_photos/settings/add_s3_backup_screen.dart';
import 'package:back_your_own_photos/settings/backup_target.dart';
import 'package:back_your_own_photos/settings/backup_targets_store.dart';
import 'package:back_your_own_photos/settings/s3_connectivity.dart';
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

Future<void> _fillForm(WidgetTester tester) async {
  await tester.enterText(find.widgetWithText(TextFormField, 'Access key ID'), 'AKIA123');
  await tester.enterText(find.widgetWithText(TextFormField, 'Secret access key'), 'topsecret');
  await tester.enterText(find.widgetWithText(TextFormField, 'Region'), 'us-east-1');
  await tester.enterText(find.widgetWithText(TextFormField, 'Bucket'), 'my-bucket');
}

void main() {
  testWidgets('shows a validation error when saving with empty required fields', (tester) async {
    final store = BackupTargetsStore(store: FakeSecureStore());
    await tester.pumpWidget(
      _wrap(
        AddS3BackupScreen(
          store: store,
          checkAccess: ({
            required accessKeyId,
            required secretAccessKey,
            required region,
            required bucket,
          }) async => const S3AccessCheckResult(S3AccessCheckOutcome.ok),
        ),
      ),
    );

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('Required'), findsWidgets);
  });

  testWidgets('validates access before saving, then pops on success', (tester) async {
    final store = BackupTargetsStore(store: FakeSecureStore());
    var checkedWith = '';
    await tester.pumpWidget(
      _wrap(
        Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => AddS3BackupScreen(
                  store: store,
                  checkAccess:
                      ({required accessKeyId, required secretAccessKey, required region, required bucket}) async {
                        checkedWith = bucket;
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
    await tester.pump();
    // Mid-flight the button should show the validating state.
    expect(find.text('Validating bucket access…'), findsOneWidget);
    await tester.pumpAndSettle();

    expect(checkedWith, 'my-bucket');
    expect(find.byType(AddS3BackupScreen), findsNothing);
    final saved = await store.loadAll();
    expect(saved, hasLength(1));
    expect((saved.single as S3BackupTarget).bucket, 'my-bucket');
  });

  testWidgets('shows an inline error and does not save when access is forbidden', (tester) async {
    final store = BackupTargetsStore(store: FakeSecureStore());
    await tester.pumpWidget(
      _wrap(
        AddS3BackupScreen(
          store: store,
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
