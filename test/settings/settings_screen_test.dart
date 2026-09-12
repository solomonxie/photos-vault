import 'package:back_your_own_photos/l10n/app_localizations.dart';
import 'package:back_your_own_photos/settings/add_local_folder_screen.dart';
import 'package:back_your_own_photos/settings/add_s3_backup_screen.dart';
import 'package:back_your_own_photos/settings/backup_targets_store.dart';
import 'package:back_your_own_photos/settings/security_scoped_bookmark.dart';
import 'package:back_your_own_photos/settings/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_secure_store.dart';

class _FakeBookmarkResolver implements SecurityScopedBookmarkResolver {
  const _FakeBookmarkResolver({required this.resolvesTo});

  final String? resolvesTo;

  @override
  Future<String> createBookmark(String path) async => 'bookmark-for-$path';

  @override
  Future<String?> resolveAndStartAccess(String bookmarkData) async => resolvesTo;

  @override
  Future<void> stopAccess(String path) async {}
}

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

    expect(find.text('No Backups Yet'), findsOneWidget);
    expect(find.text('Add Backup'), findsWidgets);
  });

  testWidgets('lists configured backup targets', (tester) async {
    final store = BackupTargetsStore(store: FakeSecureStore());
    await store.addS3(accessKeyId: 'a', secretAccessKey: 'b', region: 'us-east-1', bucket: 'my-bucket', prefix: 'p/');

    await tester.pumpWidget(_wrap(SettingsScreen(store: store)));
    await tester.pumpAndSettle();

    expect(find.text('my-bucket'), findsOneWidget);
    expect(find.text('us-east-1 · p/'), findsOneWidget);
  });

  testWidgets('tapping add offers a choice, then navigates to the S3 add screen', (tester) async {
    final store = BackupTargetsStore(store: FakeSecureStore());
    await tester.pumpWidget(_wrap(SettingsScreen(store: store)));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Add Backup'));
    await tester.pumpAndSettle();
    expect(find.text('S3 Bucket'), findsOneWidget);
    expect(find.text('iCloud Folder'), findsOneWidget);

    await tester.tap(find.text('S3 Bucket'));
    await tester.pumpAndSettle();

    expect(find.byType(AddS3BackupScreen), findsOneWidget);
  });

  testWidgets('tapping add then iCloud Folder navigates to the local-folder add screen', (tester) async {
    final store = BackupTargetsStore(store: FakeSecureStore());
    await tester.pumpWidget(_wrap(SettingsScreen(store: store)));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Add Backup'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('iCloud Folder'));
    await tester.pumpAndSettle();

    expect(find.byType(AddLocalFolderScreen), findsOneWidget);
  });

  testWidgets('tapping a local-folder target that fails to resolve prompts a re-pick', (tester) async {
    final store = BackupTargetsStore(store: FakeSecureStore());
    await store.addLocalFolder(displayName: 'My Folder', bookmarkData: 'stale-data');

    await tester.pumpWidget(
      _wrap(
        SettingsScreen(
          store: store,
          bookmarkResolver: _FakeBookmarkResolver(resolvesTo: null),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('My Folder'));
    await tester.pumpAndSettle();

    expect(find.text('Folder access lost'), findsOneWidget);
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
