import 'package:flutter/cupertino.dart';

import '../l10n/app_localizations.dart';
import '../photos/asset_removal.dart';
import '../storage/asset_record.dart';

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
  bool recoverable = true,
}) async {
  final l10n = AppLocalizations.of(context)!;
  if (!canRemoveFromDevice) {
    return await confirmSoftDelete(context, recoverable: recoverable)
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

/// Confirms a soft-delete — the one-choice case, for a photo with no
/// backed-up copy to fall back on. Permanent delete from Recently Deleted
/// has its own, separate confirmation.
///
/// A sheet at the bottom of the screen rather than an alert in the middle
/// of it: that's where Photos asks, that's where the thumb already is, and
/// a destructive choice under the finger beats one it has to reach for.
///
/// [recoverable] false says so plainly: nothing of this photo is anywhere
/// else, so it doesn't go to Recently Deleted — promising a bin it will
/// never appear in is the one thing this sheet must not do.
Future<bool> confirmSoftDelete(
  BuildContext context, {
  bool recoverable = true,
}) async {
  final l10n = AppLocalizations.of(context)!;
  final confirmed = await showCupertinoModalPopup<bool>(
    context: context,
    builder: (context) => CupertinoActionSheet(
      message: Text(
        recoverable
            ? l10n.libraryDeleteConfirmBody
            : l10n.libraryDeleteConfirmBodyGone,
      ),
      actions: [
        CupertinoActionSheetAction(
          isDestructiveAction: true,
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(l10n.libraryDeleteEverywhere),
        ),
      ],
      cancelButton: CupertinoActionSheetAction(
        onPressed: () => Navigator.of(context).pop(false),
        child: Text(l10n.actionCancel),
      ),
    ),
  );
  return confirmed ?? false;
}

/// What a [deleteAsset] actually did.
enum DeleteOutcome {
  /// Cancelled, or declined at the OS's own prompt. Nothing to say.
  none,

  /// Now cloud-only, and still in the library — so a viewer above it
  /// stays open on it rather than popping.
  cloudOnly,

  /// In this app's Recently Deleted, and out of the caller's list.
  binned,

  /// Asked for and couldn't be done — no thumbnail could be made, so
  /// dropping the original would have left nothing to draw.
  failed;

  bool get leftTheList => this == DeleteOutcome.binned;
}

/// The whole two-choice delete for one asset: ask, carry it out, say what
/// happened.
///
/// Every grid screen goes through this. Which choices are offered is a
/// property of the photo — see [AssetRemoval.canRemoveFromDevice] — not of
/// the page it happens to be on, and a photo the library offers to keep in
/// the cloud must not be a plain delete over in Favorites.
Future<DeleteOutcome> deleteAsset(
  BuildContext context, {
  required AssetRecord record,
  required AssetRemoval removal,
}) async {
  final choice = await chooseDelete(
    context,
    canRemoveFromDevice: removal.canRemoveFromDevice(record),
    recoverable: !record.hasNothingLeft,
  );
  switch (choice) {
    case DeleteChoice.cancel:
      return DeleteOutcome.none;
    case DeleteChoice.fromDevice:
      return await removal.removeFromDevice(record)
          ? DeleteOutcome.cloudOnly
          : DeleteOutcome.failed;
    case DeleteChoice.everywhere:
      return await removal.deleteEverywhere(record)
          ? DeleteOutcome.binned
          : DeleteOutcome.none;
  }
}

/// One confirmation for a whole selection, naming the count — "delete 40
/// photos" is a different decision from "delete this photo", and by the
/// time the sheet is up the selection has usually scrolled out of sight.
/// Asking once per photo wouldn't be a safeguard, just a wall to click
/// through.
Future<bool> confirmDeleteSelection(
  BuildContext context, {
  required int count,
}) async {
  final l10n = AppLocalizations.of(context)!;
  final confirmed = await showCupertinoModalPopup<bool>(
    context: context,
    builder: (context) => CupertinoActionSheet(
      message: Text(l10n.libraryDeleteConfirmBody),
      actions: [
        CupertinoActionSheetAction(
          isDestructiveAction: true,
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(l10n.selectionDeleteAction(count)),
        ),
      ],
      cancelButton: CupertinoActionSheetAction(
        onPressed: () => Navigator.of(context).pop(false),
        child: Text(l10n.actionCancel),
      ),
    ),
  );
  return confirmed ?? false;
}
