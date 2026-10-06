import 'package:flutter/cupertino.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../upload/sync_job.dart';
import '../upload/sync_queue.dart';
import 'backup_targets_store.dart';
import 'settings_section.dart';

/// Everything the app owes a bucket, one row per unit of work, as a page of
/// its own: failures first, then what is running and waiting, then what is
/// done. Called the *backup* queue, not the sync queue: what it does is put
/// photos somewhere safe, and "sync" reads as two-way.
class BackupQueueScreen extends StatefulWidget {
  const BackupQueueScreen({
    super.key,
    required this.queue,
    required this.settingsStore,
    this.syncEverything,
    this.onOpenAsset,
  });

  final SyncQueue queue;

  /// Where the last-synced time lives.
  final BackupTargetsStore settingsStore;

  /// What Sync Now does. Absent, the button is there and dead rather than
  /// missing.
  final Future<int> Function()? syncEverything;

  /// A row tap: the queue names photos, and the obvious question about a
  /// failed row is "which photo is that?".
  final Future<void> Function(String localId)? onOpenAsset;

  @override
  State<BackupQueueScreen> createState() => _BackupQueueScreenState();
}

class _Groups {
  const _Groups(this.attention, this.upNext, this.done);

  final List<SyncJob> attention;
  final List<SyncJob> upNext;
  final List<SyncJob> done;

  bool get isEmpty => attention.isEmpty && upNext.isEmpty && done.isEmpty;

  /// One pass per change of the list, never per build: the queue can hold
  /// thousands of rows.
  factory _Groups.of(List<SyncJob> jobs) {
    final attention = <SyncJob>[];
    final running = <SyncJob>[];
    final waiting = <SyncJob>[];
    final done = <SyncJob>[];
    for (final job in jobs) {
      switch (job.status) {
        case SyncJobStatus.failed:
          attention.add(job);
        case SyncJobStatus.running:
          running.add(job);
        case SyncJobStatus.pending:
          waiting.add(job);
        case SyncJobStatus.done:
          done.add(job);
      }
    }
    return _Groups(attention, [...running, ...waiting], done);
  }
}

class _BackupQueueScreenState extends State<BackupQueueScreen> {
  static const _page = 50;

  DateTime? _lastSyncAt;
  bool _syncing = false;

  List<SyncJob>? _grouped;
  _Groups _groups = const _Groups([], [], []);
  int _attentionShown = _page;
  int _upNextShown = _page;
  int _doneShown = _page;

  @override
  void initState() {
    super.initState();
    widget.queue.refresh();
    _loadLastSync();
  }

  Future<void> _loadLastSync() async {
    try {
      final at = await widget.settingsStore.getLastSyncAt();
      if (mounted) setState(() => _lastSyncAt = at);
    } catch (_) {
      // Secure storage unavailable — the line reads "never synced".
    }
  }

  String _kindLabel(AppLocalizations l10n, SyncJobKind kind) => switch (kind) {
    SyncJobKind.checkChanges => l10n.backupQueueKindCheck,
    SyncJobKind.uploadOriginal => l10n.backupQueueKindOriginal,
    SyncJobKind.uploadThumbnail => l10n.backupQueueKindThumbnail,
    SyncJobKind.uploadLivePhoto => l10n.backupQueueKindLivePhoto,
    SyncJobKind.analyzePhoto => l10n.backupQueueKindAnalyze,
  };

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
    await _loadLastSync();
    await widget.queue.refresh();
  }

  Future<void> _retryAll() async {
    for (final job in _groups.attention) {
      await widget.queue.retry(job);
    }
  }

  Future<void> _openMenu() async {
    final l10n = AppLocalizations.of(context)!;
    await showCupertinoModalPopup<void>(
      context: context,
      builder: (sheetContext) => CupertinoActionSheet(
        title: Text(l10n.queueMenuTitle),
        actions: [
          CupertinoActionSheetAction(
            onPressed: () {},
            child: ValueListenableBuilder<int>(
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
          ),
          if (widget.syncEverything != null)
            CupertinoActionSheetAction(
              onPressed: () {
                Navigator.of(sheetContext).pop();
                _syncNow();
              },
              child: Text(l10n.settingsSyncNowButton),
            ),
          CupertinoActionSheetAction(
            onPressed: () {
              Navigator.of(sheetContext).pop();
              widget.queue.clearSynced();
            },
            child: Text(l10n.backupQueueClearSynced),
          ),
          CupertinoActionSheetAction(
            isDestructiveAction: true,
            onPressed: () {
              Navigator.of(sheetContext).pop();
              widget.queue.clearQueue();
            },
            child: Text(l10n.backupQueueClearButton),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(sheetContext).pop(),
          child: Text(l10n.actionCancel),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return CupertinoPageScaffold(
      backgroundColor: settingsPageBackground,
      navigationBar: CupertinoNavigationBar(
        backgroundColor: settingsPageBackground,
        border: null,
        middle: Text(l10n.queueTitle),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ValueListenableBuilder<bool>(
              valueListenable: widget.queue.paused,
              builder: (context, paused, _) => CupertinoButton(
                padding: EdgeInsets.zero,
                minimumSize: const Size(36, 36),
                onPressed: () => widget.queue.setPaused(!paused),
                child: Icon(
                  paused ? CupertinoIcons.play_fill : CupertinoIcons.pause_fill,
                  size: 20,
                ),
              ),
            ),
            CupertinoButton(
              padding: EdgeInsets.zero,
              minimumSize: const Size(36, 36),
              onPressed: _openMenu,
              child: const Icon(CupertinoIcons.ellipsis_circle, size: 22),
            ),
          ],
        ),
      ),
      child: SafeArea(
        child: ValueListenableBuilder<List<SyncJob>>(
          valueListenable: widget.queue.jobs,
          builder: (context, jobs, _) {
            if (!identical(jobs, _grouped)) {
              _grouped = jobs;
              _groups = _Groups.of(jobs);
            }
            return ValueListenableBuilder<bool>(
              valueListenable: widget.queue.paused,
              builder: (context, paused, _) => ValueListenableBuilder<bool>(
                valueListenable: widget.queue.draining,
                builder: (context, draining, _) =>
                    _body(l10n, paused: paused, draining: draining),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _body(
    AppLocalizations l10n, {
    required bool paused,
    required bool draining,
  }) {
    final groups = _groups;
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 20),
            child: _summary(l10n, paused: paused, draining: draining),
          ),
        ),
        ..._section(
          l10n,
          heading: l10n.queueAttention,
          jobs: groups.attention,
          shown: _attentionShown,
          onMore: () => setState(() => _attentionShown += _page),
          action: l10n.queueRetryAll,
          onAction: _retryAll,
        ),
        ..._section(
          l10n,
          heading: l10n.queueUpNext,
          jobs: groups.upNext,
          shown: _upNextShown,
          onMore: () => setState(() => _upNextShown += _page),
        ),
        ..._section(
          l10n,
          heading: l10n.queueDone,
          jobs: groups.done,
          shown: _doneShown,
          onMore: () => setState(() => _doneShown += _page),
          action: l10n.backupQueueClearSyncedShort,
          onAction: widget.queue.clearSynced,
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 32)),
      ],
    );
  }

  Widget _summary(
    AppLocalizations l10n, {
    required bool paused,
    required bool draining,
  }) {
    final groups = _groups;
    final empty = groups.isEmpty;
    final speed = widget.queue.concurrency.value;
    final atCapacity =
        groups.attention.length + groups.upNext.length >= SyncQueue.capacity;
    final title = paused
        ? l10n.backupQueuePausedNote
        : draining
        ? l10n.queueBacking
        : empty
        ? l10n.backupQueueEmpty
        : l10n.backupQueueIdle;
    final color = paused || groups.attention.isNotEmpty
        ? CupertinoColors.systemOrange
        : empty
        ? CupertinoColors.systemGreen
        : settingsAccent;
    final syncLabel = _syncing
        ? l10n.settingsSyncingMessage
        : l10n.settingsSyncNowButton;
    return SettingsStatusCard(
      color: color,
      busy: draining && !paused,
      title: title,
      subtitle: empty
          ? null
          : l10n.queueCountsLine(
              groups.upNext
                  .where((j) => j.status == SyncJobStatus.pending)
                  .length,
              groups.attention.length,
              speed,
            ),
      footnote: atCapacity
          ? l10n.queueFullNote
          : _lastSyncAt == null
          ? l10n.settingsLastSyncedNever
          : l10n.settingsLastSyncedAt(
              DateFormat.MMMd().add_jm().format(_lastSyncAt!),
            ),
      primaryLabel: draining || paused ? null : syncLabel,
      onPrimary: widget.syncEverything == null || _syncing ? null : _syncNow,
    );
  }

  List<Widget> _section(
    AppLocalizations l10n, {
    required String heading,
    required List<SyncJob> jobs,
    required int shown,
    required VoidCallback onMore,
    String? action,
    VoidCallback? onAction,
  }) {
    if (jobs.isEmpty) return const [];
    final visible = jobs.length < shown ? jobs.length : shown;
    final more = jobs.length - visible;
    final rows = visible + (more > 0 ? 1 : 0);
    return [
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            settingsPagePadding + 16,
            0,
            settingsPagePadding + 4,
            6,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '${heading.toUpperCase()} · ${jobs.length}',
                  style: settingsSubheadingStyle,
                ),
              ),
              if (action != null)
                CupertinoButton(
                  padding: EdgeInsets.zero,
                  minimumSize: Size.zero,
                  onPressed: onAction,
                  child: Text(action, style: const TextStyle(fontSize: 13)),
                ),
            ],
          ),
        ),
      ),
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(
          settingsPagePadding,
          0,
          settingsPagePadding,
          24,
        ),
        sliver: SliverList.builder(
          itemCount: rows,
          itemBuilder: (context, i) => _CardRow(
            first: i == 0,
            last: i == rows - 1,
            child: i < visible
                ? _JobRow(
                    job: jobs[i],
                    kindLabel: _kindLabel(l10n, jobs[i].kind),
                    onRetry: () => widget.queue.retry(jobs[i]),
                    onOpen: widget.onOpenAsset == null
                        ? null
                        : () => widget.onOpenAsset!(jobs[i].localId),
                  )
                : GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: onMore,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: settingsPagePadding,
                        vertical: 14,
                      ),
                      child: Text(
                        l10n.queueShowMore(more),
                        style: const TextStyle(
                          fontSize: 15,
                          color: settingsAccent,
                        ),
                      ),
                    ),
                  ),
          ),
        ),
      ),
    ];
  }
}

/// One row of a lazily built, card-shaped list: the fill, the rounded ends
/// and the hairline are the row's own, since a sliver list can't sit inside
/// a single clipped card.
class _CardRow extends StatelessWidget {
  const _CardRow({
    required this.first,
    required this.last,
    required this.child,
  });

  final bool first;
  final bool last;
  final Widget child;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: settingsControlFill,
      borderRadius: BorderRadius.vertical(
        top: first ? const Radius.circular(12) : Radius.zero,
        bottom: last ? const Radius.circular(12) : Radius.zero,
      ),
    ),
    child: Column(
      children: [
        if (!first) const SettingsHairline(indent: settingsPagePadding),
        child,
      ],
    ),
  );
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
