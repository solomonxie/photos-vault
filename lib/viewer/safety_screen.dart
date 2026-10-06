import 'package:flutter/cupertino.dart';
import 'package:intl/intl.dart';

import '../backup/bucket_backup.dart';
import '../backup/icloud_backup.dart';
import '../backup/icloud_drive.dart';
import '../l10n/app_localizations.dart';
import '../settings/backup_targets_store.dart';
import '../settings/s3_backup_target.dart';
import '../settings/settings_section.dart';
import '../storage/asset_record_store.dart';
import '../upload/backup_verifier.dart';
import '../upload/library_restore.dart';

/// The one page that answers "will I lose this, and can I find it again".
///
/// Everything else the app says about safety is about *confidentiality* —
/// no server, no account, nothing sent anywhere. That is the wrong axis for
/// the question people actually hesitate on, which is whether the photos
/// they hand over are still going to be there, and findable, later.
///
/// So: every copy that exists, what each one survives, **when a real bucket
/// last confirmed it** rather than when this app last believed it, and the
/// steps to get everything back with none of this software involved. The
/// last part is the point. A backup you can only open with the app that
/// wrote it is a promise about the app, not about the photos.
class SafetyScreen extends StatefulWidget {
  const SafetyScreen({
    super.key,
    required this.recordStore,
    required this.targetsStore,
    required this.verifier,
    required this.icloudBackup,
    required this.bucketBackup,
    this.libraryRestore,
    this.onRestored,
    this.onAddBucket,
  });

  final AssetRecordStore recordStore;
  final BackupTargetsStore targetsStore;
  final BackupVerifier verifier;
  final ICloudBackup icloudBackup;
  final BucketBackup bucketBackup;

  /// Refills the grid from the bucket's `thumbnails/` after a reinstall —
  /// null hides the row. See `../upload/library_restore.dart`.
  final LibraryRestore? libraryRestore;

  /// Called once a refill has actually fetched something, so the grid
  /// underneath reloads rather than staying blank until the next launch.
  final VoidCallback? onRestored;

  /// Opens Cloud settings, for the case this page exists to catch: no
  /// bucket at all, so this phone is the only copy of everything.
  final VoidCallback? onAddBucket;

  @override
  State<SafetyScreen> createState() => _SafetyScreenState();
}

class _SafetyScreenState extends State<SafetyScreen> {
  List<S3BackupTarget> _targets = const [];
  int _photos = 0;
  int _backedUp = 0;
  int _notBackedUp = 0;
  int _cloudOnly = 0;

  DateTime? _icloudAt;
  bool _icloudOn = false;
  ICloudState _icloudState = ICloudState.unsupported;
  DateTime? _bucketDataAt;
  bool _bucketDataOn = false;

  DateTime? _verifiedAt;
  ReconcileReport? _check;
  DrillReport? _drill;
  int _requeued = 0;
  int _lost = 0;

  /// Whether an iCloud row belongs on screen at all. An unsigned build or
  /// a non-iOS shell can't offer it and the user can't fix that, so the row
  /// would be doubt with no action attached. See [ICloudState].
  bool get _icloudPossible =>
      _icloudState != ICloudState.unsupported &&
      _icloudState != ICloudState.notEntitled;

  bool _loading = true;
  bool _checking = false;
  bool _drilling = false;

  int _owedThumbnails = 0;
  RestoreProgress? _refill;
  bool _refilling = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final records = await widget.recordStore.listAll();
    var photos = 0;
    var backedUp = 0;
    var cloudOnly = 0;
    for (final record in records) {
      if (record.isDeleted) continue;
      // Hidden photos are counted nowhere on this page. A number that moved
      // when something was hidden would answer the one question the private
      // album exists not to answer.
      if (record.passcodeHash != null || record.isHidden) continue;
      photos++;
      if (record.isFullyBackedUp) backedUp++;
      if (record.localDeleted) cloudOnly++;
    }

    final targets = await widget.targetsStore.loadAll();
    final icloudState = await widget.icloudBackup.drive.status();

    if (!mounted) return;
    setState(() {
      _targets = targets;
      _photos = photos;
      _backedUp = backedUp;
      _notBackedUp = photos - backedUp;
      _cloudOnly = cloudOnly;
      _loading = false;
    });

    final icloudOn = await widget.icloudBackup.isEnabled();
    final icloudAt = icloudState == ICloudState.available
        ? await widget.icloudBackup.drive.latestWriteAt()
        : null;
    final bucketOn = await widget.bucketBackup.isEnabled();
    final bucketAt = await widget.bucketBackup.lastBackupAt();
    final verifiedAt = await widget.verifier.lastVerifiedAt();
    final owed = (await widget.libraryRestore?.owed())?.length ?? 0;
    if (!mounted) return;
    setState(() {
      _owedThumbnails = owed;
      _icloudState = icloudState;
      _icloudOn = icloudOn;
      _icloudAt = icloudAt;
      _bucketDataOn = bucketOn;
      _bucketDataAt = bucketAt;
      _verifiedAt = verifiedAt;
    });
  }

  // ------------------------------------------------------------- the checks

  Future<void> _checkNow() async {
    setState(() {
      _checking = true;
      _drill = null;
    });
    ReconcileReport? report;
    var requeued = 0;
    var lost = 0;
    try {
      report = await widget.verifier.reconcile();
      // Finding out is only half of it: a photo the bucket hasn't got goes
      // back in the queue, so the next sync makes the record true.
      if (report.reachedBucket && !report.isClean) {
        final repair = await widget.verifier.repair(report);
        requeued = repair.requeued;
        lost = repair.lost;
      }
    } catch (_) {
      report = null;
    }
    if (!mounted) return;
    setState(() {
      _check = report;
      _requeued = requeued;
      _lost = lost;
      _checking = false;
      _verifiedAt = report?.reachedBucket == true ? report?.at : _verifiedAt;
    });
    if (requeued > 0 || lost > 0) await _load();
  }

  Future<void> _testRestore() async {
    setState(() {
      _drilling = true;
      _check = null;
    });
    DrillReport? report;
    try {
      report = await widget.verifier.testRestore();
    } catch (_) {
      report = null;
    }
    if (!mounted) return;
    setState(() {
      _drill = report;
      _drilling = false;
      _verifiedAt = report?.allVerified == true ? report?.at : _verifiedAt;
    });
  }

  Future<void> _refillGrid() async {
    final restore = widget.libraryRestore;
    if (restore == null || _refilling) return;
    setState(() => _refilling = true);
    RestoreProgress? last;
    try {
      last = await restore.run(
        onProgress: (progress) {
          if (mounted) setState(() => _refill = progress);
        },
      );
    } catch (_) {
      // Offline, expired credentials — whatever arrived stays arrived.
    }
    if (!mounted) return;
    setState(() {
      _refilling = false;
      _refill = last;
    });
    if ((last?.done ?? 0) > 0) {
      widget.onRestored?.call();
      await _load();
    }
  }

  // -------------------------------------------------------------------- copy

  String _when(AppLocalizations l10n, DateTime at) {
    final now = DateTime.now();
    final sameDay =
        at.year == now.year && at.month == now.month && at.day == now.day;
    return sameDay
        ? l10n.safetyWhenToday(DateFormat.jm().format(at))
        : DateFormat.yMMMd().add_jm().format(at);
  }

  /// The one line under the buttons: whatever the most recent real answer
  /// was, in full. Blank is not an option — "no idea" is itself the answer
  /// this page came to give.
  String _statusLine(AppLocalizations l10n) {
    final drill = _drill;
    if (drill != null) {
      if (drill.attempted == 0) return l10n.safetyDrillNothingToTry;
      return drill.allVerified
          ? l10n.safetyDrillVerified(drill.verified)
          : l10n.safetyDrillFailed(drill.attempted - drill.verified);
    }
    final check = _check;
    if (check != null) {
      if (!check.reachedBucket) return l10n.safetyCheckUnreachable;
      if (_lost > 0) return l10n.safetyCheckLost(_lost, _requeued);
      if (check.missingLocalIds.isEmpty) {
        return check.missingThumbnailIds.isEmpty
            ? l10n.safetyCheckAllPresent(check.present)
            : l10n.safetyCheckThumbnailsMissing(
                check.missingThumbnailIds.length,
              );
      }
      return l10n.safetyCheckMissing(check.missingLocalIds.length, _requeued);
    }
    final at = _verifiedAt;
    return at == null
        ? l10n.safetyNeverChecked
        : l10n.safetyLastChecked(_when(l10n, at));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return CupertinoPageScaffold(
      backgroundColor: settingsPageBackground,
      navigationBar: CupertinoNavigationBar(
        backgroundColor: settingsPageBackground,
        middle: Text(l10n.safetyTitle),
      ),
      child: SafeArea(
        child: _loading
            ? const Center(child: CupertinoActivityIndicator())
            : ListView(
                padding: const EdgeInsets.only(top: 12, bottom: 32),
                children: [
                  _copies(l10n),
                  const SettingsSectionDivider(),
                  _appData(l10n),
                  const SettingsSectionDivider(),
                  _recovery(l10n),
                ],
              ),
      ),
    );
  }

  // ------------------------------------------------------------------ copies

  Widget _copies(AppLocalizations l10n) {
    final busy = _checking || _drilling;
    return SettingsSection(
      heading: l10n.safetyCopiesHeading,
      hint: l10n.safetyCopiesHint,
      footer: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_statusLine(l10n), style: settingsFooterStyle),
          const SizedBox(height: 10),
          Row(
            children: [
              SettingsPillButton(
                icon: CupertinoIcons.arrow_2_circlepath,
                label: _checking ? l10n.safetyChecking : l10n.safetyCheckNow,
                onPressed: busy || _targets.isEmpty ? null : _checkNow,
              ),
              const SizedBox(width: 8),
              SettingsPillButton(
                icon: CupertinoIcons.arrow_down_circle,
                label: _drilling
                    ? l10n.safetyTestingRestore
                    : l10n.safetyTestRestore,
                onPressed: busy || _targets.isEmpty ? null : _testRestore,
              ),
            ],
          ),
        ],
      ),
      children: [
        SettingsRow(
          leading: const SettingsIconTile(
            icon: CupertinoIcons.device_phone_portrait,
            color: CupertinoColors.systemGrey,
          ),
          title: l10n.safetyDeviceRow,
          subtitle: l10n.safetyPhotoCount(_photos),
          detail: _cloudOnly > 0
              ? l10n.safetyDeviceCloudOnly(_cloudOnly)
              : l10n.safetyDeviceNote,
        ),
        const SettingsHairline(indent: settingsRowIndent),
        if (_targets.isEmpty)
          SettingsRow(
            leading: const SettingsIconTile(
              icon: CupertinoIcons.exclamationmark_triangle_fill,
              color: CupertinoColors.systemOrange,
            ),
            title: l10n.safetyNoBucketRow,
            subtitle: l10n.safetyNoBucketSubtitle,
            trailing: widget.onAddBucket == null
                ? null
                : const Icon(
                    CupertinoIcons.chevron_right,
                    size: 16,
                    color: settingsTertiary,
                  ),
            onTap: widget.onAddBucket,
          )
        else
          for (final target in _targets) ...[
            SettingsRow(
              leading: const SettingsIconTile(
                icon: CupertinoIcons.archivebox_fill,
                color: CupertinoColors.systemTeal,
              ),
              title: target.bucket,
              subtitle: l10n.safetyBucketOriginals(_backedUp, _photos),
              detail: _notBackedUp > 0
                  ? l10n.safetyBucketWaiting(_notBackedUp)
                  : l10n.safetyBucketComplete,
            ),
            const SettingsHairline(indent: settingsRowIndent),
          ],
        // Hidden outright when the platform can't offer it — an unsigned
        // build or a non-iOS shell. A row saying "unavailable, and there's
        // nothing you can do" is a row that only adds doubt.
        if (_icloudPossible)
          SettingsRow(
            leading: SettingsIconTile(
              icon: CupertinoIcons.cloud_fill,
              color: _icloudOn && _icloudState == ICloudState.available
                  ? CupertinoColors.systemBlue
                  : CupertinoColors.systemGrey,
            ),
            title: l10n.safetyICloudRow,
            subtitle: _icloudState != ICloudState.available
                ? l10n.safetyICloudOff
                : _icloudAt == null
                ? l10n.safetyICloudNever
                : l10n.safetyICloudCopied(_when(l10n, _icloudAt!)),
            detail: l10n.safetyICloudPath,
          ),
      ],
    );
  }

  // ---------------------------------------------------------------- app data

  Widget _appData(AppLocalizations l10n) {
    return SettingsSection(
      heading: l10n.safetyAppDataHeading,
      primary: false,
      hint: l10n.safetyAppDataHint,
      children: [
        SettingsRow(
          title: l10n.safetyAppDataBucketRow,
          subtitle: !_bucketDataOn
              ? l10n.safetyAppDataOff
              : _bucketDataAt == null
              ? l10n.safetyAppDataNever
              : l10n.safetyAppDataCopied(_when(l10n, _bucketDataAt!)),
        ),
        if (_icloudPossible) const SettingsHairline(),
        if (_icloudPossible)
          SettingsRow(
            title: l10n.safetyAppDataICloudRow,
            subtitle: !_icloudOn
                ? l10n.safetyAppDataOff
                : _icloudAt == null
                ? l10n.safetyAppDataNever
                : l10n.safetyAppDataCopied(_when(l10n, _icloudAt!)),
          ),
        // Only when there is something to refill. On a phone whose grid is
        // already full this row would be an offer to fix what isn't broken.
        if (widget.libraryRestore != null &&
            (_owedThumbnails > 0 || _refill != null)) ...[
          const SettingsHairline(),
          SettingsRow(
            title: l10n.safetyRefillGridRow,
            subtitle: _refillLine(l10n),
            detail: l10n.safetyRefillGridSubtitle,
            trailing: _refilling
                ? const CupertinoActivityIndicator(radius: 8)
                : const Icon(
                    CupertinoIcons.chevron_right,
                    size: 16,
                    color: settingsTertiary,
                  ),
            onTap: _refilling ? null : _refillGrid,
          ),
        ],
      ],
    );
  }

  String _refillLine(AppLocalizations l10n) {
    final progress = _refill;
    if (progress == null) return l10n.safetyRefillOwed(_owedThumbnails);
    if (_refilling) {
      return l10n.safetyRefillRunning(progress.done, progress.total);
    }
    return progress.failed > 0
        ? l10n.safetyRefillPartial(progress.done, progress.failed)
        : l10n.safetyRefillDone(progress.done);
  }

  // ---------------------------------------------------------------- recovery

  Widget _recovery(AppLocalizations l10n) {
    final prefix = _targets.isEmpty ? null : _targets.first.prefix;
    return SettingsSection(
      heading: l10n.safetyRecoveryHeading,
      primary: false,
      hint: l10n.safetyRecoveryHint,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            settingsPagePadding,
            8,
            settingsPagePadding,
            0,
          ),
          child: Text(
            l10n.safetyRecoverySteps(prefix ?? 'photos/'),
            style: const TextStyle(
              fontSize: 13,
              height: 1.5,
              color: settingsSecondary,
            ),
          ),
        ),
      ],
    );
  }
}
