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

  /// Gone from this phone and from every bucket, with no bin in between.
  permanent,
}

/// The delete action sheet. [canRemoveFromDevice] gates the cloud-only
/// option: without a backed-up copy there'd be nothing left to restore
/// from, so only "delete" is offered and this degrades to the same
/// confirmation it always was.
Future<DeleteChoice> chooseDelete(
  BuildContext context, {
  required bool canRemoveFromDevice,
  bool recoverable = true,
  bool cloudOnly = false,
}) async {
  final l10n = AppLocalizations.of(context)!;
  final choice = await showCupertinoModalPopup<DeleteChoice>(
    context: context,
    builder: (context) => CupertinoActionSheet(
      title: canRemoveFromDevice ? Text(l10n.libraryDeleteConfirmTitle) : null,
      // A photo only the bucket holds: the bin's 30 days are the last 30
      // days of it anywhere, which is worth saying before, not after.
      message: Text(
        cloudOnly
            ? l10n.libraryDeleteCloudOnlyBody
            : canRemoveFromDevice
            ? l10n.libraryDeleteFromDeviceNote
            : recoverable
            ? l10n.libraryDeleteConfirmBody
            : l10n.libraryDeleteConfirmBodyGone,
      ),
      actions: [
        if (canRemoveFromDevice)
          CupertinoActionSheetAction(
            onPressed: () => Navigator.of(context).pop(DeleteChoice.fromDevice),
            child: Text(l10n.libraryDeleteFromDevice),
          ),
        CupertinoActionSheetAction(
          isDestructiveAction: true,
          onPressed: () => Navigator.of(context).pop(DeleteChoice.everywhere),
          child: Text(l10n.libraryDeleteEverywhere),
        ),
        // With nothing of the photo anywhere else the line above already
        // deletes for good; a second button would say the same thing twice.
        if (recoverable)
          CupertinoActionSheetAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.of(context).pop(DeleteChoice.permanent),
            child: Text(l10n.libraryDeletePermanentlyAction),
          ),
      ],
      cancelButton: CupertinoActionSheetAction(
        onPressed: () => Navigator.of(context).pop(DeleteChoice.cancel),
        child: Text(l10n.actionCancel),
      ),
    ),
  );
  return choice ?? DeleteChoice.cancel;
}

/// The last question before a permanent delete: nothing can bring it back.
Future<bool> confirmPermanentDelete(BuildContext context) async {
  final l10n = AppLocalizations.of(context)!;
  final confirmed = await showCupertinoDialog<bool>(
    context: context,
    builder: (context) => CupertinoAlertDialog(
      title: Text(l10n.libraryDeletePermanentlyTitle),
      content: Text(l10n.libraryDeletePermanentlyEverywhereBody),
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

/// The delete sheet for a selection. With [removable] of them backed up,
/// it offers what a single photo's sheet does: free the space and keep the
/// cloud copy for those, or delete the lot. With none, a plain confirm.
Future<DeleteChoice> chooseBatchDelete(
  BuildContext context, {
  required int count,
  required int removable,
  int cloudOnly = 0,
}) async {
  final l10n = AppLocalizations.of(context)!;
  final choice = await showCupertinoModalPopup<DeleteChoice>(
    context: context,
    builder: (context) => CupertinoActionSheet(
      title: Text(l10n.selectionDeleteConfirmTitle(count)),
      message: Text(
        [
          removable > 0
              ? l10n.libraryDeleteFromDeviceNote
              : l10n.libraryDeleteConfirmBody,
          if (cloudOnly > 0) l10n.selectionDeleteCloudOnlyNote(cloudOnly),
        ].join('\n\n'),
      ),
      actions: [
        if (removable > 0)
          CupertinoActionSheetAction(
            key: const ValueKey('batchRemoveFromDevice'),
            onPressed: () => Navigator.of(context).pop(DeleteChoice.fromDevice),
            child: Text(l10n.selectionRemoveFromDevice(removable)),
          ),
        CupertinoActionSheetAction(
          isDestructiveAction: true,
          onPressed: () => Navigator.of(context).pop(DeleteChoice.everywhere),
          child: Text(l10n.selectionDeleteAction(count)),
        ),
      ],
      cancelButton: CupertinoActionSheetAction(
        onPressed: () => Navigator.of(context).pop(DeleteChoice.cancel),
        child: Text(l10n.actionCancel),
      ),
    ),
  );
  return choice ?? DeleteChoice.cancel;
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

  /// Gone for good; the buckets' copies are queued for deletion.
  deleted,

  /// Asked for and couldn't be done — no thumbnail could be made, so
  /// dropping the original would have left nothing to draw.
  failed,

  /// The bucket was asked and hasn't got the photo, so nothing was freed.
  /// The one outcome the user has to hear about in full: this app believed
  /// it was backed up and it is not.
  backupMissing,

  /// No bucket could be reached, so the copy couldn't be confirmed and
  /// nothing was deleted. Try again online.
  backupUnverifiable;

  bool get leftTheList =>
      this == DeleteOutcome.binned || this == DeleteOutcome.deleted;
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
    cloudOnly: record.localDeleted,
  );
  switch (choice) {
    case DeleteChoice.cancel:
      return DeleteOutcome.none;
    case DeleteChoice.fromDevice:
      return switch (await removal.removeFromDevice(record)) {
        RemovalOutcome.freed => DeleteOutcome.cloudOnly,
        RemovalOutcome.failed => DeleteOutcome.failed,
        RemovalOutcome.backupMissing => DeleteOutcome.backupMissing,
        RemovalOutcome.backupUnverifiable => DeleteOutcome.backupUnverifiable,
      };
    case DeleteChoice.everywhere:
      return await removal.deleteEverywhere(record)
          ? DeleteOutcome.binned
          : DeleteOutcome.none;
    case DeleteChoice.permanent:
      if (!context.mounted || !await confirmPermanentDelete(context)) {
        return DeleteOutcome.none;
      }
      return await removal.deletePermanently(record)
          ? DeleteOutcome.deleted
          : DeleteOutcome.none;
  }
}
