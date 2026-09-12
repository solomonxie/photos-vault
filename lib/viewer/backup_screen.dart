import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../widgets/placeholder_screen.dart';

class BackupScreen extends StatelessWidget {
  const BackupScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.tabBackup)),
      body: PlaceholderScreen(
        icon: Icons.cloud_upload_outlined,
        title: l10n.backupEmptyTitle,
        note: l10n.backupEmptyNote,
      ),
    );
  }
}
