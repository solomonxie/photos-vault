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
      padding: const EdgeInsets.fromLTRB(settingsPagePadding, 0, 12, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ValueListenableBuilder<List<SyncJob>>(
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
                  // refuses work looks identical to one with nothing to do.
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
          const SizedBox(height: 8),
          // The controls on the page rather than behind a "…" in the far
          // corner: there were four of them, all one tap deep, and the tap
          // that opened the menu was a 20-point glyph at the top-right of a
          // sheet you hold at the bottom. Labelled, because a row of bare
          // glyphs is a quiz.
          _controls(l10n),
        ],
      ),
    );
  }

  Widget _controls(AppLocalizations l10n) {
    return ValueListenableBuilder<bool>(
      valueListenable: widget.queue.paused,
      builder: (context, paused, _) => ValueListenableBuilder<int>(
        valueListenable: widget.queue.concurrency,
        builder: (context, concurrency, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Two rows, not one that scrolls sideways: a control you have
            // to drag the row to find is a control behind a menu again.
            Row(
              children: [
                // Pause is the one that stops everything, so it reads
                // first and carries the state word.
                _QueueButton(
                  icon: paused
                      ? CupertinoIcons.play_fill
                      : CupertinoIcons.pause_fill,
                  label: paused
                      ? l10n.backupQueueResumeAction
                      : l10n.backupQueuePauseAction,
                  onPressed: () => widget.queue.setPaused(!paused),
                  prominent: true,
                ),
                _QueueButton(
                  icon: CupertinoIcons.minus,
                  label: l10n.backupQueueSlowerShort,
                  onPressed: concurrency <= 1
                      ? null
                      : () => widget.queue.setConcurrency(concurrency - 1),
                ),
                // What "slower" and "faster" are actually moving.
                Flexible(
                  child: Text(
                    l10n.backupQueueSpeed(concurrency),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: settingsRowSubtitleStyle,
                  ),
                ),
                const SizedBox(width: 8),
                _QueueButton(
                  icon: CupertinoIcons.plus,
                  label: l10n.backupQueueFasterShort,
                  onPressed: () => widget.queue.setConcurrency(concurrency + 1),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                _QueueButton(
                  icon: CupertinoIcons.checkmark_circle,
                  label: l10n.backupQueueClearSyncedShort,
                  onPressed: widget.queue.clearSynced,
                ),
                _QueueButton(
                  icon: CupertinoIcons.clear_circled,
                  label: l10n.backupQueueClearButton,
                  onPressed: widget.queue.clearQueue,
                  destructive: true,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// One control in the queue's own row: icon over label, 44 points tall, with
/// a face you can see. A tappable glyph with no background reads as
/// decoration until it's tried.
class _QueueButton extends StatelessWidget {
  const _QueueButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.prominent = false,
    this.destructive = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool prominent;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final color = onPressed == null
        ? settingsTertiary
        : destructive
        ? CupertinoColors.systemRed
        : settingsAccent;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: CupertinoButton(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        minimumSize: const Size(0, 44),
        borderRadius: BorderRadius.circular(10),
        color: prominent ? const Color(0xFF3A3A3C) : const Color(0xFF2C2C2E),
        onPressed: onPressed,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 6),
            Text(label, style: TextStyle(fontSize: 14, color: color)),
          ],
        ),
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
