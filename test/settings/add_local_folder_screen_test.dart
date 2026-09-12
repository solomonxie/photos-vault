import 'package:back_your_own_photos/l10n/app_localizations.dart';
import 'package:back_your_own_photos/settings/add_local_folder_screen.dart';
import 'package:back_your_own_photos/settings/backup_target.dart';
import 'package:back_your_own_photos/settings/backup_targets_store.dart';
import 'package:back_your_own_photos/settings/folder_picker.dart';
import 'package:back_your_own_photos/settings/local_folder_connectivity.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_secure_store.dart';

class _FakeFolderPicker implements FolderPicker {
  const _FakeFolderPicker(this.path);

  final String? path;

  @override
  Future<String?> pickFolder() async => path;
}

Widget _wrap(Widget child) {
  return MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: child,
  );
}

void main() {
  testWidgets('shows a required error when saving without picking a folder', (tester) async {
    final store = BackupTargetsStore(store: FakeSecureStore());
    await tester.pumpWidget(
      _wrap(
        AddLocalFolderScreen(
          store: store,
          folderPicker: const _FakeFolderPicker(null),
          checkAccess: ({required path}) async =>
              const LocalFolderAccessCheckResult(LocalFolderAccessOutcome.ok, bookmarkData: 'b'),
        ),
      ),
    );

    await tester.enterText(find.widgetWithText(TextFormField, 'Name'), 'My Folder');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('Choose a folder first'), findsOneWidget);
  });

  testWidgets('picks a folder, validates access, then saves', (tester) async {
    final store = BackupTargetsStore(store: FakeSecureStore());
    await tester.pumpWidget(
      _wrap(
        AddLocalFolderScreen(
          store: store,
          folderPicker: const _FakeFolderPicker('/private/var/mobile/Photos'),
          checkAccess: ({required path}) async =>
              LocalFolderAccessCheckResult(LocalFolderAccessOutcome.ok, bookmarkData: 'bookmark-for-$path'),
        ),
      ),
    );

    await tester.tap(find.text('Choose Folder…'));
    await tester.pumpAndSettle();
    expect(find.text('/private/var/mobile/Photos'), findsOneWidget);

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.byType(AddLocalFolderScreen), findsNothing);
    final saved = await store.loadAll();
    expect(saved, hasLength(1));
    final target = saved.single as LocalFolderBackupTarget;
    expect(target.displayName, 'Photos');
    expect(target.bookmarkData, 'bookmark-for-/private/var/mobile/Photos');
  });

  testWidgets('shows an inline error and does not save when access check fails', (tester) async {
    final store = BackupTargetsStore(store: FakeSecureStore());
    await tester.pumpWidget(
      _wrap(
        AddLocalFolderScreen(
          store: store,
          folderPicker: const _FakeFolderPicker('/some/folder'),
          checkAccess: ({required path}) async => const LocalFolderAccessCheckResult(LocalFolderAccessOutcome.cannotOpen),
        ),
      ),
    );

    await tester.tap(find.text('Choose Folder…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text("Couldn't open that folder. Try picking it again."), findsOneWidget);
    expect(await store.loadAll(), isEmpty);
  });
}
