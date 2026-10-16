import 'package:flutter/cupertino.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../photos/fix_queue.dart';
import '../photos/storage_advice.dart' show formatBytes;
import '../settings/settings_section.dart';
import 'asset_grid.dart';
import 'flagged_copy.dart';

/// One action and everything it applies to. All selected to start with,
/// except an action that replaces bucket originals: each of those is
/// ticked by hand. Then one button does the rest. What
/// is done drops out; what fails stays, saying why, ready to try again.
class FlaggedActionScreen extends StatefulWidget {
  const FlaggedActionScreen({
    super.key,
    required this.solution,
    required this.flags,
    required this.queue,
    this.onOpenAsset,
  });

  final FlagSolution solution;
  final List<Flag> flags;
  final FixQueue queue;
  final Future<void> Function(String localId)? onOpenAsset;

  @override
  State<FlaggedActionScreen> createState() => _FlaggedActionScreenState();
}

class _FlaggedActionScreenState extends State<FlaggedActionScreen> {
  FixQueue get _queue => widget.queue;
  late List<Flag> _flags = _open();
  late Set<String> _selected = solutionReplacesOriginal(widget.solution)
      ? {}
      : {for (final f in _flags) f.id};

  List<Flag> _open() => [
    for (final f in widget.flags)
      if (!_queue.isResolved(f)) f,
  ];

  @override
  void initState() {
    super.initState();
    _queue.addListener(_onQueue);
  }

  @override
  void dispose() {
    _queue.removeListener(_onQueue);
    super.dispose();
  }

  bool _closing = false;

  /// Each row's own time, worked out once per queue change, not per build.
  final Map<String, Duration> _eta = {};

  Duration _etaOf(Flag flag) =>
      _eta[flag.id] ??= _queue.estimate(widget.solution, [flag]);

  void _onQueue() {
    if (_closing) return;
    _eta.clear();
    final open = _open();
    setState(() {
      _flags = open;
      _selected = _selected.intersection({for (final f in open) f.id});
    });
  }

  /// Nothing left: closes once, and only while on top — a second pop would
  /// close the page underneath too. With a photo open over it, this runs
  /// again when the page is back on top.
  void _closeIfDone() {
    if (_closing || _flags.isNotEmpty) return;
    if (!(ModalRoute.of(context)?.isCurrent ?? false)) return;
    _closing = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop();
    });
  }

  bool _busy(Flag f) {
    final state = _queue.jobs[f.id]?.state;
    return state == FixJobState.waiting || state == FixJobState.running;
  }

  List<Flag> get _chosen => [
    for (final f in _flags)
      if (_selected.contains(f.id) && !_busy(f)) f,
  ];

  Future<void> _run() async {
    final chosen = _chosen;
    if (chosen.isEmpty) return;
    if (solutionIsPermanent(widget.solution) && !await _confirm(chosen)) {
      return;
    }
    _queue.enqueue(chosen, widget.solution);
  }

  Future<bool> _confirm(List<Flag> chosen) async {
    final l10n = AppLocalizations.of(context)!;
    final label = solutionLabel(l10n, widget.solution);
    final go = await showCupertinoDialog<bool>(
      context: context,
      builder: (dialogContext) => CupertinoAlertDialog(
        title: Text(l10n.flaggedConfirmTitle(label, chosen.length)),
        content: Text(permanentNote(l10n, widget.solution, chosen)),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.actionCancel),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(label),
          ),
        ],
      ),
    );
    return go == true;
  }

  Future<void> _hide() async {
    final chosen = _chosen;
    if (chosen.isNotEmpty) await _queue.keep(chosen);
  }

  @override
  Widget build(BuildContext context) {
    _closeIfDone();
    final l10n = AppLocalizations.of(context)!;
    final label = solutionLabel(l10n, widget.solution);
    final allSelected = _selected.length == _flags.length;
    final chosen = _chosen;
    final detail = solutionDetail(l10n, widget.solution);
    return CupertinoPageScaffold(
      backgroundColor: settingsPageBackground,
      navigationBar: CupertinoNavigationBar(
        backgroundColor: settingsPageBackground,
        middle: Text(label),
        trailing: SettingsAccentButton(
          label: allSelected ? l10n.flaggedSelectNone : l10n.flaggedSelectAll,
          onPressed: () => setState(
            () => _selected = allSelected ? {} : {for (final f in _flags) f.id},
          ),
        ),
      ),
      child: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: CustomScrollView(
                slivers: [
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(
                        settingsPagePadding,
                        12,
                        settingsPagePadding,
                        12,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // The fuller wording where there is one; never both.
                          Text(
                            detail ?? solutionHow(l10n, widget.solution),
                            style: const TextStyle(
                              fontSize: 15,
                              height: 1.35,
                              color: settingsSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  SliverList.builder(
                    itemCount: _flags.length,
                    itemBuilder: (context, i) => _row(l10n, _flags[i]),
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
              decoration: const BoxDecoration(
                border: Border(
                  top: BorderSide(color: settingsSeparator, width: 0.5),
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (chosen.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        key: const ValueKey('flagged-run-summary'),
                        [
                          if (chosen.fold(0, (sum, f) => sum + f.saving)
                              case final saving when saving > 0)
                            l10n.flaggedSavesAbout(formatBytes(saving)),
                          etaLabel(
                            l10n,
                            _queue.estimate(widget.solution, chosen),
                          ),
                        ].join(' · '),
                        style: settingsHintStyle,
                      ),
                    ),
                  Row(
                    children: [
                      CupertinoButton(
                        key: const ValueKey('flagged-hide'),
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        onPressed: chosen.isEmpty ? null : _hide,
                        child: Text(
                          l10n.flaggedIgnore,
                          style: const TextStyle(fontSize: 15),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: CupertinoButton.filled(
                          key: const ValueKey('flagged-run'),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          onPressed: chosen.isEmpty ? null : _run,
                          child: Text(
                            '$label · ${chosen.length}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(AppLocalizations l10n, Flag flag) {
    final job = _queue.jobs[flag.id];
    final record = flag.record;
    final selected = _selected.contains(flag.id);
    final note = failureNote(l10n, job);
    final reason = flagReason(l10n, flag);
    final open = widget.onOpenAsset;
    return GestureDetector(
      key: ValueKey(flag.id),
      behavior: HitTestBehavior.opaque,
      onTap: _busy(flag)
          ? null
          : () => setState(() {
              if (!_selected.remove(flag.id)) _selected.add(flag.id);
            }),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(settingsPagePadding, 8, 16, 8),
        child: Row(
          children: [
            SizedBox(
              width: 28,
              child: switch (job?.state) {
                FixJobState.running => const CupertinoActivityIndicator(
                  radius: 9,
                ),
                FixJobState.waiting => const Icon(
                  CupertinoIcons.clock,
                  size: 20,
                  color: settingsTertiary,
                ),
                _ => Icon(
                  selected
                      ? CupertinoIcons.checkmark_circle_fill
                      : CupertinoIcons.circle,
                  size: 22,
                  color: selected ? settingsAccent : settingsTertiary,
                ),
              },
            ),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: record == null || open == null
                  ? null
                  : () => open(record.localId),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 52,
                  height: 52,
                  child: record != null
                      ? assetImage(
                          record,
                          thumbnailSize: 200,
                          placeholder: () =>
                              const _IconTile(CupertinoIcons.photo),
                        )
                      : _IconTile(
                          flag.bucket!.isVideo
                              ? CupertinoIcons.film
                              : CupertinoIcons.doc,
                        ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    flag.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: settingsRowTitleStyle,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    [
                      if (flag.bytes > 0) formatBytes(flag.bytes),
                      DateFormat.yMMMd().format(flag.date),
                      // Only when it isn't simply the whole file.
                      if (flag.saving > 0 && flag.saving < flag.bytes)
                        l10n.flaggedSavesAbout(formatBytes(flag.saving)),
                      // A row's own time only once it is worth a glance.
                      if (_etaOf(flag) case final eta when eta.inSeconds >= 60)
                        etaLabel(l10n, eta),
                    ].join(' · '),
                    style: settingsRowSubtitleStyle,
                  ),
                  if (reason.isNotEmpty)
                    Text(
                      reason,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        color: settingsTertiary,
                      ),
                    ),
                  if (note != null) ...[
                    const SizedBox(height: 2),
                    Text(note, style: settingsErrorStyle),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _IconTile extends StatelessWidget {
  const _IconTile(this.icon);

  final IconData icon;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: settingsControlFill,
    child: Icon(icon, size: 20, color: settingsTertiary),
  );
}
