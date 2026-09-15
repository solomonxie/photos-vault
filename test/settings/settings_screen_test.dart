import 'package:bring_your_own_photos/l10n/app_localizations.dart';
import 'package:bring_your_own_photos/settings/add_s3_backup_screen.dart';
import 'package:bring_your_own_photos/settings/backup_targets_store.dart';
import 'package:bring_your_own_photos/settings/settings_screen.dart';
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

void main() {
  testWidgets('shows empty state with an add button when no backups configured', (tester) async {
    final store = BackupTargetsStore(store: FakeSecureStore());
    await tester.pumpWidget(_wrap(SettingsScreen(store: store)));
    await tester.pumpAndSettle();

    expect(find.text('No S3 Backups Yet'), findsOneWidget);
    expect(find.text('Add S3 Backup'), findsWidgets);
  });

  testWidgets('lists configured backup targets', (tester) async {
    final store = BackupTargetsStore(store: FakeSecureStore());
    await store.addS3(accessKeyId: 'a', secretAccessKey: 'b', region: 'us-east-1', bucket: 'my-bucket', prefix: 'p/');

    await tester.pumpWidget(_wrap(SettingsScreen(store: store)));
    await tester.pumpAndSettle();

    expect(find.text('my-bucket'), findsOneWidget);
    expect(find.text('us-east-1 · p/'), findsOneWidget);
  });

  testWidgets('tapping add navigates to the add-backup screen', (tester) async {
    final store = BackupTargetsStore(store: FakeSecureStore());
    await tester.pumpWidget(_wrap(SettingsScreen(store: store)));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Add S3 Backup'));
    await tester.pumpAndSettle();

    expect(find.byType(AddS3BackupScreen), findsOneWidget);
  });

  testWidgets('deleting a target asks for confirmation, then removes it', (tester) async {
    final store = BackupTargetsStore(store: FakeSecureStore());
    await store.addS3(accessKeyId: 'a', secretAccessKey: 'b', region: 'us-east-1', bucket: 'my-bucket', prefix: '');

    await tester.pumpWidget(_wrap(SettingsScreen(store: store)));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();
    expect(find.text('Remove this backup target?'), findsOneWidget);

    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(find.text('my-bucket'), findsNothing);
    expect(await store.loadAll(), isEmpty);
  });
}
