import 'package:flutter/cupertino.dart';

import '../l10n/app_localizations.dart';
import '../photos/fix_queue.dart';
import '../photos/storage_optimizer.dart' show FixAction;
import '../upload/bucket_flagged.dart';

/// The words and icons for Suggestions, shared by the action list and
/// each action's own page so the two never disagree.

String solutionLabel(AppLocalizations l10n, FlagSolution s) => switch (s) {
  FlagSolution.backUp => l10n.storageFixBackUpFirst,
  FlagSolution.removeFromDevice => l10n.storageFixRemoveFromDevice,
  FlagSolution.optimize ||
  FlagSolution.optimizeRemote => l10n.storageFixOptimize,
  FlagSolution.removeDuplicate ||
  FlagSolution.removeBucketDuplicate => l10n.suggestionsRemoveDuplicates,
  FlagSolution.import => l10n.suggestionsImport,
  FlagSolution.rename => l10n.suggestionsRename,
  FlagSolution.reformat => l10n.suggestionsReformat,
  FlagSolution.removeThumbnail => l10n.suggestionsRemove,
  FlagSolution.removeOldCopy => l10n.suggestionsRemoveOldCopy,
  FlagSolution.ignore => l10n.suggestionsIgnore,
  FlagSolution.importAnyway => l10n.suggestionsImportAnyway,
  FlagSolution.makeThumbnail => l10n.suggestionsMakeThumbnails,
  FlagSolution.getFromPhotos => l10n.suggestionsGetFromPhotos,
  FlagSolution.removeFromLibrary => l10n.suggestionsRemoveFromLibrary,
  FlagSolution.finishOptimize => l10n.suggestionsFinishOptimize,
  FlagSolution.removeExtraCopies => l10n.suggestionsRemoveExtraCopies,
  FlagSolution.removeImportCopy => l10n.suggestionsRemoveDuplicates,
  FlagSolution.attachLiveHalf => l10n.suggestionsAttachLiveHalf,
};

/// One line: what the action will do.
String solutionHow(AppLocalizations l10n, FlagSolution s) => switch (s) {
  FlagSolution.backUp => l10n.suggestionsHowBackUp,
  FlagSolution.optimize => l10n.suggestionsHowOptimize,
  FlagSolution.optimizeRemote => l10n.suggestionsHowOptimizeRemote,
  FlagSolution.removeDuplicate => l10n.suggestionsHowRemoveDuplicate,
  FlagSolution.removeBucketDuplicate =>
    l10n.suggestionsHowRemoveBucketDuplicate,
  FlagSolution.removeFromDevice => l10n.suggestionsHowRemoveFromDevice,
  FlagSolution.import => l10n.suggestionsHowImport,
  FlagSolution.rename => l10n.suggestionsHowRename,
  FlagSolution.reformat => l10n.suggestionsHowReformat,
  FlagSolution.removeThumbnail => l10n.suggestionsHowRemoveThumbnail,
  FlagSolution.removeOldCopy => l10n.suggestionsHowRemoveOldCopy,
  FlagSolution.ignore => l10n.suggestionsHowIgnore,
  FlagSolution.importAnyway => l10n.suggestionsHowImportAnyway,
  FlagSolution.makeThumbnail => l10n.suggestionsHowMakeThumbnail,
  FlagSolution.getFromPhotos => l10n.suggestionsHowGetFromPhotos,
  FlagSolution.removeFromLibrary => l10n.suggestionsHowRemoveFromLibrary,
  FlagSolution.finishOptimize => l10n.suggestionsHowFinishOptimize,
  FlagSolution.removeExtraCopies => l10n.suggestionsHowRemoveExtraCopies,
  FlagSolution.removeImportCopy => l10n.suggestionsHowRemoveImportCopy,
  FlagSolution.attachLiveHalf => l10n.suggestionsHowAttachLiveHalf,
};

/// The fine print, shown on the action's page before anything runs.
String? solutionDetail(AppLocalizations l10n, FlagSolution s) => switch (s) {
  FlagSolution.removeFromDevice => l10n.suggestionsConfirmRemoveBody,
  FlagSolution.optimize => l10n.suggestionsConfirmOptimizeBody,
  FlagSolution.optimizeRemote => l10n.suggestionsConfirmOptimizeRemoteBody,
  FlagSolution.reformat => l10n.suggestionsConfirmReformatBody,
  FlagSolution.removeOldCopy => l10n.suggestionsConfirmOldCopyBody,
  FlagSolution.importAnyway => l10n.suggestionsConfirmImportAnywayBody,
  FlagSolution.removeFromLibrary =>
    l10n.suggestionsConfirmRemoveFromLibraryBody,
  FlagSolution.finishOptimize => l10n.suggestionsConfirmFinishOptimizeBody,
  FlagSolution.removeExtraCopies => l10n.suggestionsConfirmExtraCopiesBody,
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
    return l10n.suggestionsConfirmRemoveFromLibraryBody;
  }
  if (!solutionReplacesOriginal(s)) return l10n.suggestionsPermanent;
  final only = chosen
      .where((f) => f.record == null || f.record!.localDeleted)
      .length;
  return [
    l10n.suggestionsPermanentReplace,
    if (only > 0) l10n.suggestionsPermanentOnlyCopy(only),
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
  FlagSolution.attachLiveHalf => CupertinoIcons.link,
};

String problemLabel(AppLocalizations l10n, FlagProblem p) => switch (p) {
  FlagProblem.onDevice => l10n.storageIssueOnDevice,
  FlagProblem.largeFile => l10n.storageIssueLargeFile,
  FlagProblem.highResolution => l10n.storageIssueHighResolution,
  FlagProblem.optimizableFormat => l10n.storageIssueOptimizableFormat,
  FlagProblem.offProtocol => l10n.suggestionsProblemOffProtocol,
  FlagProblem.orphanThumbnail => l10n.suggestionsProblemOrphan,
  FlagProblem.unclaimed => l10n.suggestionsProblemUnclaimed,
  FlagProblem.likelyLeftover => l10n.suggestionsProblemLeftover,
  FlagProblem.duplicate => l10n.suggestionsProblemDuplicate,
  FlagProblem.noThumbnail => l10n.suggestionsProblemNoThumbnail,
  FlagProblem.missingFromBucket => l10n.suggestionsProblemMissing,
  FlagProblem.leftoverCopy => l10n.suggestionsProblemLeftoverCopy,
  FlagProblem.extraCopies => l10n.suggestionsProblemExtraCopies,
  FlagProblem.liveHalf => l10n.suggestionsProblemLiveHalf,
};

/// Why this item is listed. A photo's tags explain its size; a bucket file
/// needs the sentence.
String flagReason(AppLocalizations l10n, Flag flag) {
  final bucket = flag.bucket;
  if (flag.asset != null) {
    if (flag.problems.contains(FlagProblem.noThumbnail)) {
      return l10n.suggestionsNoThumbnailReason;
    }
    if (flag.problems.contains(FlagProblem.leftoverCopy)) {
      return l10n.suggestionsLeftoverCopyReason;
    }
    if (flag.problems.contains(FlagProblem.extraCopies)) {
      return l10n.suggestionsExtraCopiesReason;
    }
    if (flag.problems.contains(FlagProblem.duplicate)) {
      return l10n.suggestionsDuplicateOf(flag.name);
    }
    return flag.solutions.contains(FlagSolution.getFromPhotos)
        ? l10n.suggestionsLostInPhotosReason
        : l10n.suggestionsLostReason;
  }
  if (flag.storage?.duplicateOf case final kept?) {
    return l10n.suggestionsDuplicateOf(kept);
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
          l10n.suggestionsHighResolution(record!.width!, record.height!)
        else if (p != FlagProblem.onDevice)
          problemLabel(l10n, p),
    ].join(' · ');
  }
  if (bucket.likelyDuplicateOf case final key?) {
    final name = key.split('/').last;
    return switch (bucket.kind) {
      FlagKind.oldCopy => l10n.suggestionsOldCopyReason(name),
      FlagKind.duplicate => l10n.suggestionsDuplicateOf(name),
      _ => l10n.suggestionsLikelyDuplicate(name),
    };
  }
  return switch (bucket.kind) {
    FlagKind.offProtocol => l10n.suggestionsOffProtocolReason,
    FlagKind.orphanThumbnail => l10n.suggestionsOrphanReason,
    FlagKind.unclaimed => l10n.suggestionsUnclaimedReason,
    FlagKind.liveHalf => l10n.suggestionsLiveHalfReason,
    FlagKind.likelyLeftover ||
    FlagKind.oldCopy ||
    FlagKind.duplicate => l10n.suggestionsLeftoverReason,
  };
}

String? failureNote(AppLocalizations l10n, FixJob? job) {
  if (job == null || job.state != FixJobState.failed) return null;
  return switch (job.failure) {
    FixFailure.needsAlbum => l10n.suggestionsNeedsAlbum,
    FixFailure.unverified => l10n.suggestionsUnverified,
    _ =>
      job.detail == null
          ? l10n.suggestionsFailed
          : '${l10n.suggestionsFailed} (${job.detail})',
  };
}

/// How long something should take, rounded the way a person would say it.
String etaLabel(AppLocalizations l10n, Duration d) {
  final seconds = d.inSeconds;
  if (seconds < 10) return l10n.suggestionsEtaSeconds;
  if (seconds < 60) return l10n.suggestionsEtaUnderMinute;
  final minutes = (seconds / 60).ceil();
  if (minutes < 60) return l10n.suggestionsEtaMinutes(minutes);
  return l10n.suggestionsEtaHours(minutes ~/ 60, minutes % 60);
}

String actionLabel(AppLocalizations l10n, FixAction a) => switch (a) {
  FixAction.optimizing => l10n.suggestionsStepOptimizing,
  FixAction.downloading => l10n.suggestionsStepDownloading,
  FixAction.uploading => l10n.suggestionsStepUploading,
  FixAction.deleting => l10n.suggestionsStepDeleting,
  FixAction.renaming => l10n.suggestionsStepRenaming,
  FixAction.adding => l10n.suggestionsStepAdding,
  FixAction.converting => l10n.suggestionsStepConverting,
  FixAction.confirming => l10n.suggestionsStepConfirming,
};
