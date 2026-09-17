import 'package:flutter/cupertino.dart';

import '../l10n/app_localizations.dart';
import '../settings/settings_section.dart';
import '../upload/sync_job.dart';
import '../upload/sync_queue.dart';

/// Opens the queue over whatever is on screen. A transient status list is
/// not a destination — it's something you glance at and dismiss, so it gets
/// a sheet rather than a page of its own.
/// [onOpenAsset] is what a row tap does: the queue names photos, and the
/// obvious question about a row — especially a failed one — is "which photo
/// is that?". Absent, rows aren't tappable rather than tappable and inert.
Future<void> showSyncQueueSheet(
  BuildContext context,
  SyncQueue queue, {
  Future<void> Function(String localId)? onOpenAsset,
}) {
  return showCupertinoModalPopup<void>(
    context: context,
    builder: (context) =>
        SyncQueueSheet(queue: queue, onOpenAsset: onOpenAsset),
  );
}

/// The real queue: every unit of sync work, one row each — uploads,
/// thumbnails, and the change checks that re-hash a file to spot an edit.
/// Pause, speed, and clearing act on the same list right below them.
class SyncQueueSheet extends StatefulWidget {
  const SyncQueueSheet({super.key, required this.queue, this.onOpenAsset});

  final SyncQueue queue;

  /// See [showSyncQueueSheet].
  final Future<void> Function(String localId)? onOpenAsset;

  @override
  State<SyncQueueSheet> createState() => _SyncQueueSheetState();
}

class _SyncQueueSheetState extends State<SyncQueueSheet> {
  @override
  void initState() {
    super.initState();
    widget.queue.refresh();
  }

  String _kindLabel(AppLocalizations l10n, SyncJobKind kind) => switch (kind) {
    SyncJobKind.checkChanges => l10n.backupQueueKindCheck,
    SyncJobKind.uploadOriginal => l10n.backupQueueKindOriginal,
    SyncJobKind.uploadThumbnail => l10n.backupQueueKindThumbnail,
    SyncJobKind.analyzePhoto => l10n.backupQueueKindAnalyze,
  };

  Future<void> _showActions() async {
    final l10n = AppLocalizations.of(context)!;
    await showCupertinoModalPopup<void>(
      context: context,
      builder: (sheetContext) => CupertinoActionSheet(
        title: Text(l10n.backupQueueSpeed(widget.queue.concurrency.value)),
        actions: [
          CupertinoActionSheetAction(
            onPressed: () {
              widget.queue.setConcurrency(widget.queue.concurrency.value - 1);
              Navigator.of(sheetContext).pop();
            },
            child: Text(l10n.backupQueueSlower),
          ),
          CupertinoActionSheetAction(
            onPressed: () {
              widget.queue.setConcurrency(widget.queue.concurrency.value + 1);
              Navigator.of(sheetContext).pop();
            },
            child: Text(l10n.backupQueueFaster),
          ),
          CupertinoActionSheetAction(
            onPressed: () {
              widget.queue.clearSynced();
              Navigator.of(sheetContext).pop();
            },
            child: Text(l10n.backupQueueClearSynced),
          ),
          CupertinoActionSheetAction(
            isDestructiveAction: true,
            onPressed: () {
              widget.queue.clearQueue();
              Navigator.of(sheetContext).pop();
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

  /// How far down the finger has to go, from the top of the list, for the
  /// sheet to close. Short: this is a sheet, not a page, and the gesture
  /// that opens a sheet is the one that closes it.
  static const _dismissPullDistance = 44.0;

  Offset? _pullOrigin;
  bool _dismissed = false;

  /// True only when the list can't scroll up any further — a drag from
  /// halfway down the queue is someone reading it, not someone leaving.
  bool get _atTop => !_scroll.hasClients || _scroll.position.pixels <= 0;

  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _onPointerDown(PointerDownEvent event) =>
      _pullOrigin = _atTop ? event.position : null;

  void _onPointerMove(PointerMoveEvent event) {
    final origin = _pullOrigin;
    if (origin == null || _dismissed || !_atTop) return;
    final moved = event.position - origin;
    if (moved.dy < _dismissPullDistance || moved.dy <= moved.dx.abs()) return;
    _dismissed = true;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Listener(
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: (_) => _pullOrigin = null,
      onPointerCancel: (_) => _pullOrigin = null,
      child: _sheet(context, l10n),
    );
  }

  Widget _sheet(BuildContext context, AppLocalizations l10n) {
    return Container(
      height: MediaQuery.of(context).size.height * 0.7,
      decoration: const BoxDecoration(
        color: Color(0xFF2C2C2E),
        borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            const _DragHandle(),
            _header(l10n),
            const SettingsHairline(),
            Expanded(
              child: ValueListenableBuilder<List<SyncJob>>(
                valueListenable: widget.queue.jobs,
                builder: (context, jobs, _) {
                  if (jobs.isEmpty) {
                    return Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          l10n.backupQueueEmpty,
                          textAlign: TextAlign.center,
                          style: settingsFooterStyle,
                        ),
                      ),
                    );
                  }
                  return ListView.separated(
                    controller: _scroll,
                    itemCount: jobs.length,
                    separatorBuilder: (_, _) =>
                        const SettingsHairline(indent: settingsPagePadding),
                    itemBuilder: (context, i) => _JobRow(
                      job: jobs[i],
                      kindLabel: _kindLabel(l10n, jobs[i].kind),
                      onRetry: () => widget.queue.retry(jobs[i]),
                      onOpen: widget.onOpenAsset == null
                          ? null
                          : () async {
                              // Out of the way first: the viewer is a page,
                              // and leaving a sheet over it would trap it.
                              Navigator.of(context).pop();
                              await widget.onOpenAsset!(jobs[i].localId);
                            },
                    ),
                  );
                },
              ),
            ),
          ],
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

  Widget _header(AppLocalizations l10n) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(settingsPagePadding, 0, 8, 8),
      child: Row(
        children: [
          Expanded(
            child: ValueListenableBuilder<List<SyncJob>>(
              valueListenable: widget.queue.jobs,
              builder: (context, jobs, _) => ValueListenableBuilder<bool>(
                valueListenable: widget.queue.paused,
                builder: (context, paused, _) => Row(
                  children: [
                    Text(
                      l10n.backupQueueHeader(jobs.length),
                      style: settingsRowTitleStyle,
                    ),
                    // Why nothing new is going in. A queue that quietly
                    // refuses work looks identical to one with nothing
                    // to do.
                    if (paused || _atCapacity(jobs)) ...[
                      const SizedBox(width: 6),
                      Text(
                        paused
                            ? l10n.backupQueuePausedNote
                            : l10n.backupQueueFullNote,
                        style: settingsRowSubtitleStyle,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          // A pause/play icon, not a toggle labelled with a state — a
          // "Paused" switch leaves nobody sure which way means running.
          ValueListenableBuilder<bool>(
            valueListenable: widget.queue.paused,
            builder: (context, paused, _) => CupertinoButton(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: Size.zero,
              onPressed: () => widget.queue.setPaused(!paused),
              child: Icon(
                paused ? CupertinoIcons.play_fill : CupertinoIcons.pause_fill,
                size: 20,
                color: settingsAccent,
              ),
            ),
          ),
          CupertinoButton(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            minimumSize: Size.zero,
            onPressed: _showActions,
            child: const Icon(
              CupertinoIcons.ellipsis_circle,
              size: 20,
              color: settingsAccent,
            ),
          ),
        ],
      ),
    );
  }
}

class _DragHandle extends StatelessWidget {
  const _DragHandle();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 36,
      height: 5,
      margin: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: settingsTertiary,
        borderRadius: BorderRadius.circular(3),
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

  /// Opens the photo this row is about — see [showSyncQueueSheet].
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
            size: 20,
          ),
        );
    }
  }
}
