import 'package:flutter/cupertino.dart';

import '../l10n/app_localizations.dart';

/// Confirms a soft-delete (Favorite/Hidden/Library/Album screens all route
/// through this before calling `AssetRecordStore.softDelete`) — permanent
/// delete from Recently Deleted has its own, separate confirmation.
Future<bool> confirmSoftDelete(BuildContext context) async {
  final l10n = AppLocalizations.of(context)!;
  final confirmed = await showCupertinoDialog<bool>(
    context: context,
    builder: (context) => CupertinoAlertDialog(
      title: Text(l10n.libraryDeleteConfirmTitle),
      content: Text(l10n.libraryDeleteConfirmBody),
      actions: [
        CupertinoDialogAction(onPressed: () => Navigator.of(context).pop(false), child: Text(l10n.actionCancel)),
        CupertinoDialogAction(
          isDestructiveAction: true,
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(l10n.actionDelete),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}
