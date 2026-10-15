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
  FlagSolution.makeThumbnail => l10n.flaggedMakeThumbnails,
  FlagSolution.getFromPhotos => l10n.flaggedGetFromPhotos,
  FlagSolution.removeFromLibrary => l10n.flaggedRemoveFromLibrary,
  FlagSolution.finishOptimize => l10n.flaggedFinishOptimize,
  FlagSolution.removeExtraCopies => l10n.flaggedRemoveExtraCopies,
  FlagSolution.removeImportCopy => l10n.flaggedRemoveDuplicates,
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
  FlagSolution.makeThumbnail => l10n.flaggedHowMakeThumbnail,
  FlagSolution.getFromPhotos => l10n.flaggedHowGetFromPhotos,
  FlagSolution.removeFromLibrary => l10n.flaggedHowRemoveFromLibrary,
  FlagSolution.finishOptimize => l10n.flaggedHowFinishOptimize,
  FlagSolution.removeExtraCopies => l10n.flaggedHowRemoveExtraCopies,
  FlagSolution.removeImportCopy => l10n.flaggedHowRemoveImportCopy,
};

/// The fine print, shown on the action's page before anything runs.
String? solutionDetail(AppLocalizations l10n, FlagSolution s) => switch (s) {
  FlagSolution.removeFromDevice => l10n.flaggedConfirmRemoveBody,
  FlagSolution.optimize => l10n.flaggedConfirmOptimizeBody,
  FlagSolution.optimizeRemote => l10n.flaggedConfirmOptimizeRemoteBody,
  FlagSolution.reformat => l10n.flaggedConfirmReformatBody,
  FlagSolution.removeOldCopy => l10n.flaggedConfirmOldCopyBody,
  FlagSolution.importAnyway => l10n.flaggedConfirmImportAnywayBody,
  FlagSolution.removeFromLibrary => l10n.flaggedConfirmRemoveFromLibraryBody,
  FlagSolution.finishOptimize => l10n.flaggedConfirmFinishOptimizeBody,
  FlagSolution.removeExtraCopies => l10n.flaggedConfirmExtraCopiesBody,
  _ => null,
};

/// Deletes or overwrites for good, so it asks once more.
bool solutionIsPermanent(FlagSolution s) =>
    s == FlagSolution.removeThumbnail ||
    s == FlagSolution.removeOldCopy ||
    s == FlagSolution.removeBucketDuplicate ||
    s == FlagSolution.removeFromLibrary ||
    solutionReplacesOriginal(s);

/// Writes a smaller copy over the bucket's original.
bool solutionReplacesOriginal(FlagSolution s) =>
    s == FlagSolution.optimizeRemote || s == FlagSolution.reformat;

/// What the confirmation says is lost. For a replace, how many of [chosen]
/// have no other copy: a bucket file not in the library, or a cloud-only
/// photo.
String permanentNote(
  AppLocalizations l10n,
  FlagSolution s, [
  List<Flag> chosen = const [],
]) {
  if (s == FlagSolution.removeFromLibrary) {
    return l10n.flaggedConfirmRemoveFromLibraryBody;
  }
  if (!solutionReplacesOriginal(s)) return l10n.flaggedPermanent;
  final only = chosen
      .where((f) => f.record == null || f.record!.localDeleted)
      .length;
  return [
    l10n.flaggedPermanentReplace,
    if (only > 0) l10n.flaggedPermanentOnlyCopy(only),
  ].join(' ');
}

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
  FlagSolution.makeThumbnail => CupertinoIcons.photo_fill,
  FlagSolution.getFromPhotos => CupertinoIcons.arrow_down_circle_fill,
  FlagSolution.removeFromLibrary => CupertinoIcons.trash_fill,
  FlagSolution.finishOptimize => CupertinoIcons.arrow_down_right_arrow_up_left,
  FlagSolution.removeExtraCopies ||
  FlagSolution.removeImportCopy => CupertinoIcons.square_on_square,
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
  FlagProblem.noThumbnail => l10n.flaggedProblemNoThumbnail,
  FlagProblem.missingFromBucket => l10n.flaggedProblemMissing,
  FlagProblem.leftoverCopy => l10n.flaggedProblemLeftoverCopy,
  FlagProblem.extraCopies => l10n.flaggedProblemExtraCopies,
};

/// Why this item is listed. A photo's tags explain its size; a bucket file
/// needs the sentence.
String flagReason(AppLocalizations l10n, Flag flag) {
  final bucket = flag.bucket;
  if (flag.asset != null) {
    if (flag.problems.contains(FlagProblem.noThumbnail)) {
      return l10n.flaggedNoThumbnailReason;
    }
    if (flag.problems.contains(FlagProblem.leftoverCopy)) {
      return l10n.flaggedLeftoverCopyReason;
    }
    if (flag.problems.contains(FlagProblem.extraCopies)) {
      return l10n.flaggedExtraCopiesReason;
    }
    if (flag.problems.contains(FlagProblem.duplicate)) {
      return l10n.flaggedDuplicateOf(flag.name);
    }
    return flag.solutions.contains(FlagSolution.getFromPhotos)
        ? l10n.flaggedLostInPhotosReason
        : l10n.flaggedLostReason;
  }
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
