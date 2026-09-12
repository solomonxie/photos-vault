import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../widgets/placeholder_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.tabSettings)),
      body: PlaceholderScreen(
        icon: Icons.settings_outlined,
        title: l10n.settingsSectionTitle,
        note: l10n.settingsNote,
      ),
    );
  }
}
