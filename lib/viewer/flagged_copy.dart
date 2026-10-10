import 'package:flutter/cupertino.dart';

import '../l10n/app_localizations.dart';
import '../photos/fix_queue.dart';
import '../photos/storage_optimizer.dart' show FixAction;
import '../upload/bucket_flagged.dart';

/// The words and icons for Flagged Items, shared by the action list and
/// each action's own page so the two never disagree.

String solutionLabel(AppLocalizations l10n, FlagSolution s) => switch (s) {
  FlagSolution.backUp => l10n.storageFixBackUpFirst,
  FlagSolution.removeFromDevice => l10n.storageFixRemoveFromDevice,
  FlagSolution.optimize ||
  FlagSolution.optimizeRemote => l10n.storageFixOptimize,
  FlagSolution.removeDuplicate ||
  FlagSolution.removeBucketDuplicate => l10n.flaggedRemoveDuplicates,
  FlagSolution.import => l10n.flaggedImport,
  FlagSolution.rename => l10n.flaggedRename,
  FlagSolution.reformat => l10n.flaggedReformat,
  FlagSolution.removeThumbnail => l10n.flaggedRemove,
  FlagSolution.removeOldCopy => l10n.flaggedRemoveOldCopy,
  FlagSolution.ignore => l10n.flaggedIgnore,
  FlagSolution.importAnyway => l10n.flaggedImportAnyway,
};

/// One line: what the action will do.
String solutionHow(AppLocalizations l10n, FlagSolution s) => switch (s) {
  FlagSolution.backUp => l10n.flaggedHowBackUp,
  FlagSolution.optimize => l10n.flaggedHowOptimize,
  FlagSolution.optimizeRemote => l10n.flaggedHowOptimizeRemote,
  FlagSolution.removeDuplicate => l10n.flaggedHowRemoveDuplicate,
  FlagSolution.removeBucketDuplicate => l10n.flaggedHowRemoveBucketDuplicate,
  FlagSolution.removeFromDevice => l10n.flaggedHowRemoveFromDevice,
  FlagSolution.import => l10n.flaggedHowImport,
  FlagSolution.rename => l10n.flaggedHowRename,
  FlagSolution.reformat => l10n.flaggedHowReformat,
  FlagSolution.removeThumbnail => l10n.flaggedHowRemoveThumbnail,
  FlagSolution.removeOldCopy => l10n.flaggedHowRemoveOldCopy,
  FlagSolution.ignore => l10n.flaggedHowIgnore,
  FlagSolution.importAnyway => l10n.flaggedHowImportAnyway,
};

/// The fine print, shown on the action's page before anything runs.
String? solutionDetail(AppLocalizations l10n, FlagSolution s) => switch (s) {
  FlagSolution.removeFromDevice => l10n.flaggedConfirmRemoveBody,
  FlagSolution.optimize => l10n.flaggedConfirmOptimizeBody,
  FlagSolution.optimizeRemote => l10n.flaggedConfirmOptimizeRemoteBody,
  FlagSolution.reformat => l10n.flaggedConfirmReformatBody,
  FlagSolution.removeOldCopy => l10n.flaggedConfirmOldCopyBody,
  FlagSolution.importAnyway => l10n.flaggedConfirmImportAnywayBody,
  _ => null,
};

/// Deletes from the bucket for good, so it asks once more.
bool solutionIsPermanent(FlagSolution s) =>
    s == FlagSolution.removeThumbnail ||
    s == FlagSolution.removeOldCopy ||
    s == FlagSolution.removeBucketDuplicate;

IconData solutionIcon(FlagSolution s) => switch (s) {
  FlagSolution.backUp => CupertinoIcons.cloud_upload_fill,
  FlagSolution.removeFromDevice => CupertinoIcons.cloud_fill,
  FlagSolution.optimize ||
  FlagSolution.optimizeRemote ||
  FlagSolution.reformat => CupertinoIcons.arrow_down_right_arrow_up_left,
  FlagSolution.import ||
  FlagSolution.importAnyway => CupertinoIcons.tray_arrow_down_fill,
  FlagSolution.rename => CupertinoIcons.pencil,
  FlagSolution.removeThumbnail ||
  FlagSolution.removeOldCopy => CupertinoIcons.delete_solid,
  FlagSolution.removeDuplicate ||
  FlagSolution.removeBucketDuplicate => CupertinoIcons.square_on_square,
  FlagSolution.ignore => CupertinoIcons.eye_slash_fill,
};

String problemLabel(AppLocalizations l10n, FlagProblem p) => switch (p) {
  FlagProblem.onDevice => l10n.storageIssueOnDevice,
  FlagProblem.largeFile => l10n.storageIssueLargeFile,
  FlagProblem.highResolution => l10n.storageIssueHighResolution,
  FlagProblem.optimizableFormat => l10n.storageIssueOptimizableFormat,
  FlagProblem.offProtocol => l10n.flaggedProblemOffProtocol,
  FlagProblem.orphanThumbnail => l10n.flaggedProblemOrphan,
  FlagProblem.unclaimed => l10n.flaggedProblemUnclaimed,
  FlagProblem.likelyLeftover => l10n.flaggedProblemLeftover,
  FlagProblem.duplicate => l10n.flaggedProblemDuplicate,
};

/// Why this item is listed. A photo's tags explain its size; a bucket file
/// needs the sentence.
String flagReason(AppLocalizations l10n, Flag flag) {
  final bucket = flag.bucket;
  if (flag.storage?.duplicateOf case final kept?) {
    return l10n.flaggedDuplicateOf(kept);
  }
  if (bucket == null) {
    final record = flag.storage?.record;
    return [
      for (final p in flag.problems)
        if (p == FlagProblem.highResolution &&
            record?.width != null &&
            record?.height != null)
          // The size it is and the size it becomes: the reason, and what
          // Optimize Space does about it, in one look.
          l10n.flaggedHighResolution(record!.width!, record.height!)
        else if (p != FlagProblem.onDevice)
          problemLabel(l10n, p),
    ].join(' · ');
  }
  if (bucket.likelyDuplicateOf case final key?) {
    final name = key.split('/').last;
    return switch (bucket.kind) {
      FlagKind.oldCopy => l10n.flaggedOldCopyReason(name),
      FlagKind.duplicate => l10n.flaggedDuplicateOf(name),
      _ => l10n.flaggedLikelyDuplicate(name),
    };
  }
  return switch (bucket.kind) {
    FlagKind.offProtocol => l10n.flaggedOffProtocolReason,
    FlagKind.orphanThumbnail => l10n.flaggedOrphanReason,
    FlagKind.unclaimed => l10n.flaggedUnclaimedReason,
    FlagKind.likelyLeftover ||
    FlagKind.oldCopy ||
    FlagKind.duplicate => l10n.flaggedLeftoverReason,
  };
}

String? failureNote(AppLocalizations l10n, FixJob? job) {
  if (job == null || job.state != FixJobState.failed) return null;
  return switch (job.failure) {
    FixFailure.needsAlbum => l10n.flaggedNeedsAlbum,
    FixFailure.unverified => l10n.flaggedUnverified,
    _ =>
      job.detail == null
          ? l10n.flaggedFailed
          : '${l10n.flaggedFailed} (${job.detail})',
  };
}

/// How long something should take, rounded the way a person would say it.
String etaLabel(AppLocalizations l10n, Duration d) {
  final seconds = d.inSeconds;
  if (seconds < 10) return l10n.flaggedEtaSeconds;
  if (seconds < 60) return l10n.flaggedEtaUnderMinute;
  final minutes = (seconds / 60).ceil();
  if (minutes < 60) return l10n.flaggedEtaMinutes(minutes);
  return l10n.flaggedEtaHours(minutes ~/ 60, minutes % 60);
}

String actionLabel(AppLocalizations l10n, FixAction a) => switch (a) {
  FixAction.optimizing => l10n.flaggedStepOptimizing,
  FixAction.downloading => l10n.flaggedStepDownloading,
  FixAction.uploading => l10n.flaggedStepUploading,
  FixAction.deleting => l10n.flaggedStepDeleting,
  FixAction.renaming => l10n.flaggedStepRenaming,
  FixAction.adding => l10n.flaggedStepAdding,
  FixAction.converting => l10n.flaggedStepConverting,
  FixAction.confirming => l10n.flaggedStepConfirming,
};
