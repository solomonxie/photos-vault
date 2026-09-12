import 'package:flutter/material.dart';

import 'l10n/app_localizations.dart';
import 'settings/settings_screen.dart';
import 'viewer/backup_screen.dart';
import 'viewer/library_screen.dart';

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Back Your Own Photos',
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const HomeTabs(),
    );
  }
}

class HomeTabs extends StatefulWidget {
  const HomeTabs({super.key});

  @override
  State<HomeTabs> createState() => _HomeTabsState();
}

class _HomeTabsState extends State<HomeTabs> {
  int _index = 0;

  static const _screens = [
    LibraryScreen(),
    BackupScreen(),
    SettingsScreen(),
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
