import 'package:flutter/cupertino.dart';

import '../l10n/app_localizations.dart';

/// What the user picked from [chooseDelete].
enum DeleteChoice {
  cancel,

  /// Reclaim the device storage, keep the cloud copy: the asset stays in
  /// the library as a thumbnail, with the original re-downloadable from
  /// the detail screen. See `AssetRecord.localDeleted`.
  fromDevice,

  /// The ordinary Photos-style delete — into Recently Deleted, from where
  /// it can still be restored.
  everywhere,
}

/// The delete action sheet. [canRemoveFromDevice] gates the cloud-only
/// option: without a backed-up copy there'd be nothing left to restore
/// from, so only "delete" is offered and this degrades to the same
/// confirmation it always was.
Future<DeleteChoice> chooseDelete(
  BuildContext context, {
  required bool canRemoveFromDevice,
}) async {
  final l10n = AppLocalizations.of(context)!;
  if (!canRemoveFromDevice) {
    return await confirmSoftDelete(context)
        ? DeleteChoice.everywhere
        : DeleteChoice.cancel;
  }
  final choice = await showCupertinoModalPopup<DeleteChoice>(
    context: context,
    builder: (context) => CupertinoActionSheet(
      title: Text(l10n.libraryDeleteConfirmTitle),
      actions: [
        CupertinoActionSheetAction(
          onPressed: () => Navigator.of(context).pop(DeleteChoice.fromDevice),
          child: Text(l10n.libraryDeleteFromDevice),
        ),
        CupertinoActionSheetAction(
          isDestructiveAction: true,
          onPressed: () => Navigator.of(context).pop(DeleteChoice.everywhere),
          child: Text(l10n.libraryDeleteEverywhere),
        ),
      ],
      message: Text(l10n.libraryDeleteFromDeviceNote),
      cancelButton: CupertinoActionSheetAction(
        onPressed: () => Navigator.of(context).pop(DeleteChoice.cancel),
        child: Text(l10n.actionCancel),
      ),
    ),
  );
  return choice ?? DeleteChoice.cancel;
}

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
        CupertinoDialogAction(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l10n.actionCancel),
        ),
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
