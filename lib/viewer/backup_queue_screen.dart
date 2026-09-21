import 'package:flutter/cupertino.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../settings/backup_targets_store.dart';
import '../settings/settings_section.dart';
import '../upload/sync_job.dart';
import '../upload/sync_queue.dart';

/// Everything the app owes a bucket, one row per unit of work — uploads,
/// the `.mov` half of a Live Photo, thumbnails, and the change checks that
/// re-hash a file to spot an edit.
///
/// A page rather than the sheet it used to be, and a sibling of
/// `AnalyzeQueueScreen` rather than a block of pills on Cloud Settings.
/// Called the *backup* queue, not the sync queue: what it does is put your
/// photos somewhere safe, and "sync" reads as two-way.
/// The two queues are the same kind of thing — a long list, paced, pausable,
/// with settings you come back to — so they read the same and sit next to
/// each other. Cloud Settings goes back to being about the connections.
class BackupQueueScreen extends StatefulWidget {
  const BackupQueueScreen({
    super.key,
    required this.queue,
    required this.settingsStore,
    this.syncEverything,
    this.onOpenAsset,
  });

  final SyncQueue queue;

  /// Where the schedule and the upload format live.
  final BackupTargetsStore settingsStore;

  /// What Sync Now does. Absent, the button is there and dead rather than
  /// missing — a manual action that silently isn't offered is worse than
  /// one that visibly can't run.
  final Future<int> Function()? syncEverything;

  /// What a row tap does: the queue names photos, and the obvious question
  /// about a row — especially a failed one — is "which photo is that?".
  final Future<void> Function(String localId)? onOpenAsset;

  @override
  State<BackupQueueScreen> createState() => _BackupQueueScreenState();
}

class _BackupQueueScreenState extends State<BackupQueueScreen> {
  BackupFormat _format = BackupFormat.original;
  SyncFrequency _frequency = SyncFrequency.manual;
  DateTime? _lastSyncAt;
  bool _syncing = false;

  @override
  void initState() {
    super.initState();
    widget.queue.refresh();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    try {
      final format = await widget.settingsStore.getBackupFormat();
      final frequency = await widget.settingsStore.getSyncFrequency();
      final lastSyncAt = await widget.settingsStore.getLastSyncAt();
      if (!mounted) return;
      setState(() {
        _format = format;
        _frequency = frequency;
        _lastSyncAt = lastSyncAt;
      });
    } catch (_) {
      // Secure storage unavailable — the defaults above are a working
      // page, and the queue itself is what this screen is for.
    }
  }

  String _kindLabel(AppLocalizations l10n, SyncJobKind kind) => switch (kind) {
    SyncJobKind.checkChanges => l10n.backupQueueKindCheck,
    SyncJobKind.uploadOriginal => l10n.backupQueueKindOriginal,
    SyncJobKind.uploadThumbnail => l10n.backupQueueKindThumbnail,
    SyncJobKind.uploadLivePhoto => l10n.backupQueueKindLivePhoto,
    SyncJobKind.analyzePhoto => l10n.backupQueueKindAnalyze,
  };

  String _frequencyLabel(AppLocalizations l10n, SyncFrequency f) => switch (f) {
    SyncFrequency.manual => l10n.settingsSyncFrequencyManual,
    SyncFrequency.every15Minutes => l10n.settingsSyncFrequencyEvery15Minutes,
    SyncFrequency.everyHour => l10n.settingsSyncFrequencyEveryHour,
    SyncFrequency.every6Hours => l10n.settingsSyncFrequencyEvery6Hours,
    SyncFrequency.daily => l10n.settingsSyncFrequencyDaily,
  };

  String _formatLabel(AppLocalizations l10n, BackupFormat f) => switch (f) {
    BackupFormat.original => l10n.settingsBackupFormatOriginal,
    BackupFormat.optimized => l10n.settingsBackupFormatOptimized,
  };

  Future<void> _pickFrequency() async {
    final l10n = AppLocalizations.of(context)!;
    final picked = await showCupertinoModalPopup<SyncFrequency>(
      context: context,
      builder: (sheetContext) => CupertinoActionSheet(
        title: Text(l10n.settingsSyncFrequencyHeading),
        message: Text(l10n.settingsSyncFrequencyHint),
        actions: [
          for (final f in SyncFrequency.values)
            CupertinoActionSheetAction(
              onPressed: () => Navigator.of(sheetContext).pop(f),
              child: Text(
                f == _frequency
                    ? '${_frequencyLabel(l10n, f)}  ✓'
                    : _frequencyLabel(l10n, f),
              ),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(sheetContext).pop(),
          child: Text(l10n.actionCancel),
        ),
      ),
    );
    if (picked == null) return;
    setState(() => _frequency = picked);
    await widget.settingsStore.setSyncFrequency(picked);
  }

  /// The same drop-down the schedule uses, for the same reason: two choices
  /// and a sentence about each is a sheet's worth of content, not half a
  /// page of radio rows under a setting that gets changed once.
  Future<void> _pickFormat() async {
    final l10n = AppLocalizations.of(context)!;
    final picked = await showCupertinoModalPopup<BackupFormat>(
      context: context,
      builder: (sheetContext) => CupertinoActionSheet(
        title: Text(l10n.settingsBackupFormatHeading),
        // What each one costs you, where the choice is actually made.
        message: Text(
          '${l10n.settingsBackupFormatOriginal}: '
          '${l10n.settingsBackupFormatOriginalDescription}\n\n'
          '${l10n.settingsBackupFormatOptimized}: '
          '${l10n.settingsBackupFormatOptimizedDescription}\n\n'
          '${l10n.settingsBackupFormatVideoNote}\n'
          '${l10n.settingsBackupFormatFolderNote}',
        ),
        actions: [
          for (final f in BackupFormat.values)
            CupertinoActionSheetAction(
              onPressed: () => Navigator.of(sheetContext).pop(f),
              child: Text(
                f == _format
                    ? '${_formatLabel(l10n, f)}  ✓'
                    : _formatLabel(l10n, f),
              ),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(sheetContext).pop(),
          child: Text(l10n.actionCancel),
        ),
      ),
    );
    if (picked == null) return;
    setState(() => _format = picked);
    await widget.settingsStore.setBackupFormat(picked);
  }

  Future<void> _syncNow() async {
    final syncEverything = widget.syncEverything;
    if (syncEverything == null || _syncing) return;
    setState(() => _syncing = true);
    try {
      await syncEverything();
      await widget.settingsStore.setLastSyncAt(DateTime.now());
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
    await _loadSettings();
    await widget.queue.refresh();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return CupertinoPageScaffold(
      backgroundColor: settingsPageBackground,
      navigationBar: CupertinoNavigationBar(
        backgroundColor: settingsPageBackground,
        middle: Text(l10n.collectionsBackupQueueRow),
        trailing: ValueListenableBuilder<bool>(
          valueListenable: widget.queue.draining,
          builder: (context, draining, _) => draining
              ? const CupertinoActivityIndicator(radius: 8)
              : const SizedBox.shrink(),
        ),
      ),
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.only(top: 16, bottom: 32),
          children: [
            ValueListenableBuilder<List<SyncJob>>(
              valueListenable: widget.queue.jobs,
              builder: (context, jobs, _) => SettingsSection(
                heading: l10n.backupQueueHeader(
                  jobs.where((job) => !job.isFinished).length,
                ),
                children: [_controls(l10n), const SettingsHairline(), _note()],
              ),
            ),
            const SettingsSectionDivider(),
            _jobs(l10n),
          ],
        ),
      ),
    );
  }

  /// When it last ran, plus why nothing new is going in if that's the
  /// case. A queue that quietly refuses work looks identical to one with
  /// nothing to do.
  Widget _note() {
    final l10n = AppLocalizations.of(context)!;
    return ValueListenableBuilder<List<SyncJob>>(
      valueListenable: widget.queue.jobs,
      builder: (context, jobs, _) => ValueListenableBuilder<bool>(
        valueListenable: widget.queue.paused,
        builder: (context, paused, _) => Padding(
          padding: const EdgeInsets.fromLTRB(settingsPagePadding, 10, 12, 10),
          child: Text(
            paused
                ? l10n.backupQueuePausedNote
                : _atCapacity(jobs)
                ? l10n.backupQueueFullNote
                : _lastSyncAt == null
                ? l10n.settingsLastSyncedNever
                : l10n.settingsLastSyncedAt(
                    DateFormat.MMMd().add_jm().format(_lastSyncAt!),
                  ),
            style: settingsRowSubtitleStyle,
          ),
        ),
      ),
    );
  }

  static bool _atCapacity(List<SyncJob> jobs) =>
      jobs
          .where(
            (j) =>
                j.status == SyncJobStatus.pending ||
                j.status == SyncJobStatus.running ||
                j.status == SyncJobStatus.failed,
          )
          .length >=
      SyncQueue.capacity;

  Widget _controls(AppLocalizations l10n) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(settingsPagePadding, 4, 12, 12),
      child: ValueListenableBuilder<bool>(
        valueListenable: widget.queue.paused,
        builder: (context, paused, _) => Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            SettingsPillButton(
              icon: CupertinoIcons.arrow_2_circlepath,
              label: _syncing
                  ? l10n.settingsSyncingMessage
                  : l10n.settingsSyncNowButton,
              // Never a silent no-op: with nothing to sync with, the
              // control stays visible but dead.
              onPressed: widget.syncEverything == null || _syncing
                  ? null
                  : _syncNow,
            ),
            // Pause is the one that stops everything, so it carries the
            // state word.
            SettingsPillButton(
              icon: paused
                  ? CupertinoIcons.play_fill
                  : CupertinoIcons.pause_fill,
              label: paused
                  ? l10n.backupQueueResumeAction
                  : l10n.backupQueuePauseAction,
              onPressed: () => widget.queue.setPaused(!paused),
            ),
            SettingsPillButton(
              icon: CupertinoIcons.clock,
              label: _frequencyLabel(l10n, _frequency),
              onPressed: _pickFrequency,
            ),
            SettingsPillButton(
              icon: CupertinoIcons.photo,
              label: _formatLabel(l10n, _format),
              onPressed: _pickFormat,
            ),
            SettingsPillButton(
              icon: CupertinoIcons.checkmark_circle,
              label: l10n.backupQueueClearSyncedShort,
              onPressed: widget.queue.clearSynced,
            ),
            SettingsPillButton(
              icon: CupertinoIcons.clear_circled,
              label: l10n.backupQueueClearButton,
              onPressed: widget.queue.clearQueue,
            ),
            ValueListenableBuilder<int>(
              valueListenable: widget.queue.concurrency,
              builder: (context, concurrency, _) => SettingsStepper(
                label: l10n.backupQueueSpeed(concurrency),
                decreaseSemanticLabel: l10n.backupQueueSlowerShort,
                increaseSemanticLabel: l10n.backupQueueFasterShort,
                onDecrease: concurrency <= 1
                    ? null
                    : () => widget.queue.setConcurrency(concurrency - 1),
                onIncrease: () => widget.queue.setConcurrency(concurrency + 1),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _jobs(AppLocalizations l10n) {
    return ValueListenableBuilder<List<SyncJob>>(
      valueListenable: widget.queue.jobs,
      builder: (context, jobs, _) => SettingsSection(
        heading: l10n.backupQueueListHeading,
        primary: false,
        children: jobs.isEmpty
            ? [
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    settingsPagePadding,
                    8,
                    settingsPagePadding,
                    0,
                  ),
                  child: Text(
                    l10n.backupQueueEmpty,
                    style: settingsFooterStyle,
                  ),
                ),
              ]
            : [
                for (var i = 0; i < jobs.length; i++) ...[
                  if (i > 0)
                    const SettingsHairline(indent: settingsPagePadding),
                  _JobRow(
                    job: jobs[i],
                    kindLabel: _kindLabel(l10n, jobs[i].kind),
                    onRetry: () => widget.queue.retry(jobs[i]),
                    onOpen: widget.onOpenAsset == null
                        ? null
                        : () => widget.onOpenAsset!(jobs[i].localId),
                  ),
                ],
              ],
      ),
    );
  }
}

class _JobRow extends StatelessWidget {
  const _JobRow({
    required this.job,
    required this.kindLabel,
    required this.onRetry,
    this.onOpen,
  });

  final SyncJob job;
  final String kindLabel;
  final VoidCallback onRetry;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final row = Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: settingsPagePadding,
        vertical: 10,
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  job.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: settingsRowTitleStyle,
                ),
                Text(kindLabel, style: settingsRowSubtitleStyle),
                if (job.status == SyncJobStatus.failed &&
                    job.errorMessage != null)
                  Text(
                    job.errorMessage!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: CupertinoColors.systemOrange,
                      fontSize: 12,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          _status(context),
        ],
      ),
    );
    if (onOpen == null) return row;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onOpen,
      child: row,
    );
  }

  Widget _status(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    switch (job.status) {
      case SyncJobStatus.pending:
        return Text(l10n.backupQueueWaiting, style: settingsRowDetailStyle);
      case SyncJobStatus.running:
        return const CupertinoActivityIndicator(radius: 9);
      case SyncJobStatus.done:
        return const Icon(
          CupertinoIcons.checkmark_circle_fill,
          color: CupertinoColors.systemGreen,
          size: 20,
        );
      case SyncJobStatus.failed:
        return CupertinoButton(
          padding: EdgeInsets.zero,
          minimumSize: Size.zero,
          onPressed: onRetry,
          child: const Icon(
            CupertinoIcons.arrow_clockwise_circle_fill,
            color: CupertinoColors.systemOrange,
            size: 22,
          ),
        );
    }
  }
}
