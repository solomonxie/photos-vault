import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show BottomNavigationBarItem, Colors, Theme, ThemeData;

import 'l10n/app_localizations.dart';
import 'photos/demo_assets_service.dart';
import 'photos/manual_add.dart';
import 'settings/backup_targets_store.dart';
import 'storage/asset_record_store.dart';
import 'viewer/collections_screen.dart';
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
    return CupertinoApp(
      title: 'Bring Your Own Photos',
      theme: const CupertinoThemeData(primaryColor: CupertinoColors.systemBlue),
      // Some settings/add-target screens are still Material underneath —
      // gives them a sane theme rather than Material's default fallback.
      builder: (context, child) => Theme(data: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true), child: child!),
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
  // Shared across Library and Collections so a demo photo deleted in one
  // and reset from the other stay in sync with the same underlying store.
  late final AssetRecordStore _assetRecordStore = widget.assetRecordStore ?? AssetRecordStore();
  late final ManualAddService _manualAddService = ManualAddService(store: _assetRecordStore);
  late final DemoAssetsService _demoAssetsService = DemoAssetsService(manualAddService: _manualAddService);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return CupertinoTabScaffold(
      tabBar: CupertinoTabBar(
        items: [
          BottomNavigationBarItem(icon: const Icon(CupertinoIcons.photo_fill), label: l10n.tabLibrary),
          BottomNavigationBarItem(icon: const Icon(CupertinoIcons.square_grid_2x2_fill), label: l10n.tabCollections),
        ],
      ),
      tabBuilder: (context, index) {
        return CupertinoTabView(
          builder: (context) => switch (index) {
            0 => LibraryScreen(
              assetRecordStore: _assetRecordStore,
              backupTargetsStore: widget.settingsStore,
              manualAddService: _manualAddService,
              demoAssetsService: _demoAssetsService,
            ),
            _ => CollectionsScreen(assetRecordStore: _assetRecordStore, backupTargetsStore: widget.settingsStore),
          },
        );
      },
    );
  }
}
