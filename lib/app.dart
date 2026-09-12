import 'package:flutter/material.dart';

import 'l10n/app_localizations.dart';
import 'photos/demo_assets_service.dart';
import 'photos/manual_add.dart';
import 'settings/backup_targets_store.dart';
import 'settings/settings_screen.dart';
import 'storage/asset_record_store.dart';
import 'viewer/backup_screen.dart';
import 'viewer/library_screen.dart';

class App extends StatelessWidget {
  const App({super.key, this.settingsStore, this.assetRecordStore});

  /// Overridable for tests so widget tests never touch the real
  /// secure-storage platform channel.
  final BackupTargetsStore? settingsStore;

  /// Overridable for tests so widget tests never touch the real sqflite
  /// platform channel.
  final AssetRecordStore? assetRecordStore;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Bring Your Own Photos',
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: HomeTabs(settingsStore: settingsStore, assetRecordStore: assetRecordStore),
    );
  }
}

class HomeTabs extends StatefulWidget {
  const HomeTabs({super.key, this.settingsStore, this.assetRecordStore});

  final BackupTargetsStore? settingsStore;
  final AssetRecordStore? assetRecordStore;

  @override
  State<HomeTabs> createState() => _HomeTabsState();
}

class _HomeTabsState extends State<HomeTabs> {
  int _index = 0;

  // Shared across Library and Settings so a demo photo deleted in one tab
  // and reset from the other stay in sync with the same underlying store.
  late final AssetRecordStore _assetRecordStore = widget.assetRecordStore ?? AssetRecordStore();
  late final ManualAddService _manualAddService = ManualAddService(store: _assetRecordStore);
  late final DemoAssetsService _demoAssetsService = DemoAssetsService(manualAddService: _manualAddService);

  late final List<Widget> _screens = [
    LibraryScreen(
      assetRecordStore: _assetRecordStore,
      backupTargetsStore: widget.settingsStore,
      manualAddService: _manualAddService,
      demoAssetsService: _demoAssetsService,
    ),
    const BackupScreen(),
    SettingsScreen(store: widget.settingsStore, assetRecordStore: _assetRecordStore, demoAssetsService: _demoAssetsService),
  ];

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      body: IndexedStack(index: _index, children: _screens),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: [
          NavigationDestination(icon: const Icon(Icons.photo_library), label: l10n.tabLibrary),
          NavigationDestination(icon: const Icon(Icons.cloud_upload), label: l10n.tabBackup),
          NavigationDestination(icon: const Icon(Icons.settings), label: l10n.tabSettings),
        ],
      ),
    );
  }
}
