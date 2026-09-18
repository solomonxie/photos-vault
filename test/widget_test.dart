import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:photos_vault/app.dart';
import 'package:photos_vault/settings/backup_targets_store.dart';

import 'settings/fake_secure_store.dart';
import 'support/fake_album_store.dart';
import 'support/fake_person_store.dart';
import 'support/fake_asset_record_store.dart';
import 'support/fake_sync_job_store.dart';

BackupTargetsStore _fakeSettingsStore() =>
    BackupTargetsStore(store: FakeSecureStore());

FakeAssetRecordStore _fakeAssetRecordStore() => FakeAssetRecordStore();

void main() {
  testWidgets('shows the Library page with no bottom tab bar', (tester) async {
    await tester.pumpWidget(
      App(
        settingsStore: _fakeSettingsStore(),
        assetRecordStore: _fakeAssetRecordStore(),
        albumStore: FakeAlbumStore(),
        syncJobStore: FakeSyncJobStore(),
        personStore: FakePersonStore(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Library'), findsOneWidget);
    expect(find.text('Utilities'), findsOneWidget);
  });

  testWidgets('renders Mandarin labels under zh locale', (tester) async {
    tester.platformDispatcher.localesTestValue = const [Locale('zh')];
    tester.platformDispatcher.localeTestValue = const Locale('zh');
    addTearDown(() {
      tester.platformDispatcher.clearLocalesTestValue();
      tester.platformDispatcher.clearLocaleTestValue();
    });

    await tester.pumpWidget(
      App(
        settingsStore: _fakeSettingsStore(),
        assetRecordStore: _fakeAssetRecordStore(),
        albumStore: FakeAlbumStore(),
        syncJobStore: FakeSyncJobStore(),
        personStore: FakePersonStore(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('图库'), findsOneWidget);
    expect(find.text('实用工具'), findsOneWidget);
  });
}
