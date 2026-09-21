import 'package:flutter/cupertino.dart';

import '../l10n/app_localizations.dart';
import '../photos/analyze_queue.dart';
import '../photos/on_device_vision.dart';
import '../settings/backup_targets_store.dart' show SyncFrequency;
import '../settings/settings_section.dart';

/// What the pass is working through, and nothing else. What it *found* is
/// answered on the photo it's about — a photo screen can show the picture
/// the suggestion is about, and an inbox of little cards can't.
///
/// A page rather than a sheet: the list is long, rows lead somewhere (tap
/// one and its photo opens on top), and the controls above them are
/// settings you come back to — none of which a sheet you dismiss is for.
class AnalyzeQueueScreen extends StatefulWidget {
  const AnalyzeQueueScreen({super.key, required this.queue, this.onOpenAsset});

  final AnalyzeQueue queue;

  /// What a row tap does: the queue names photos, and the obvious question
  /// about a row is "which photo is that?". Absent, rows aren't tappable
  /// rather than tappable and inert.
  final Future<void> Function(String localId)? onOpenAsset;

  @override
  State<AnalyzeQueueScreen> createState() => _AnalyzeQueueScreenState();
}

class _AnalyzeQueueScreenState extends State<AnalyzeQueueScreen> {
  /// Null until asked. Says which of the two things is actually matching
  /// faces — a working fallback looks exactly like a working model until
  /// the answers are poor and nobody can say which produced them.
  Object? _faceModel;

  @override
  void initState() {
    super.initState();
    widget.queue.refresh();
    _loadFaceModel();
  }

  Future<void> _loadFaceModel() async {
    final status = await OnDeviceVisionService().faceModelStatus;
    if (mounted) setState(() => _faceModel = status);
  }

  String _stepLabel(AppLocalizations l10n, AnalyzeStep step) => switch (step) {
    AnalyzeStep.findFaces => l10n.analyzeQueueStepFaces,
    AnalyzeStep.suggest => l10n.analyzeQueueStepSuggest,
    AnalyzeStep.learnFaces => l10n.analyzeQueueStepLearnFaces,
    AnalyzeStep.matchFaces => l10n.analyzeQueueStepMatchFaces,
  };

  String _frequencyLabel(AppLocalizations l10n, SyncFrequency f) => switch (f) {
    SyncFrequency.manual => l10n.settingsSyncFrequencyManual,
    SyncFrequency.every15Minutes => l10n.settingsSyncFrequencyEvery15Minutes,
    SyncFrequency.everyHour => l10n.settingsSyncFrequencyEveryHour,
    SyncFrequency.every6Hours => l10n.settingsSyncFrequencyEvery6Hours,
    SyncFrequency.daily => l10n.settingsSyncFrequencyDaily,
  };

  /// "Analyze Now" means now: a paused queue would otherwise make the
  /// button do nothing and say nothing about why, same as Sync Now on the
  /// backup queue.
  Future<void> _runNow() async {
    await widget.queue.setPaused(false);
    await widget.queue.start();
  }

  /// Asked first, because it throws away work — not destructively (the
  /// names stay, nothing is re-billed), but it is minutes of the phone's
  /// time and the button is next to one that only clears a list.
  Future<void> _confirmRescan() async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showCupertinoDialog<bool>(
      context: context,
      builder: (dialogContext) => CupertinoAlertDialog(
        title: Text(l10n.analyzeQueueRescanConfirmTitle),
        content: Text(l10n.analyzeQueueRescanConfirmBody),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.actionCancel),
          ),
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.analyzeQueueRescanButton),
          ),
        ],
      ),
    );
    if (confirmed == true) await widget.queue.rescanAll();
  }

  Future<void> _pickFrequency() async {
    final l10n = AppLocalizations.of(context)!;
    final picked = await showCupertinoModalPopup<SyncFrequency>(
      context: context,
      builder: (sheetContext) => CupertinoActionSheet(
        title: Text(l10n.analyzeQueueFrequencyHeading),
        message: Text(l10n.analyzeQueueFrequencyHint),
        actions: [
          for (final f in SyncFrequency.values)
            CupertinoActionSheetAction(
              onPressed: () => Navigator.of(sheetContext).pop(f),
              child: Text(
                f == widget.queue.frequency.value
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
    if (picked != null) await widget.queue.setFrequency(picked);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return CupertinoPageScaffold(
      backgroundColor: settingsPageBackground,
      navigationBar: CupertinoNavigationBar(
        backgroundColor: settingsPageBackground,
        middle: Text(l10n.collectionsAnalyzeQueueRow),
        trailing: ValueListenableBuilder<bool>(
          valueListenable: widget.queue.running,
          builder: (context, running, _) => running
              ? const CupertinoActivityIndicator(radius: 8)
              : const SizedBox.shrink(),
        ),
      ),
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.only(top: 16, bottom: 32),
          children: [
            ValueListenableBuilder<int>(
              valueListenable: widget.queue.remaining,
              builder: (context, remaining, _) => SettingsSection(
                heading: l10n.analyzeQueueRemaining(remaining),
                children: [
                  _controls(l10n),
                  const SettingsHairline(),
                  _faceModelRow(l10n),
                  const SettingsHairline(),
                  _paidRow(l10n),
                ],
              ),
            ),
            const SettingsSectionDivider(),
            _jobs(l10n),
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------------------------ queue

  Widget _jobs(AppLocalizations l10n) {
    return ValueListenableBuilder<List<AnalyzeJob>>(
      valueListenable: widget.queue.jobs,
      builder: (context, jobs, _) => SettingsSection(
        heading: l10n.analyzeQueueListHeading,
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
                    l10n.analyzeQueueEmpty,
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
                    stepLabel: _stepLabel(l10n, jobs[i].step),
                    onOpen:
                        jobs[i].localId == null || widget.onOpenAsset == null
                        ? null
                        : () => widget.onOpenAsset!(jobs[i].localId!),
                  ),
                ],
              ],
      ),
    );
  }

  Widget _controls(AppLocalizations l10n) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(settingsPagePadding, 4, 12, 12),
      // Whether it is *running* is the only state these controls turn on;
      // `paused` is how that state is persisted, not what it looks like.
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          // One control, not two. Running and stopped are the same
          // question asked from opposite sides, and a separate Pause
          // beside a separate Analyze Now meant one of them was always
          // the wrong thing to press.
          //
          // The pass is Manual by default, and Manual means it never
          // starts itself — so without this there is no way to start it
          // at all, and the queue just shows a number that never moves.
          ValueListenableBuilder<bool>(
            valueListenable: widget.queue.running,
            builder: (context, running, _) => SettingsPillButton(
              icon: running
                  ? CupertinoIcons.pause_fill
                  : CupertinoIcons.play_fill,
              label: running
                  ? l10n.backupQueuePauseAction
                  : l10n.analyzeQueueRunNowButton,
              onPressed: running ? () => widget.queue.setPaused(true) : _runNow,
            ),
          ),
          SettingsPillButton(
            icon: CupertinoIcons.arrow_2_circlepath,
            label: l10n.analyzeQueueRescanButton,
            onPressed: _confirmRescan,
          ),
          ValueListenableBuilder<SyncFrequency>(
            valueListenable: widget.queue.frequency,
            builder: (context, frequency, _) => SettingsPillButton(
              icon: CupertinoIcons.clock,
              label: _frequencyLabel(l10n, frequency),
              onPressed: _pickFrequency,
            ),
          ),
          SettingsPillButton(
            icon: CupertinoIcons.clear_circled,
            label: l10n.backupQueueClearButton,
            onPressed: widget.queue.clear,
          ),
          ValueListenableBuilder<int>(
            valueListenable: widget.queue.pace,
            builder: (context, pace, _) => SettingsStepper(
              label: l10n.backupQueueSpeed(pace),
              decreaseSemanticLabel: l10n.backupQueueSlowerShort,
              increaseSemanticLabel: l10n.backupQueueFasterShort,
              onDecrease: pace <= 1
                  ? null
                  : () => widget.queue.setPace(pace - 1),
              onIncrease: pace >= 4
                  ? null
                  : () => widget.queue.setPace(pace + 1),
            ),
          ),
        ],
      ),
    );
  }

  Widget _faceModelRow(AppLocalizations l10n) {
    final status = _faceModel;
    if (status == null) return const SizedBox.shrink();
    final on = status == true;
    return Padding(
      padding: const EdgeInsets.fromLTRB(settingsPagePadding, 10, 12, 10),
      child: Row(
        children: [
          Icon(
            on
                ? CupertinoIcons.checkmark_seal_fill
                : CupertinoIcons.exclamationmark_triangle_fill,
            size: 18,
            color: on
                ? CupertinoColors.systemGreen
                : CupertinoColors.systemOrange,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              on ? l10n.analyzeQueueFaceModelOn : l10n.analyzeQueueFaceModelOff,
              style: settingsRowSubtitleStyle,
            ),
          ),
        ],
      ),
    );
  }

  /// The one thing here that costs money, on its own row, saying what it
  /// costs before it's switched on rather than after the bill.
  Widget _paidRow(AppLocalizations l10n) {
    return ValueListenableBuilder<bool>(
      valueListenable: widget.queue.canSuggest,
      builder: (context, canSuggest, _) => ValueListenableBuilder<bool>(
        valueListenable: widget.queue.suggest,
        builder: (context, on, _) => Padding(
          padding: const EdgeInsets.fromLTRB(settingsPagePadding, 10, 12, 10),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.analyzeQueuePaidTitle,
                      style: settingsRowTitleStyle,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      canSuggest
                          ? l10n.analyzeQueuePaidNote
                          : l10n.analyzeQueuePaidNoKey,
                      style: settingsRowSubtitleStyle,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              CupertinoSwitch(
                value: on && canSuggest,
                onChanged: canSuggest ? widget.queue.setSuggest : null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _JobRow extends StatelessWidget {
  const _JobRow({required this.job, required this.stepLabel, this.onOpen});

  final AnalyzeJob job;
  final String stepLabel;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
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
                Text(stepLabel, style: settingsRowSubtitleStyle),
                if (job.status == AnalyzeJobStatus.failed && job.note != null)
                  Text(
                    job.note!,
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
          switch (job.status) {
            AnalyzeJobStatus.pending => Text(
              l10n.backupQueueWaiting,
              style: settingsRowDetailStyle,
            ),
            AnalyzeJobStatus.running => const CupertinoActivityIndicator(
              radius: 9,
            ),
            AnalyzeJobStatus.done => const Icon(
              CupertinoIcons.checkmark_circle_fill,
              color: CupertinoColors.systemGreen,
              size: 20,
            ),
            AnalyzeJobStatus.failed => const Icon(
              CupertinoIcons.exclamationmark_circle_fill,
              color: CupertinoColors.systemOrange,
              size: 20,
            ),
          },
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
}
