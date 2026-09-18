import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show Colors, Theme, ThemeData;

import 'l10n/app_localizations.dart';
import 'photos/person_store.dart';
import 'settings/backup_targets_store.dart';
import 'upload/sync_job_store.dart';
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
    return CupertinoApp(
      title: 'BYO Photos',
      theme: const CupertinoThemeData(
        brightness: Brightness.dark,
        primaryColor: CupertinoColors.systemBlue,
        // A dark charcoal, not pure black — list-row backgrounds (e.g.
        // Utilities' cards) are a step lighter still, so sections stay
        // visually separated from the page instead of both being #000.
        scaffoldBackgroundColor: Color(0xFF1C1C1E),
      ),
      // Settings/add-target screens are still Material underneath — gives
      // them a sane theme rather than Material's default fallback.
      builder: (context, child) => Theme(
        data: ThemeData(
          brightness: Brightness.dark,
          colorSchemeSeed: Colors.indigo,
          useMaterial3: true,
        ),
        // Over every page and sheet: a touch that lands on a moving list
        // stops it and nothing else.
        child: ScrollStopGuard(child: child!),
      ),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      // One page, no bottom tab bar — matches Photos: a day-grouped grid
      // with Media Types/Utilities sections below, not separate tabs.
      home: LibraryScreen(
        assetRecordStore: assetRecordStore,
        backupTargetsStore: settingsStore,
        albumStore: albumStore,
        syncJobStore: syncJobStore,
        personStore: personStore,
        // The real app keeps working in the background while it's open:
        // uploads still owed, then the camera roll, then faces.
        backgroundPassInterval: const Duration(seconds: 20),
      ),
    );
  }
}
