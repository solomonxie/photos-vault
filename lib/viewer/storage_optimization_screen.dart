import 'package:flutter/cupertino.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../photos/storage_advice.dart';
import '../photos/storage_optimizer.dart';
import '../settings/settings_section.dart';
import 'asset_grid.dart';

/// Where the space went, and what can be done about each bit of it.
///
/// One filter chip per kind of problem, then the photos themselves —
/// biggest win first — each carrying the one fix that suits it. "Select"
/// turns the list into checkboxes so a hundred of them go at once; every
/// item still applies its *own* fix, so a mixed selection does the right
/// thing per photo rather than the same blunt thing to all of them.
class StorageOptimizationScreen extends StatefulWidget {
  const StorageOptimizationScreen({
    super.key,
    required this.advisor,
    required this.optimizer,
    this.onOpenAsset,
  });

  final StorageAdvisor advisor;
  final StorageOptimizer optimizer;

  /// A card's obvious question is "which photo is that?" — absent, cards
  /// are simply not tappable rather than tappable and inert.
  final Future<void> Function(String localId)? onOpenAsset;

  @override
  State<StorageOptimizationScreen> createState() =>
      _StorageOptimizationScreenState();
}

class _StorageOptimizationScreenState extends State<StorageOptimizationScreen> {
  StorageScan _scan = const StorageScan();
  StorageIssue? _filter;
  bool _scanning = false;
  int _scanned = 0;
  int _toScan = 0;
  bool _selecting = false;
  final Set<String> _selected = {};
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// Last time's findings, straight onto the screen. Walking the library
  /// is a channel call per photo; doing it on every visit would make an
  /// answer the app already had cost ten seconds to see again.
  ///
  /// Then, if the pass never reached the end — a first run, or photos
  /// added since — it carries on from where it stopped. Being *on* the
  /// page is the one time the user is waiting for the answer, so it runs
  /// flat out here; off the page it trickles (`StorageAdvisor.sweep`).
  Future<void> _load() async {
    final cached = await widget.advisor.cached();
    if (!mounted) return;
    setState(() => _scan = cached);
    if (!cached.complete) await _scanOn();
  }

  /// [restart] throws away what's been measured and walks the library
  /// again — the Rescan button. Without it this resumes.
  Future<void> _scanOn({bool restart = false}) async {
    if (_scanning) return;
    setState(() {
      _scanning = true;
      _scanned = _scan.measured.length;
      _toScan = 0;
    });
    final found = await widget.advisor.scan(
      restart: restart,
      onProgress: (items, done, total) {
        if (!mounted) return;
        setState(() {
          _scan = StorageScan(
            items: items,
            scannedAt: _scan.scannedAt,
            measured: _scan.measured,
          );
          _scanned = done;
          _toScan = total;
        });
      },
    );
    if (!mounted) return;
    setState(() {
      _scan = found;
      _scanning = false;
      _dropStaleSelection();
    });
  }

  void _dropStaleSelection() {
    final live = {for (final item in _scan.items) item.record.localId};
    _selected.removeWhere((id) => !live.contains(id));
  }

  List<StorageItem> get _items => _scan.items;

  List<StorageItem> get _visible => _filter == null
      ? _items
      : _items.where((item) => item.issues.contains(_filter)).toList();

  List<StorageItem> get _selection =>
      _items.where((item) => _selected.contains(item.record.localId)).toList();

  int _countOf(StorageIssue issue) =>
      _items.where((item) => item.issues.contains(issue)).length;

  /// What applying every fix would give back. "Up to", because the two
  /// re-encodes can't know what the encoder will produce until it runs.
  int _savingOf(List<StorageItem> items) =>
      items.fold(0, (sum, item) => sum + item.estimatedSaving);

  /// What the listed items take up right now. The other half of the
  /// answer: "free up to 6 GB" means nothing without "out of 8".
  int _sizeOf(List<StorageItem> items) =>
      items.fold(0, (sum, item) => sum + item.bytes);

  // ------------------------------------------------------------- applying

  Future<void> _apply(List<StorageItem> items) async {
    if (items.isEmpty || _busy) return;
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showCupertinoDialog<bool>(
      context: context,
      builder: (dialogContext) => CupertinoAlertDialog(
        title: Text(l10n.storageConfirmTitle(items.length)),
        content: Text(l10n.storageConfirmBody),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.actionCancel),
          ),
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.storageOptimizeAction),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _busy = true);
    final result = await widget.optimizer.apply(items);
    // Only what was touched is measured again — the rest of the library
    // is exactly as the last scan left it.
    final next = await widget.advisor.remeasure(_scan, {
      for (final item in items) item.record.localId,
    });
    if (!mounted) return;
    setState(() {
      _scan = next;
      _busy = false;
      _selecting = false;
      _selected.clear();
    });
    _report(result);
  }

  void _report(StorageFixResult result) {
    final l10n = AppLocalizations.of(context)!;
    final lines = [
      if (result.freedBytes > 0)
        l10n.storageResultFreed(formatBytes(result.freedBytes)),
      if (result.queuedForBackup > 0)
        l10n.storageResultQueued(result.queuedForBackup),
      if (result.skipped > 0) l10n.storageResultSkipped(result.skipped),
    ];
    showCupertinoDialog<void>(
      context: context,
      builder: (dialogContext) => CupertinoAlertDialog(
        content: Text(
          lines.isEmpty ? l10n.storageResultNothing : lines.join('\n'),
        ),
        actions: [
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l10n.actionOk),
          ),
        ],
      ),
    );
  }

  void _toggle(StorageItem item) {
    setState(() {
      if (!_selected.add(item.record.localId)) {
        _selected.remove(item.record.localId);
      }
    });
  }

  void _toggleSelectAll() {
    final visible = _visible;
    final all = visible.every(
      (item) => _selected.contains(item.record.localId),
    );
    setState(() {
      for (final item in visible) {
        if (all) {
          _selected.remove(item.record.localId);
        } else {
          _selected.add(item.record.localId);
        }
      }
    });
  }

  // ----------------------------------------------------------------- copy

  String _issueLabel(AppLocalizations l10n, StorageIssue issue) =>
      switch (issue) {
        StorageIssue.onDevice => l10n.storageIssueOnDevice,
        StorageIssue.largeFile => l10n.storageIssueLargeFile,
        StorageIssue.highResolution => l10n.storageIssueHighResolution,
        StorageIssue.optimizableFormat => l10n.storageIssueOptimizableFormat,
      };

  String _fixLabel(AppLocalizations l10n, StorageFix fix) => switch (fix) {
    StorageFix.backUpFirst => l10n.storageFixBackUpFirst,
    StorageFix.removeFromDevice => l10n.storageFixRemoveFromDevice,
    StorageFix.reduceResolution => l10n.storageFixReduceResolution,
    StorageFix.convertFormat => l10n.storageFixConvertFormat,
  };

  static IconData _fixIcon(StorageFix fix) => switch (fix) {
    StorageFix.backUpFirst => CupertinoIcons.cloud_upload_fill,
    StorageFix.removeFromDevice => CupertinoIcons.trash_fill,
    StorageFix.reduceResolution =>
      CupertinoIcons.arrow_down_right_arrow_up_left,
    StorageFix.convertFormat => CupertinoIcons.arrow_2_squarepath,
  };

  String _subtitleOf(StorageItem item) {
    final parts = [
      DateFormat.yMMMd().format(item.record.createdAt),
      formatBytes(item.bytes),
      if (item.record.width case final width?)
        if (item.record.height case final height?) '$width × $height',
    ];
    return parts.join(' · ');
  }

  // ---------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final visible = _visible;
    return CupertinoPageScaffold(
      backgroundColor: settingsPageBackground,
      navigationBar: CupertinoNavigationBar(
        backgroundColor: settingsPageBackground,
        middle: Text(l10n.storageTitle),
        trailing: _trailing(l10n),
      ),
      child: Stack(
        children: [
          SafeArea(
            child: CustomScrollView(
              slivers: [
                SliverToBoxAdapter(child: _header(l10n)),
                if (visible.isEmpty && !_scanning)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Center(
                        child: Text(
                          l10n.storageEmpty,
                          textAlign: TextAlign.center,
                          style: settingsHintStyle,
                        ),
                      ),
                    ),
                  ),
                SliverList.builder(
                  itemCount: visible.length,
                  itemBuilder: (context, index) {
                    final item = visible[index];
                    return _ItemCard(
                      item: item,
                      subtitle: _subtitleOf(item),
                      tags: [
                        for (final issue in StorageIssue.values)
                          if (item.issues.contains(issue))
                            _issueLabel(l10n, issue),
                      ],
                      fixLabel: _fixLabel(l10n, item.fix),
                      fixIcon: _fixIcon(item.fix),
                      selecting: _selecting,
                      selected: _selected.contains(item.record.localId),
                      onTap: _selecting
                          ? () => _toggle(item)
                          : widget.onOpenAsset == null
                          ? null
                          : () => widget.onOpenAsset!(item.record.localId),
                      onLongPress: _selecting
                          ? null
                          : () => setState(() {
                              _selecting = true;
                              _selected.add(item.record.localId);
                            }),
                      onFix: () => _apply([item]),
                    );
                  },
                ),
                SliverToBoxAdapter(
                  child: SizedBox(height: _selecting ? 132 : 32),
                ),
              ],
            ),
          ),
          if (_selecting) _selectionBar(l10n),
          if (_busy)
            const ColoredBox(
              color: Color(0x99000000),
              child: Center(child: CupertinoActivityIndicator(radius: 14)),
            ),
        ],
      ),
    );
  }

  Widget? _trailing(AppLocalizations l10n) {
    if (_scanning) return const CupertinoActivityIndicator(radius: 8);
    if (_items.isEmpty) return null;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_selecting)
          SettingsAccentButton(
            label: l10n.storageSelectAll,
            onPressed: _toggleSelectAll,
          ),
        SettingsAccentButton(
          label: _selecting ? l10n.selectionDone : l10n.storageSelect,
          onPressed: () => setState(() {
            _selecting = !_selecting;
            if (!_selecting) _selected.clear();
          }),
        ),
      ],
    );
  }

  Widget _header(AppLocalizations l10n) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(settingsPagePadding, 12, 12, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _scanning
                ? l10n.storageScanning(_scanned, _toScan)
                : l10n.storageSummary(formatBytes(_savingOf(_items))),
            style: settingsHeadingStyle,
          ),
          const SizedBox(height: 4),
          if (!_scanning)
            Text(
              l10n.storageSummaryDetail(
                _items.length,
                formatBytes(_sizeOf(_items)),
              ),
              style: settingsHintStyle,
            ),
          Text(l10n.storageHint, style: settingsHintStyle),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: Text(
                  _scan.scannedAt == null
                      ? l10n.storageNeverScanned
                      : l10n.storageScannedAt(
                          DateFormat.yMMMd().add_jm().format(_scan.scannedAt!),
                        ),
                  style: settingsFooterStyle,
                ),
              ),
              SettingsPillButton(
                icon: CupertinoIcons.arrow_clockwise,
                label: l10n.storageRescan,
                onPressed: _scanning ? null : () => _scanOn(restart: true),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _FilterChip(
                label: l10n.storageFilterAll,
                count: _items.length,
                selected: _filter == null,
                onTap: () => setState(() => _filter = null),
              ),
              for (final issue in StorageIssue.values)
                if (_countOf(issue) > 0)
                  _FilterChip(
                    label: _issueLabel(l10n, issue),
                    count: _countOf(issue),
                    selected: _filter == issue,
                    onTap: () => setState(() => _filter = issue),
                  ),
            ],
          ),
          const SizedBox(height: 4),
        ],
      ),
    );
  }

  Widget _selectionBar(AppLocalizations l10n) {
    final selection = _selection;
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Container(
        decoration: const BoxDecoration(
          color: Color(0xFF2C2C2E),
          border: Border(top: BorderSide(color: settingsSeparator, width: 0.5)),
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(settingsPagePadding, 10, 12, 10),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    l10n.storageSelected(
                      selection.length,
                      formatBytes(_savingOf(selection)),
                    ),
                    style: settingsFooterStyle,
                  ),
                ),
                CupertinoButton(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 6,
                  ),
                  minimumSize: const Size(0, 36),
                  borderRadius: BorderRadius.circular(18),
                  color: settingsAccent,
                  onPressed: selection.isEmpty ? null : () => _apply(selection),
                  child: Text(
                    l10n.storageFixSelected,
                    style: const TextStyle(fontSize: 14),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: settingsControlFill,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: selected ? settingsAccent : settingsSeparator,
            width: selected ? 1.5 : 0.5,
          ),
        ),
        child: Text(
          '$label $count',
          style: TextStyle(
            fontSize: 13,
            color: selected ? settingsAccent : CupertinoColors.white,
          ),
        ),
      ),
    );
  }
}

class _ItemCard extends StatelessWidget {
  const _ItemCard({
    required this.item,
    required this.subtitle,
    required this.tags,
    required this.fixLabel,
    required this.fixIcon,
    required this.selecting,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
    required this.onFix,
  });

  final StorageItem item;
  final String subtitle;
  final List<String> tags;
  final String fixLabel;
  final IconData fixIcon;
  final bool selecting;
  final bool selected;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final VoidCallback onFix;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        margin: const EdgeInsets.fromLTRB(settingsPagePadding, 6, 16, 6),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFF2C2C2E),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? settingsAccent : const Color(0x00000000),
            width: 1.5,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: SizedBox(
                    width: 52,
                    height: 52,
                    child: assetImage(
                      item.record,
                      thumbnailSize: 200,
                      placeholder: () => const ColoredBox(
                        color: settingsPageBackground,
                        child: Icon(
                          CupertinoIcons.photo,
                          size: 18,
                          color: settingsTertiary,
                        ),
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
                        item.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: settingsRowTitleStyle,
                      ),
                      const SizedBox(height: 3),
                      Text(subtitle, style: settingsRowSubtitleStyle),
                    ],
                  ),
                ),
                if (selecting) ...[
                  const SizedBox(width: 8),
                  Icon(
                    selected
                        ? CupertinoIcons.checkmark_circle_fill
                        : CupertinoIcons.circle,
                    size: 22,
                    color: selected ? settingsAccent : settingsTertiary,
                  ),
                ],
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [for (final tag in tags) _Tag(label: tag)],
            ),
            if (!selecting) ...[
              const SizedBox(height: 10),
              // A filled pill, sized to its words and sitting at the end
              // of the card: an action you press, not an empty box the
              // width of the row.
              Align(
                alignment: Alignment.centerRight,
                child: CupertinoButton(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  minimumSize: const Size(0, 32),
                  borderRadius: BorderRadius.circular(16),
                  color: settingsAccent,
                  onPressed: onFix,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(fixIcon, size: 14, color: CupertinoColors.white),
                      const SizedBox(width: 6),
                      Text(
                        fixLabel,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: CupertinoColors.white,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: settingsPageBackground,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        label,
        style: const TextStyle(fontSize: 11, color: settingsSecondary),
      ),
    );
  }
}
