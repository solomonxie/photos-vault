import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:back_your_own_photos/app.dart';
import 'package:back_your_own_photos/settings/backup_targets_store.dart';

import 'settings/fake_secure_store.dart';
import 'support/fake_asset_record_store.dart';

BackupTargetsStore _fakeSettingsStore() => BackupTargetsStore(store: FakeSecureStore());

FakeAssetRecordStore _fakeAssetRecordStore() => FakeAssetRecordStore();

void main() {
  testWidgets('shows the two main tab destinations', (tester) async {
    await tester.pumpWidget(App(settingsStore: _fakeSettingsStore(), assetRecordStore: _fakeAssetRecordStore()));
    await tester.pumpAndSettle();

    expect(find.byIcon(CupertinoIcons.photo_fill), findsOneWidget);
    expect(find.byIcon(CupertinoIcons.square_grid_2x2_fill), findsOneWidget);
  });

  testWidgets('renders Mandarin labels under zh locale', (tester) async {
    tester.platformDispatcher.localesTestValue = const [Locale('zh')];
    tester.platformDispatcher.localeTestValue = const Locale('zh');
    addTearDown(() {
      tester.platformDispatcher.clearLocalesTestValue();
      tester.platformDispatcher.clearLocaleTestValue();
    });

    await tester.pumpWidget(App(settingsStore: _fakeSettingsStore(), assetRecordStore: _fakeAssetRecordStore()));
    await tester.pumpAndSettle();

    // Each label appears at least twice: once in the tab bar, once as that
    // tab's own large title (both tabs stay mounted, offstage, like Photos).
    expect(find.text('图库'), findsWidgets);
    expect(find.text('合集'), findsWidgets);
  });
}
