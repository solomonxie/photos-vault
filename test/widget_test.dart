import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:back_your_own_photos/app.dart';
import 'package:back_your_own_photos/settings/s3_backup_targets_store.dart';

import 'settings/fake_secure_store.dart';

S3BackupTargetsStore _fakeSettingsStore() => S3BackupTargetsStore(store: FakeSecureStore());

void main() {
  testWidgets('shows the three main tab destinations', (tester) async {
    await tester.pumpWidget(App(settingsStore: _fakeSettingsStore()));

    expect(find.byIcon(Icons.photo_library), findsOneWidget);
    expect(find.byIcon(Icons.cloud_upload), findsOneWidget);
    expect(find.byIcon(Icons.settings), findsOneWidget);
  });

  testWidgets('renders Mandarin labels under zh locale', (tester) async {
    tester.platformDispatcher.localesTestValue = const [Locale('zh')];
    tester.platformDispatcher.localeTestValue = const Locale('zh');
    addTearDown(() {
      tester.platformDispatcher.clearLocalesTestValue();
      tester.platformDispatcher.clearLocaleTestValue();
    });

    await tester.pumpWidget(App(settingsStore: _fakeSettingsStore()));
    await tester.pumpAndSettle();

    // Each label appears twice: once in the nav bar, once in that screen's
    // own AppBar (IndexedStack keeps all three screens mounted).
    expect(find.text('图库'), findsWidgets);
    expect(find.text('备份'), findsWidgets);
    expect(find.text('设置'), findsWidgets);
  });
}
