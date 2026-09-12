import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../widgets/placeholder_screen.dart';

class LibraryScreen extends StatelessWidget {
  const LibraryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.tabLibrary)),
      body: PlaceholderScreen(
        icon: Icons.photo_library_outlined,
        title: l10n.libraryEmptyTitle,
        note: l10n.libraryEmptyNote,
      ),
    );
  }
}
