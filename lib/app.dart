import 'package:flutter/cupertino.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'demo/demo_mode.dart';
import 'l10n/app_localizations.dart';
import 'photos/person_store.dart';
import 'settings/app_store_region.dart';
import 'settings/backup_targets_store.dart';
import 'upload/sync_job_store.dart';
import 'vault/private_lifecycle.dart';
import 'storage/album_store.dart';
import 'storage/asset_record_store.dart';
import 'viewer/library_screen.dart';
import 'viewer/scroll_stop_guard.dart';

class App extends StatelessWidget {
  const App({
    super.key,
    this.settingsStore,
    this.assetRecordStore,
    this.albumStore,
    this.syncJobStore,
    this.personStore,
  });

  /// Overridable for tests so widget tests never touch the real
  /// secure-storage platform channel.
  final BackupTargetsStore? settingsStore;

  /// Overridable for tests so widget tests never touch the real sqflite
  /// platform channel.
  final AssetRecordStore? assetRecordStore;

  /// Overridable for tests so widget tests never touch the real sqflite
  /// platform channel.
  final AlbumStore? albumStore;

  /// Overridable for tests so widget tests never open the real sync-queue
  /// database.
  final SyncJobStore? syncJobStore;

  /// Overridable for tests so widget tests never open the real People
  /// database.
  final PersonStore? personStore;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: AppStoreRegion.language,
      builder: (context, language, _) => _app(language),
    );
  }

  Widget _app(String? language) {
    return CupertinoApp(
      locale: language == null ? null : Locale(language),
      debugShowCheckedModeBanner: false,
      title: 'Photos Vault',
      theme: const CupertinoThemeData(
        brightness: Brightness.dark,
        primaryColor: CupertinoColors.systemBlue,
        // A dark charcoal, not pure black — list-row backgrounds (e.g.
        // Utilities' cards) are a step lighter still, so sections stay
        // visually separated from the page instead of both being #000.
        scaffoldBackgroundColor: Color(0xFF1C1C1E),
      ),
      // Over every page and sheet: a touch that lands on a moving list
      // stops it and nothing else.
      builder: (context, child) =>
          PrivacyShield(child: ScrollStopGuard(child: child!)),
      // Not AppLocalizations.localizationsDelegates: that list carries the
      // Material tables, and with nothing Material left in the app AOT can
      // drop the whole library. See CLAUDE.md's size budget.
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      localeListResolutionCallback: (_, supported) => storefrontLocale(
        supported,
        region: AppStoreRegion.current,
        languageChosen: AppStoreRegion.languageChosen,
        picked: language,
      ),
      // One page, no bottom tab bar — matches Photos: a day-grouped grid
      // with Media Types/Utilities sections below, not separate tabs.
      // Keyed on demo mode: switching rebuilds the library from scratch,
      // so every store opens again against the other data root.
      home: ListenableBuilder(
        listenable: Listenable.merge([DemoMode.shown, DemoMode.resets]),
        builder: (context, _) => LibraryScreen(
          key: ValueKey((DemoMode.shown.value, DemoMode.resets.value)),
          assetRecordStore: assetRecordStore,
          backupTargetsStore: settingsStore,
          albumStore: albumStore,
          syncJobStore: syncJobStore,
          personStore: personStore,
          // The real app keeps working in the background while it's open:
          // uploads still owed, then the camera roll, then faces.
          backgroundPassInterval: const Duration(seconds: 20),
        ),
      ),
    );
  }
}
