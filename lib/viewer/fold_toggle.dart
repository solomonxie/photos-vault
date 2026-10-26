import 'package:flutter/cupertino.dart';

import '../l10n/app_localizations.dart';

/// How many of a long list show before "Show All".
const foldedCount = 5;

/// "Show All (N)" / "Show Less" under a list cut to [foldedCount].
class FoldToggle extends StatelessWidget {
  const FoldToggle({
    super.key,
    required this.total,
    required this.expanded,
    required this.onPressed,
  });

  final int total;
  final bool expanded;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return CupertinoButton(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      minimumSize: const Size(0, 32),
      onPressed: onPressed,
      child: Text(
        expanded ? l10n.collectionsShowLess : l10n.collectionsShowAll(total),
        style: const TextStyle(fontSize: 14),
      ),
    );
  }
}
