import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../photos/fix_queue.dart';
import '../photos/storage_advice.dart';
import '../settings/backup_targets_store.dart';
import '../settings/settings_section.dart';
import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import '../upload/bucket_flagged.dart';
import '../upload/bucket_import.dart';
import '../upload/lost_originals.dart';
import 'flagged_action_screen.dart';
import 'flagged_copy.dart';

/// What can be done about this phone's space and the bucket's odd files,
/// as a list of actions rather than a list of files: each says what it
/// will do, to how many, and what it saves, and opens onto the items it
/// would touch. Grouped by where it acts: this iPhone, the bucket. Never
/// offers to delete a local copy — what to keep on the phone is the
/// person's call.
///
/// The work runs in [FixQueue], not here, so the page can be left. See
/// `docs/design/uiux/storage.md`.
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

  /// Simulator screenshots only: opens the first action once it is known.
  static bool demoOpenAction = false;

  @override
  State<FlaggedItemsScreen> createState() => _FlaggedItemsScreenState();
}

class _FlaggedItemsScreenState extends State<FlaggedItemsScreen> {
  FixQueue get _queue => widget.queue;

  List<Flag> _storage = const [];
  List<Flag> _bucket = const [];

  /// Exact copies of another photo here. A copy's own size or format
  /// flag gives way to this: it is going, not being shrunk.
  List<Flag> _duplicates = const [];

  /// Cloud-only photos whose bucket copy could be smaller.
  List<Flag> _cloudOnly = const [];
  DateTime? _scannedAt;
  bool _scanning = false;
  int _scanned = 0;
  int _toScan = 0;
  bool _loadingBucket = true;

  // Derived once per change, not per build — the list can be the library.
  int _problemCount = 0;
  int _saving = 0;
  Map<FlagSolution, List<Flag>> _phone = const {};
  Map<FlagSolution, List<Flag>> _inBucket = const {};

  /// Per action: what it saves and how long it should take, worked out
  /// with the groups rather than on every build.
  Map<FlagSolution, (int, Duration)> _totals = const {};

  @override
  void initState() {
    super.initState();
    _queue.addListener(_derive);
    _loadStorage();
    _loadDuplicates();
    _loadLost();
    _loadBucket();
  }

  /// Photos the bucket turned out not to have — said under the heading,
  /// the one place left that says so.
  int _lost = 0;

  Future<void> _loadLost() async {
    try {
      final lost = {...await LostOriginals(widget.store).current()};
      // Also cloud-only photos whose every known copy is in a bucket no
      // longer set up: nothing here can download them.
      final listed = {
        for (final o in await widget.store.listBucketObjects()) o.key,
      };
      if (listed.isNotEmpty) {
        final holdings = await widget.store.allHoldings();
        for (final r in await widget.store.listAll()) {
          if (!r.localDeleted || r.isDeleted || r.passcodeHash != null) {
            continue;
          }
          final keys = {
            ?r.stateOf(DerivativeKind.original).destinationKey,
            ...?holdings[r.localId]?[DerivativeKind.original]?.values,
          };
          if (keys.isNotEmpty && !keys.any(listed.contains)) {
            lost.add(r.localId);
          }
        }
      }
      if (mounted) setState(() => _lost = lost.length);
    } catch (_) {
      // Unreadable: said nothing rather than something wrong.
    }
  }

  Future<void> _loadDuplicates() async {
    final found = await widget.advisor.duplicates();
    final cloudOnly = await widget.advisor.cloudOnly();
    if (!mounted) return;
    _duplicates = [for (final item in found) Flag.storage(item)];
    _cloudOnly = [for (final item in cloudOnly) Flag.storage(item)];
    _derive();
  }

  @override
  void dispose() {
    _queue.removeListener(_derive);
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
    final fixer = _queue.fixer;
    try {
      if (refresh || (await widget.store.listBucketObjects()).isEmpty) {
        await indexer.refresh();
      } else {
        await indexer.forgetRemovedBuckets();
      }
      final objects = await BucketFlags(store: widget.store)
          .detect(inspect: fixer.inspect, etag: fixer.etagOf);
      if (!mounted) return;
      _bucket = [for (final o in objects) Flag.bucket(o)];
      _loadingBucket = false;
      _derive();
      // Re-format is offered only once the header says the file isn't a
      // hidden photo — a read per object, so it arrives after the list,
      // a few at a time, and the page doesn't wait on it.
      final candidates = [
        for (final o in objects)
          if (o.kind == FlagKind.offProtocol && !o.isVideo) o,
      ];
      for (var i = 0; i < candidates.length; i += 8) {
        final chunk = candidates.skip(i).take(8).toList();
        final ok = await Future.wait(chunk.map(fixer.canReformat));
        if (!mounted) return;
        final yes = {
          for (final (j, o) in chunk.indexed)
            if (ok[j]) bucketFlagId(o.object): o,
        };
        if (yes.isEmpty) continue;
        _bucket = [
          for (final f in _bucket)
            if (yes[f.id] case final o?)
              Flag.bucket(o, reformatable: true)
            else
              f,
        ];
        _derive();
      }
    } catch (_) {
      // Offline: whatever the index already had stays listed.
    } finally {
      // Saved even when the page was left mid-way: what was read stays read.
      await fixer.saveLooks();
      if (mounted) setState(() => _loadingBucket = false);
    }
  }

  void _rescan() {
    _loadStorage(restart: true);
    _loadDuplicates();
    _loadBucket(refresh: true);
  }

  // ---------------------------------------------------------------- derive

  void _derive() {
    if (!mounted) return;
    final copies = {for (final f in _duplicates) f.id};
    final live = [
      for (final f in [
        ..._duplicates,
        ..._storage.where((f) => !copies.contains(f.id)),
        ..._cloudOnly,
        ..._bucket,
      ])
        if (!_queue.isResolved(f)) f,
    ];
    // One waiting for its backup has nothing to do here but wait: the
    // queue's row covers it.
    final problems = [
      for (final f in live)
        if (f.solutions.any(
          (s) => s != FlagSolution.backUp && s != FlagSolution.ignore,
        ))
          f,
    ];
    final groups = _groupsOf(problems);
    final totals = {
      for (final MapEntry(key: s, value: flags) in groups.entries)
        s: (
          flags.fold(0, (sum, f) => sum + f.saving),
          _queue.estimate(s, flags),
        ),
    };
    setState(() {
      _totals = totals;
      _problemCount = problems.length;
      _saving = problems.fold(0, (sum, f) => sum + f.saving);
      _phone = {
        for (final e in groups.entries)
          if (!e.key.inBucket) e.key: e.value,
      };
      _inBucket = {
        for (final e in groups.entries)
          if (e.key.inBucket) e.key: e.value,
      };
    });
    if (FlaggedItemsScreen.demoOpenAction) {
      final first = [..._phone.entries, ..._inBucket.entries];
      if (first.isNotEmpty) {
        FlaggedItemsScreen.demoOpenAction = false;
        Timer(const Duration(seconds: 2), () {
          if (mounted) _openAction(first.first.key, first.first.value);
        });
      }
    }
  }

  /// Every action and the items it applies to. An item with two possible
  /// fixes is under both; doing either takes it out of the other.
  static Map<FlagSolution, List<Flag>> _groupsOf(List<Flag> flags) {
    final groups = <FlagSolution, List<Flag>>{};
    for (final f in flags) {
      for (final s in f.solutions) {
        // Hiding is on every action's own page, not an action of its own;
        // backing up is the queue's row.
        if (s == FlagSolution.ignore || s == FlagSolution.backUp) continue;
        (groups[s] ??= []).add(f);
      }
    }
    return Map.fromEntries(
      FlagSolution.values
          .where(groups.containsKey)
          .map((s) => MapEntry(s, groups[s]!)),
    );
  }

  Future<void> _openAction(FlagSolution solution, List<Flag> flags) =>
      Navigator.of(context).push(
        CupertinoPageRoute<void>(
          builder: (_) => FlaggedActionScreen(
            solution: solution,
            flags: flags,
            queue: _queue,
            onOpenAsset: widget.onOpenAsset,
          ),
        ),
      );

  // ---------------------------------------------------------------- build

  static const _collapse = Duration(milliseconds: 280);

  bool get _loading => _scanning || _loadingBucket;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final nothing = _phone.isEmpty && _inBucket.isEmpty && !_loading;
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
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            settingsPagePadding,
            12,
            settingsPagePadding,
            32,
          ),
          children: [
            _header(l10n),
            if (_phone.isNotEmpty)
              ..._section(l10n.flaggedGroupPhone, null, _phone),
            if (_inBucket.isNotEmpty)
              ..._section(l10n.flaggedGroupBucket, null, _inBucket),
            if (nothing)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 48),
                child: Text(
                  l10n.flaggedNone,
                  textAlign: TextAlign.center,
                  style: settingsHintStyle,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _header(AppLocalizations l10n) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      // What the last scan found stays the heading; a pass over photos
      // added since is a line under it, not a page that looks rescanned.
      Text(
        _loading && _problemCount == 0 && _scannedAt == null
            ? l10n.flaggedLooking
            : l10n.flaggedHeading(_problemCount),
        style: settingsHeadingStyle,
      ),
      if (_scanning && _toScan > 0)
        Text(l10n.storageScanning(_scanned, _toScan), style: settingsHintStyle),
      if (_lost > 0)
        Text(
          l10n.cloudStatusLost(_lost),
          style: const TextStyle(
            fontSize: 13,
            color: CupertinoColors.systemRed,
          ),
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
    ],
  );

  List<Widget> _section(
    String title,
    String? body,
    Map<FlagSolution, List<Flag>> actions,
  ) => [
    Padding(
      padding: const EdgeInsets.only(top: 24, bottom: 6, left: 4),
      child: Text(title.toUpperCase(), style: settingsHintStyle),
    ),
    if (body != null)
      Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 8),
        child: Text(body, style: settingsHintStyle),
      ),
    Container(
      decoration: BoxDecoration(
        color: settingsControlFill,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          for (final (i, MapEntry(key: s, value: flags))
              in actions.entries.indexed) ...[
            if (i > 0)
              Container(
                height: 0.5,
                margin: const EdgeInsets.only(left: 56),
                color: settingsSeparator,
              ),
            _ActionRow(
              key: ValueKey('flagged-action-${s.name}'),
              icon: solutionIcon(s),
              title: solutionLabel(AppLocalizations.of(context)!, s),
              body: solutionHow(AppLocalizations.of(context)!, s),
              amount: _amount(AppLocalizations.of(context)!, s, flags),
              warning: _failedIn(AppLocalizations.of(context)!, flags),
              onTap: () => _openAction(s, flags),
            ),
          ],
        ],
      ),
    ),
  ];

  String _amount(AppLocalizations l10n, FlagSolution s, List<Flag> flags) {
    final (saving, eta) = _totals[s] ?? (0, Duration.zero);
    return [
      l10n.flaggedItemCount(flags.length),
      if (saving > 0) l10n.flaggedSavesAbout(formatBytes(saving)),
      etaLabel(l10n, eta),
    ].join(' · ');
  }

  String? _failedIn(AppLocalizations l10n, List<Flag> flags) {
    final failed = flags
        .where((f) => _queue.jobs[f.id]?.state == FixJobState.failed)
        .length;
    return failed == 0 ? null : l10n.flaggedActionFailed(failed);
  }

  Widget _runCard(AppLocalizations l10n) {
    final q = _queue;
    final progress = q.total == 0 ? 0.0 : q.progressed / q.total;
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
                      : l10n.flaggedBatchProgress(q.progressed, q.total),
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
          if (!finished && q.step != null) ...[
            const SizedBox(height: 6),
            Text(
              key: const ValueKey('flagged-step'),
              [
                actionLabel(l10n, q.step!.action),
                q.step!.name,
                formatBytes(q.step!.bytes),
              ].where((part) => part.isNotEmpty).join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13, color: settingsSecondary),
            ),
          ],
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

/// One action: what it's called, what it will do, to how many.
class _ActionRow extends StatelessWidget {
  const _ActionRow({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
    required this.amount,
    required this.onTap,
    this.warning,
  });

  final IconData icon;
  final String title;
  final String body;
  final String amount;
  final VoidCallback onTap;

  /// How many of these failed last time, in orange.
  final String? warning;

  @override
  Widget build(BuildContext context) => CupertinoButton(
    padding: const EdgeInsets.fromLTRB(12, 12, 10, 12),
    minimumSize: Size.zero,
    onPressed: onTap,
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: settingsAccent.withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, size: 17, color: settingsAccent),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: CupertinoColors.white,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                body,
                style: const TextStyle(
                  fontSize: 13,
                  height: 1.3,
                  color: CupertinoColors.systemGrey,
                ),
              ),
              const SizedBox(height: 4),
              if (amount.isNotEmpty)
                Text(
                  amount,
                  style: const TextStyle(fontSize: 13, color: settingsAccent),
                ),
              if (warning != null)
                Text(
                  warning!,
                  style: const TextStyle(
                    fontSize: 13,
                    color: CupertinoColors.systemOrange,
                  ),
                ),
            ],
          ),
        ),
        const Padding(
          padding: EdgeInsets.only(top: 8, left: 6),
          child: Icon(
            CupertinoIcons.chevron_right,
            size: 15,
            color: CupertinoColors.systemGrey2,
          ),
        ),
      ],
    ),
  );
}
