import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../photos/fix_queue.dart';
import '../photos/storage_advice.dart';
import '../settings/backup_targets_store.dart';
import '../settings/settings_section.dart';
import '../storage/asset_record_store.dart';
import '../upload/bucket_flagged.dart';
import '../upload/bucket_import.dart';
import 'asset_grid.dart';

/// Everything the app wants a person to look at, as one list that drains:
/// space this phone could give back, and bucket objects the app doesn't
/// understand.
///
/// A chip per problem, a button per solution. A solution button queues
/// every listed item it applies to; a row's own button queues that one.
/// The work runs in [FixQueue], not here, so the page can be left — each
/// item drops out of the list as it is fixed, and a failure stays with its
/// reason. See `docs/design/uiux/storage.md`.
class FlaggedItemsScreen extends StatefulWidget {
  const FlaggedItemsScreen({
    super.key,
    required this.store,
    required this.targetsStore,
    required this.advisor,
    required this.queue,
    this.onOpenAsset,
  });

  final AssetRecordStore store;
  final BackupTargetsStore targetsStore;
  final StorageAdvisor advisor;
  final FixQueue queue;
  final Future<void> Function(String localId)? onOpenAsset;

  @override
  State<FlaggedItemsScreen> createState() => _FlaggedItemsScreenState();
}

class _FlaggedItemsScreenState extends State<FlaggedItemsScreen> {
  FixQueue get _queue => widget.queue;

  List<Flag> _storage = const [];
  List<Flag> _bucket = const [];
  DateTime? _scannedAt;
  bool _scanning = false;
  int _scanned = 0;
  int _toScan = 0;
  bool _loadingBucket = true;
  FlagProblem? _filter;

  /// Rows on their way out: drawn collapsing, then dropped.
  final Set<String> _leaving = {};

  // Derived once per change, not per build — the list can be the library.
  List<Flag> _all = const [];
  List<Flag> _visible = const [];
  Map<FlagProblem, int> _counts = const {};
  Map<FlagSolution, List<Flag>> _batches = const {};
  int _saving = 0;

  @override
  void initState() {
    super.initState();
    _queue.addListener(_onQueue);
    _loadStorage();
    _loadBucket();
  }

  @override
  void dispose() {
    _queue.removeListener(_onQueue);
    super.dispose();
  }

  // ---------------------------------------------------------------- loading

  Future<void> _loadStorage({bool restart = false}) async {
    if (!restart) {
      final cached = await widget.advisor.cached();
      if (!mounted) return;
      _setStorage(cached);
      if (cached.complete) return;
    }
    // On the page is the one time somebody waits for the answer, so the
    // pass runs flat out here; off it, it trickles (`StorageAdvisor.sweep`).
    setState(() => _scanning = true);
    final found = await widget.advisor.scan(
      restart: restart,
      onProgress: (items, done, total) {
        if (!mounted) return;
        _scanned = done;
        _toScan = total;
        _setStorage(StorageScan(items: items, scannedAt: _scannedAt));
      },
    );
    if (!mounted) return;
    _scanning = false;
    _setStorage(found);
  }

  void _setStorage(StorageScan scan) {
    _scannedAt = scan.scannedAt;
    _storage = [for (final item in scan.items) Flag.storage(item)];
    _derive();
  }

  Future<void> _loadBucket({bool refresh = false}) async {
    if (refresh) setState(() => _loadingBucket = true);
    final indexer = BucketIndexer(
      targetsStore: widget.targetsStore,
      recordStore: widget.store,
    );
    try {
      if (refresh || (await widget.store.listBucketObjects()).isEmpty) {
        await indexer.refresh();
      }
      final fixer = _queue.fixer;
      final objects = await BucketFlags(store: widget.store)
          .detect(inspect: fixer.inspect);
      if (!mounted) return;
      _bucket = [for (final o in objects) Flag.bucket(o)];
      _derive();
      // Re-format is offered only once the header says the file isn't a
      // hidden photo — a read per object, so it arrives after the list.
      for (final o in objects) {
        if (o.kind != FlagKind.offProtocol || o.isVideo) continue;
        if (!await fixer.canReformat(o)) continue;
        if (!mounted) return;
        final id = bucketFlagId(o.object);
        _bucket = [
          for (final f in _bucket)
            f.id == id ? Flag.bucket(o, reformatable: true) : f,
        ];
        _derive();
      }
    } catch (_) {
      // Offline: whatever the index already had stays listed.
    } finally {
      if (mounted) setState(() => _loadingBucket = false);
    }
  }

  void _rescan() {
    _loadStorage(restart: true);
    _loadBucket(refresh: true);
  }

  // ---------------------------------------------------------------- queue

  void _onQueue() {
    for (final flag in _all) {
      if (_queue.isResolved(flag) && _leaving.add(flag.id)) {
        Timer(_collapse, () {
          if (!mounted) return;
          _leaving.remove(flag.id);
          _derive();
        });
      }
    }
    _derive();
  }

  void _derive() {
    final all = [
      for (final f in [..._storage, ..._bucket])
        if (!_queue.isResolved(f) || _leaving.contains(f.id)) f,
    ];
    final counts = <FlagProblem, int>{};
    var saving = 0;
    for (final f in all) {
      for (final p in f.problems) {
        counts[p] = (counts[p] ?? 0) + 1;
      }
      saving += f.saving;
    }
    final filter = counts.containsKey(_filter) ? _filter : null;
    final visible = filter == null
        ? all
        : [
            for (final f in all)
              if (f.problems.contains(filter)) f,
          ];
    final batches = <FlagSolution, List<Flag>>{};
    for (final f in visible) {
      if (_leaving.contains(f.id)) continue;
      final job = _queue.jobs[f.id];
      if (job != null && job.state != FixJobState.failed) continue;
      for (final s in f.solutions) {
        if (f.batchable(s)) (batches[s] ??= []).add(f);
      }
    }
    setState(() {
      _all = all;
      _filter = filter;
      _visible = visible;
      _counts = counts;
      _saving = saving;
      _batches = Map.fromEntries(
        FlagSolution.values
            .where(batches.containsKey)
            .map((s) => MapEntry(s, batches[s]!)),
      );
    });
  }

  Future<void> _fix(List<Flag> flags, FlagSolution solution) async {
    if (!await _confirm(flags, solution) || !mounted) return;
    _queue.enqueue(flags, solution);
  }

  Future<bool> _confirm(List<Flag> flags, FlagSolution solution) async {
    final l10n = AppLocalizations.of(context)!;
    final body = switch (solution) {
      FlagSolution.removeFromDevice => l10n.flaggedConfirmRemoveBody,
      FlagSolution.reduceResolution ||
      FlagSolution.convertFormat => l10n.flaggedConfirmShrinkBody,
      FlagSolution.removeThumbnail => l10n.flaggedBatchRemoveBody(flags.length),
      FlagSolution.rename when flags.length > 1 => l10n.flaggedBatchRenameBody(
        flags.length,
      ),
      FlagSolution.reformat => l10n.flaggedConfirmReformatBody,
      FlagSolution.importAnyway => l10n.flaggedConfirmImportAnywayBody,
      _ => null,
    };
    if (body == null) return true;
    final label = _solutionLabel(l10n, solution);
    final go = await showCupertinoDialog<bool>(
      context: context,
      builder: (dialogContext) => CupertinoAlertDialog(
        title: Text(l10n.flaggedConfirmTitle(label, flags.length)),
        content: Text(body),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.actionCancel),
          ),
          CupertinoDialogAction(
            isDefaultAction: true,
            isDestructiveAction:
                solution == FlagSolution.removeFromDevice ||
                solution == FlagSolution.removeThumbnail,
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(label),
          ),
        ],
      ),
    );
    return go == true;
  }

  Future<void> _moreFixes(Flag flag) async {
    final l10n = AppLocalizations.of(context)!;
    final picked = await showCupertinoModalPopup<FlagSolution>(
      context: context,
      builder: (sheetContext) => CupertinoActionSheet(
        title: Text(flag.name),
        actions: [
          for (final s in flag.solutions)
            CupertinoActionSheetAction(
              isDestructiveAction: s == FlagSolution.removeThumbnail,
              onPressed: () => Navigator.of(sheetContext).pop(s),
              child: Text(_solutionLabel(l10n, s)),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(sheetContext).pop(),
          child: Text(l10n.actionCancel),
        ),
      ),
    );
    if (picked != null) await _fix([flag], picked);
  }

  // ----------------------------------------------------------------- copy

  static String _problemLabel(AppLocalizations l10n, FlagProblem p) =>
      switch (p) {
        FlagProblem.onDevice => l10n.storageIssueOnDevice,
        FlagProblem.largeFile => l10n.storageIssueLargeFile,
        FlagProblem.highResolution => l10n.storageIssueHighResolution,
        FlagProblem.optimizableFormat => l10n.storageIssueOptimizableFormat,
        FlagProblem.offProtocol => l10n.flaggedProblemOffProtocol,
        FlagProblem.orphanThumbnail => l10n.flaggedProblemOrphan,
        FlagProblem.unclaimed => l10n.flaggedProblemUnclaimed,
        FlagProblem.likelyLeftover => l10n.flaggedProblemLeftover,
      };

  static String _solutionLabel(AppLocalizations l10n, FlagSolution s) =>
      switch (s) {
        FlagSolution.backUp => l10n.storageFixBackUpFirst,
        FlagSolution.removeFromDevice => l10n.storageFixRemoveFromDevice,
        FlagSolution.reduceResolution => l10n.storageFixReduceResolution,
        FlagSolution.convertFormat => l10n.storageFixConvertFormat,
        FlagSolution.import => l10n.flaggedImport,
        FlagSolution.rename => l10n.flaggedRename,
        FlagSolution.reformat => l10n.flaggedReformat,
        FlagSolution.removeThumbnail => l10n.flaggedRemove,
        FlagSolution.ignore => l10n.flaggedIgnore,
        FlagSolution.importAnyway => l10n.flaggedImportAnyway,
      };

  static IconData _solutionIcon(FlagSolution s) => switch (s) {
    FlagSolution.backUp => CupertinoIcons.cloud_upload_fill,
    FlagSolution.removeFromDevice => CupertinoIcons.trash_fill,
    FlagSolution.reduceResolution =>
      CupertinoIcons.arrow_down_right_arrow_up_left,
    FlagSolution.convertFormat ||
    FlagSolution.reformat => CupertinoIcons.arrow_2_squarepath,
    FlagSolution.import ||
    FlagSolution.importAnyway => CupertinoIcons.tray_arrow_down_fill,
    FlagSolution.rename => CupertinoIcons.pencil,
    FlagSolution.removeThumbnail => CupertinoIcons.delete_solid,
    FlagSolution.ignore => CupertinoIcons.eye_slash_fill,
  };

  /// A storage row's tags explain its size; a bucket row needs the
  /// sentence, since "Likely old copy" alone doesn't say why.
  String _reason(AppLocalizations l10n, Flag flag) {
    final bucket = flag.bucket;
    if (bucket == null) {
      return [for (final p in flag.problems) _problemLabel(l10n, p)]
          .join(' · ');
    }
    if (bucket.likelyDuplicateOf case final key?) {
      return l10n.flaggedLikelyDuplicate(key.split('/').last);
    }
    return switch (bucket.kind) {
      FlagKind.offProtocol => l10n.flaggedOffProtocolReason,
      FlagKind.orphanThumbnail => l10n.flaggedOrphanReason,
      FlagKind.unclaimed => l10n.flaggedUnclaimedReason,
      FlagKind.likelyLeftover => l10n.flaggedLeftoverReason,
    };
  }

  String? _failureNote(AppLocalizations l10n, FixJob? job) {
    if (job == null || job.state != FixJobState.failed) return null;
    return switch (job.failure) {
      FixFailure.needsAlbum => l10n.flaggedNeedsAlbum,
      FixFailure.unverified => l10n.flaggedUnverified,
      _ =>
        job.detail == null
            ? l10n.flaggedFailed
            : '${l10n.flaggedFailed} (${job.detail})',
    };
  }

  // ---------------------------------------------------------------- build

  static const _collapse = Duration(milliseconds: 280);

  bool get _loading => _scanning || _loadingBucket;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return CupertinoPageScaffold(
      backgroundColor: settingsPageBackground,
      navigationBar: CupertinoNavigationBar(
        backgroundColor: settingsPageBackground,
        middle: Text(l10n.flaggedTitle),
        trailing: _loading
            ? const CupertinoActivityIndicator(radius: 8)
            : SettingsAccentButton(
                label: l10n.flaggedRescan,
                onPressed: _rescan,
              ),
      ),
      child: SafeArea(
        child: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(child: _header(l10n)),
            if (_visible.isEmpty && !_loading)
              SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text(
                      l10n.flaggedNone,
                      textAlign: TextAlign.center,
                      style: settingsHintStyle,
                    ),
                  ),
                ),
              ),
            SliverList.builder(
              itemCount: _visible.length,
              itemBuilder: (context, index) => _row(l10n, _visible[index]),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 32)),
          ],
        ),
      ),
    );
  }

  Widget _header(AppLocalizations l10n) {
    final count = _all.length - _leaving.length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(settingsPagePadding, 12, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _scanning && _toScan > 0
                ? l10n.storageScanning(_scanned, _toScan)
                : _loading && count == 0
                ? l10n.flaggedLooking
                : l10n.flaggedHeading(count),
            style: settingsHeadingStyle,
          ),
          if (_saving > 0) ...[
            const SizedBox(height: 4),
            Text(
              l10n.flaggedFreesUpTo(formatBytes(_saving)),
              style: settingsFooterStyle,
            ),
          ],
          if (_scannedAt != null)
            Text(
              l10n.storageScannedAt(
                DateFormat.yMMMd().add_jm().format(_scannedAt!),
              ),
              style: settingsHintStyle,
            ),
          AnimatedSize(
            duration: _collapse,
            alignment: Alignment.topCenter,
            child: _queue.total > 0 ? _runCard(l10n) : const SizedBox.shrink(),
          ),
          const SizedBox(height: 12),
          if (_counts.isNotEmpty) _chips(l10n),
          if (_batches.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final (i, MapEntry(key: s, value: flags))
                    in _batches.entries.indexed)
                  _SolutionButton(
                    icon: _solutionIcon(s),
                    label: '${_solutionLabel(l10n, s)} · ${flags.length}',
                    filled: i == 0,
                    onPressed: () => _fix(flags, s),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _chips(AppLocalizations l10n) => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    child: Row(
      children: [
        _FilterChip(
          label: l10n.storageFilterAll,
          count: _all.length - _leaving.length,
          selected: _filter == null,
          onTap: () {
            _filter = null;
            _derive();
          },
        ),
        for (final p in FlagProblem.values)
          if (_counts[p] case final count?)
            _FilterChip(
              label: _problemLabel(l10n, p),
              count: count,
              selected: _filter == p,
              onTap: () {
                _filter = p;
                _derive();
              },
            ),
      ],
    ),
  );

  Widget _runCard(AppLocalizations l10n) {
    final q = _queue;
    final progress = q.total == 0 ? 0.0 : q.done / q.total;
    final finished = q.finished;
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.fromLTRB(12, 10, 4, 12),
      decoration: BoxDecoration(
        color: settingsControlFill,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (finished)
                Icon(
                  q.failed > 0
                      ? CupertinoIcons.exclamationmark_circle_fill
                      : CupertinoIcons.checkmark_circle_fill,
                  size: 18,
                  color: q.failed > 0
                      ? CupertinoColors.systemOrange
                      : CupertinoColors.systemGreen,
                )
              else
                const CupertinoActivityIndicator(radius: 8),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  finished
                      ? l10n.flaggedRunDone
                      : l10n.flaggedBatchProgress(q.done, q.total),
                  style: settingsRowTitleStyle,
                ),
              ),
              CupertinoButton(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                minimumSize: const Size(0, 30),
                onPressed: finished
                    ? q.dismiss
                    : q.stopping
                    ? null
                    : q.stop,
                child: Text(
                  finished ? l10n.actionOk : l10n.flaggedBatchStop,
                  style: const TextStyle(fontSize: 14),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: _ProgressBar(value: progress),
          ),
          const SizedBox(height: 6),
          Text(
            [
              if (finished && q.freedBytes > 0)
                l10n.storageResultFreed(formatBytes(q.freedBytes)),
              if (finished && q.failed > 0) l10n.flaggedBatchLeft(q.failed),
              if (!finished) l10n.flaggedRunHint,
            ].join(' '),
            style: settingsHintStyle,
          ),
        ],
      ),
    );
  }

  Widget _row(AppLocalizations l10n, Flag flag) {
    final job = _queue.jobs[flag.id];
    final storage = flag.storage;
    return _Collapsing(
      key: ValueKey(flag.id),
      gone: _leaving.contains(flag.id),
      duration: _collapse,
      child: _FlagRow(
        thumbnail: storage != null
            ? assetImage(
                storage.record,
                thumbnailSize: 200,
                placeholder: () => const _IconTile(CupertinoIcons.photo),
              )
            : _IconTile(
                flag.bucket!.isVideo ? CupertinoIcons.film : CupertinoIcons.doc,
              ),
        title: flag.name,
        subtitle:
            '${formatBytes(flag.bytes)} · ${DateFormat.yMMMd().format(flag.date)}',
        tags: _reason(l10n, flag),
        note: _failureNote(l10n, job),
        onTap: storage == null || widget.onOpenAsset == null
            ? null
            : () => widget.onOpenAsset!(storage.record.localId),
        trailing: switch (job?.state) {
          FixJobState.running => const CupertinoActivityIndicator(radius: 9),
          FixJobState.waiting => Text(
            l10n.flaggedWaiting,
            style: settingsRowSubtitleStyle,
          ),
          FixJobState.failed => _RowButton(
            label: l10n.flaggedRetry,
            onPressed: () => _fix([flag], job!.solution),
          ),
          null => Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _RowButton(
                label: _solutionLabel(l10n, flag.solutions.first),
                onPressed: () => _fix([flag], flag.solutions.first),
              ),
              if (flag.solutions.length > 1)
                CupertinoButton(
                  padding: const EdgeInsets.only(left: 6),
                  minimumSize: const Size(28, 30),
                  onPressed: () => _moreFixes(flag),
                  child: const Icon(
                    CupertinoIcons.ellipsis_circle,
                    size: 22,
                    color: settingsAccent,
                  ),
                ),
            ],
          ),
        },
      ),
    );
  }
}

class _FlagRow extends StatelessWidget {
  const _FlagRow({
    required this.thumbnail,
    required this.title,
    required this.subtitle,
    required this.tags,
    required this.trailing,
    this.note,
    this.onTap,
  });

  final Widget thumbnail;
  final String title;
  final String subtitle;
  final String tags;
  final Widget trailing;
  final String? note;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(settingsPagePadding, 8, 12, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(width: 48, height: 48, child: thumbnail),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: settingsRowTitleStyle,
                  ),
                  const SizedBox(height: 2),
                  Text(subtitle, style: settingsRowSubtitleStyle),
                  if (tags.isNotEmpty)
                    Text(
                      tags,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 11,
                        color: settingsTertiary,
                      ),
                    ),
                  if (note != null) ...[
                    const SizedBox(height: 2),
                    Text(note!, style: settingsErrorStyle),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              height: 48,
              child: Align(alignment: Alignment.centerRight, child: trailing),
            ),
          ],
        ),
      ),
    );
  }
}

/// A row leaving the list: folds to nothing rather than vanishing, so the
/// eye sees the list drain instead of jump.
class _Collapsing extends StatefulWidget {
  const _Collapsing({
    super.key,
    required this.gone,
    required this.duration,
    required this.child,
  });

  final bool gone;
  final Duration duration;
  final Widget child;

  @override
  State<_Collapsing> createState() => _CollapsingState();
}

class _CollapsingState extends State<_Collapsing>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
    value: widget.gone ? 0 : 1,
  );
  late final Animation<double> _curve = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeInOut,
  );

  @override
  void didUpdateWidget(_Collapsing old) {
    super.didUpdateWidget(old);
    if (widget.gone && !old.gone) _controller.reverse();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizeTransition(
    sizeFactor: _curve,
    alignment: Alignment.topCenter,
    child: FadeTransition(opacity: _curve, child: widget.child),
  );
}

class _ProgressBar extends StatelessWidget {
  const _ProgressBar({required this.value});

  final double value;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(2),
    child: SizedBox(
      height: 4,
      child: Stack(
        children: [
          const Positioned.fill(child: ColoredBox(color: settingsSeparator)),
          TweenAnimationBuilder<double>(
            tween: Tween(end: value.clamp(0, 1)),
            duration: const Duration(milliseconds: 250),
            builder: (context, v, _) => FractionallySizedBox(
              widthFactor: v,
              child: const ColoredBox(color: settingsAccent),
            ),
          ),
        ],
      ),
    ),
  );
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

class _RowButton extends StatelessWidget {
  const _RowButton({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => CupertinoButton(
    padding: const EdgeInsets.symmetric(horizontal: 12),
    minimumSize: const Size(0, 30),
    borderRadius: BorderRadius.circular(15),
    color: settingsControlFill,
    onPressed: onPressed,
    child: Text(
      label,
      style: const TextStyle(fontSize: 13, color: settingsAccent),
    ),
  );
}

/// One solution for every listed item it applies to. The first is filled:
/// the one most of the list is waiting for.
class _SolutionButton extends StatelessWidget {
  const _SolutionButton({
    required this.icon,
    required this.label,
    required this.filled,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final bool filled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final color = filled ? CupertinoColors.white : settingsAccent;
    return CupertinoButton(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      minimumSize: const Size(0, 34),
      borderRadius: BorderRadius.circular(17),
      color: filled ? settingsAccent : settingsControlFill,
      onPressed: onPressed,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
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
        margin: const EdgeInsets.only(right: 8),
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
