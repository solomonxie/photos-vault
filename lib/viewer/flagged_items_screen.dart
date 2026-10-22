import 'dart:async';
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../photos/album_suggestions.dart';
import '../photos/fix_queue.dart';
import '../photos/flag_scan.dart';
import '../photos/storage_advice.dart';
import '../settings/backup_targets_store.dart';
import '../settings/settings_section.dart';
import '../storage/album_store.dart';
import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import 'album_suggestions_screen.dart';
import 'flagged_action_screen.dart';
import 'flagged_copy.dart';
import 'library_index.dart';

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
    this.scan,
    this.onOpenAsset,
    this.albumStore,
  });

  /// Null leaves album suggestions off.
  final AlbumStore? albumStore;

  final AssetRecordStore store;
  final BackupTargetsStore targetsStore;
  final StorageAdvisor advisor;
  final FixQueue queue;

  /// The library screen's, so a scan outlives the page; one of its own
  /// when none is given.
  final FlagScan? scan;
  final Future<void> Function(String localId)? onOpenAsset;

  /// Simulator screenshots only: opens the first action once it is known.
  static bool demoOpenAction = false;

  /// How often an open page asks whether anything it lists has moved.
  static Duration pollEvery = const Duration(seconds: 5);

  @override
  State<FlaggedItemsScreen> createState() => _FlaggedItemsScreenState();
}

class _FlaggedItemsScreenState extends State<FlaggedItemsScreen> {
  FixQueue get _queue => widget.queue;

  late final FlagScan _scan =
      widget.scan ??
      FlagScan(
        store: widget.store,
        targetsStore: widget.targetsStore,
        advisor: widget.advisor,
        queue: widget.queue,
      );

  // Derived once per change, not per build — the list can be the library.
  int _problemCount = 0;
  int _saving = 0;
  int _lost = 0;
  int _backingUp = 0;
  Map<FlagSolution, List<Flag>> _phone = const {};
  Map<FlagSolution, List<Flag>> _inBucket = const {};

  /// Per action: what it saves, how long it should take, and how many
  /// failed last time, worked out with the groups rather than per build.
  Map<FlagSolution, (int, Duration, int)> _totals = const {};

  Timer? _poll;
  bool _wasRunning = false;

  @override
  void initState() {
    super.initState();
    _queue.addListener(_onQueue);
    _scan.addListener(_deriveSoon);
    _wasRunning = _queue.running;
    _compute();
    unawaited(_loadSuggestions());
    unawaited(_scan.open());
    _poll = Timer.periodic(
      FlaggedItemsScreen.pollEvery,
      (_) => unawaited(_scan.refreshIfChanged()),
    );
  }

  @override
  void dispose() {
    _poll?.cancel();
    _deriveTimer?.cancel();
    _queue.removeListener(_onQueue);
    _scan.removeListener(_deriveSoon);
    if (widget.scan == null) _scan.dispose();
    super.dispose();
  }

  /// A run ending is what changed the library: scanned again then, so a
  /// follow-on item (a copy to finish) shows without a Rescan.
  void _onQueue() {
    final running = _queue.running;
    if (_wasRunning && !running) unawaited(_scan.run());
    _wasRunning = running;
    _deriveSoon();
  }

  Timer? _deriveTimer;
  bool _derivePending = false;

  /// The queue says something per item: regrouped at once, then at most
  /// every 100 ms while it keeps talking, every 400 ms under a run (each
  /// regroup is a pass over every flag, which can be the library).
  void _deriveSoon() {
    if (_deriveTimer?.isActive ?? false) {
      _derivePending = true;
      return;
    }
    _derive();
    final gap = _queue.running
        ? const Duration(milliseconds: 400)
        : const Duration(milliseconds: 100);
    _deriveTimer = Timer(gap, () {
      if (!_derivePending) return;
      _derivePending = false;
      _deriveSoon();
    });
  }

  void _rescan() {
    unawaited(_scan.run(relist: true, restart: true));
    unawaited(_loadSuggestions());
  }

  List<AlbumSuggestion> _suggestions = const [];

  Future<void> _loadSuggestions() async {
    final albums = widget.albumStore;
    if (albums == null) return;
    final all = await widget.store.listAll();
    final filed = {
      for (final ids in (await albums.allMemberships()).values) ...ids,
    };
    final raw = await widget.store.getAppState(AlbumSuggestions.dismissedKey);
    final dismissed = raw == null
        ? const <String>{}
        : (jsonDecode(raw) as List<dynamic>).cast<String>().toSet();
    final found = AlbumSuggestions.of(
      LibraryIndex.forList(all).home,
      filed,
      dismissed: dismissed,
    );
    if (mounted) setState(() => _suggestions = found);
  }

  Future<void> _openSuggestions() async {
    await Navigator.of(context).push(
      CupertinoPageRoute<void>(
        builder: (_) => AlbumSuggestionsScreen(
          suggestions: _suggestions,
          assetRecordStore: widget.store,
          albumStore: widget.albumStore!,
        ),
      ),
    );
    await _loadSuggestions();
  }

  List<Widget> _suggestionsSection(AppLocalizations l10n) => [
    Padding(
      padding: const EdgeInsets.only(top: 24, bottom: 6, left: 4),
      child: Text(
        l10n.albumSuggestionsGroup.toUpperCase(),
        style: settingsHintStyle,
      ),
    ),
    Container(
      decoration: BoxDecoration(
        color: settingsControlFill,
        borderRadius: BorderRadius.circular(12),
      ),
      child: _ActionRow(
        key: const ValueKey('flagged-album-suggestions'),
        icon: CupertinoIcons.rectangle_stack_badge_plus,
        title: l10n.albumSuggestionsTitle,
        body: l10n.albumSuggestionsHow(AlbumSuggestions.perDay),
        amount: l10n.albumSuggestionsAmount(
          _suggestions.length,
          _suggestions.fold(0, (n, s) => n + s.records.length),
        ),
        onTap: _openSuggestions,
      ),
    ),
  ];

  // ---------------------------------------------------------------- derive

  static bool _uploading(AssetRecord? r) =>
      switch (r?.stateOf(DerivativeKind.original).status) {
        UploadStatus.pending || UploadStatus.uploading => true,
        _ => false,
      };

  static bool _isOptimize(Flag f) =>
      f.storage != null &&
      f.solutions.any(
        (s) => s == FlagSolution.optimize || s == FlagSolution.optimizeRemote,
      );

  void _derive() {
    if (!mounted) return;
    setState(_compute);
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

  void _compute() {
    final live = [
      for (final f in _scan.result.flags)
        if (!_queue.isResolved(f)) f,
    ];
    // While photos are still uploading, each one landing would add an
    // Optimize: they're held back and offered together once backup is done,
    // so one pass clears the list. A failed upload doesn't hold them.
    final backingUp = [
      for (final f in live)
        if (f.solutions.contains(FlagSolution.backUp) &&
            _uploading(f.storage?.record))
          f,
    ].length;
    // One waiting for its backup has nothing to do here but wait: the
    // queue's row covers it.
    final problems = [
      for (final f in live)
        if (f.solutions.any(
              (s) => s != FlagSolution.backUp && s != FlagSolution.ignore,
            ) &&
            !(backingUp > 0 && _isOptimize(f)))
          f,
    ];
    final groups = _groupsOf(problems);
    final totals = {
      for (final MapEntry(key: s, value: flags) in groups.entries)
        s: (
          flags.fold(0, (sum, f) => sum + f.saving),
          _queue.estimate(s, flags),
          flags.where((f) => _queue.failedBefore(f.id)).length,
        ),
    };
    _backingUp = backingUp;
    _totals = totals;
    _problemCount = problems.length;
    _saving = problems.fold(0, (sum, f) => sum + f.saving);
    _lost = problems
        .where((f) => f.problems.contains(FlagProblem.missingFromBucket))
        .length;
    _phone = {
      for (final e in groups.entries)
        if (!e.key.inBucket) e.key: e.value,
    };
    _inBucket = {
      for (final e in groups.entries)
        if (e.key.inBucket) e.key: e.value,
    };
  }

  /// What the one-time repair listed, ordinary photos only: a hidden one
  /// is shown inside its album, never here.
  List<Widget> _reviewSection(AppLocalizations l10n) => [
    Padding(
      padding: const EdgeInsets.only(top: 24, bottom: 6, left: 4),
      child: Text(
        l10n.flaggedGroupReview.toUpperCase(),
        style: settingsHintStyle,
      ),
    ),
    Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Text(l10n.flaggedReviewNote, style: settingsHintStyle),
    ),
    Container(
      decoration: BoxDecoration(
        color: settingsControlFill,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          for (final item in _scan.result.review)
            _ActionRow(
              key: ValueKey('flagged-review-${item.localId}'),
              icon: CupertinoIcons.info,
              title: l10n.flaggedCarrierStemTitle,
              body: l10n.flaggedCarrierStemBody,
              amount: '',
              onTap: () => widget.onOpenAsset?.call(item.localId),
            ),
        ],
      ),
    ),
  ];

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

  bool get _loading => _scan.running;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final review = _scan.result.review;
    final nothing =
        _phone.isEmpty &&
        _inBucket.isEmpty &&
        review.isEmpty &&
        _suggestions.isEmpty &&
        !_loading;
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
            if (review.isNotEmpty) ..._reviewSection(l10n),
            if (_suggestions.isNotEmpty) ..._suggestionsSection(l10n),
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
        _loading && _problemCount == 0 && _scan.result.stamp == null
            ? l10n.flaggedLooking
            : l10n.flaggedHeading(_problemCount),
        style: settingsHeadingStyle,
      ),
      if (_scan.storageRunning && _scan.toScan > 0)
        Text(
          l10n.storageScanning(_scan.scanned, _scan.toScan),
          style: settingsHintStyle,
        ),
      if (_lost > 0)
        Text(
          l10n.cloudStatusLost(_lost),
          style: const TextStyle(
            fontSize: 13,
            color: CupertinoColors.systemRed,
          ),
        ),
      if (_backingUp > 0)
        Text(l10n.flaggedWaitingBackup(_backingUp), style: settingsHintStyle),
      if (_saving > 0) ...[
        const SizedBox(height: 4),
        Text(
          l10n.flaggedFreesUpTo(formatBytes(_saving)),
          style: settingsFooterStyle,
        ),
      ],
      if (_scan.result.storageScannedAt case final at?)
        Text(
          l10n.storageScannedAt(DateFormat.yMMMd().add_jm().format(at)),
          style: settingsHintStyle,
        ),
      if (_queue.swapsWaiting > 0 && !_queue.running) _swapsBanner(l10n),
      AnimatedSize(
        duration: _collapse,
        alignment: Alignment.topCenter,
        child: _queue.total > 0 ? _runCard(l10n) : const SizedBox.shrink(),
      ),
    ],
  );

  /// Originals filed by a run and not yet asked about: iOS's delete sheet
  /// comes from here, where the page says what it is for.
  Widget _swapsBanner(AppLocalizations l10n) => Container(
    key: const ValueKey('flagged-swaps'),
    margin: const EdgeInsets.only(top: 12),
    padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
    decoration: BoxDecoration(
      color: settingsControlFill,
      borderRadius: BorderRadius.circular(12),
    ),
    child: Row(
      children: [
        Expanded(
          child: Text(
            l10n.flaggedSwapsWaiting(_queue.swapsWaiting),
            style: settingsRowSubtitleStyle,
          ),
        ),
        CupertinoButton(
          key: const ValueKey('flagged-swaps-finish'),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          minimumSize: const Size(0, 30),
          onPressed: _queue.finishPending,
          child: Text(
            l10n.flaggedSwapsFinish,
            style: const TextStyle(fontSize: 14),
          ),
        ),
      ],
    ),
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
              warning: _failedIn(AppLocalizations.of(context)!, s),
              onTap: () => _openAction(s, flags),
            ),
          ],
        ],
      ),
    ),
  ];

  String _amount(AppLocalizations l10n, FlagSolution s, List<Flag> flags) {
    final (saving, eta, _) = _totals[s] ?? (0, Duration.zero, 0);
    return [
      l10n.flaggedItemCount(flags.length),
      if (saving > 0) l10n.flaggedSavesAbout(formatBytes(saving)),
      etaLabel(l10n, eta),
    ].join(' · ');
  }

  String? _failedIn(AppLocalizations l10n, FlagSolution s) {
    final failed = _totals[s]?.$3 ?? 0;
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
