import 'package:flutter/cupertino.dart';

import '../l10n/app_localizations.dart';
import '../photos/analyze_queue.dart';
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
  @override
  void initState() {
    super.initState();
    widget.queue.refresh();
  }

  String _stepLabel(AppLocalizations l10n, AnalyzeStep step) => switch (step) {
    AnalyzeStep.findFaces => l10n.analyzeQueueStepFaces,
    AnalyzeStep.suggest => l10n.analyzeQueueStepSuggest,
  };

  String _frequencyLabel(AppLocalizations l10n, SyncFrequency f) => switch (f) {
    SyncFrequency.manual => l10n.settingsSyncFrequencyManual,
    SyncFrequency.every15Minutes => l10n.settingsSyncFrequencyEvery15Minutes,
    SyncFrequency.everyHour => l10n.settingsSyncFrequencyEveryHour,
    SyncFrequency.every6Hours => l10n.settingsSyncFrequencyEvery6Hours,
    SyncFrequency.daily => l10n.settingsSyncFrequencyDaily,
  };

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
      child: ValueListenableBuilder<bool>(
        valueListenable: widget.queue.paused,
        builder: (context, paused, _) => Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            SettingsPillButton(
              icon: paused
                  ? CupertinoIcons.play_fill
                  : CupertinoIcons.pause_fill,
              label: paused
                  ? l10n.backupQueueResumeAction
                  : l10n.backupQueuePauseAction,
              onPressed: () => widget.queue.setPaused(!paused),
            ),
            ValueListenableBuilder<SyncFrequency>(
              valueListenable: widget.queue.frequency,
              builder: (context, frequency, _) => SettingsPillButton(
                icon: CupertinoIcons.clock,
                label: _frequencyLabel(l10n, frequency),
                onPressed: _pickFrequency,
              ),
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
