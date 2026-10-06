import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../photos/storage_advice.dart';
import '../photos/storage_optimizer.dart';
import '../settings/backup_targets_store.dart';
import '../settings/settings_section.dart';
import '../storage/asset_record_store.dart';
import '../upload/bucket_flagged.dart';
import '../upload/bucket_leftovers.dart';
import '../upload/bucket_import.dart';
import '../upload/s3_uploader.dart';
import '../vault/keys.dart';
import '../vault/object_key.dart' show fitsProtocol;
import 'storage_optimization_screen.dart';

/// Everything the app wants a person to look at: space it could free on
/// this phone, and objects in the bucket it does not recognise.
///
/// The bucket half never skips anything quietly. Each flagged object gets
/// one fix per job - Rename changes a name inside the bucket, Re-format
/// changes the bytes - and neither is run without being asked.
class FlaggedItemsScreen extends StatefulWidget {
  const FlaggedItemsScreen({
    super.key,
    required this.store,
    required this.targetsStore,
    required this.passphrases,
    required this.advisor,
    required this.optimizer,
    this.onOpenAsset,
  });

  final AssetRecordStore store;
  final BackupTargetsStore targetsStore;
  final Future<List<PassphraseEntry>> Function() passphrases;
  final StorageAdvisor advisor;
  final StorageOptimizer optimizer;
  final Future<void> Function(String localId)? onOpenAsset;

  @override
  State<FlaggedItemsScreen> createState() => _FlaggedItemsScreenState();
}

class _FlaggedItemsScreenState extends State<FlaggedItemsScreen> {
  late final BucketFlags _flags = BucketFlags(store: widget.store);
  late final BucketFixer _fixer = BucketFixer(
    store: widget.store,
    targetsStore: widget.targetsStore,
    passphrases: widget.passphrases,
    uploader: S3Uploader(),
  );
  List<FlaggedObject> _items = const [];
  final Map<String, bool> _reformatable = {};
  final Map<String, String> _notes = {};
  bool _busy = false;
  String? _batchNote;
  int _batchDone = 0;
  int _batchTotal = 0;
  bool _batchStop = false;

  bool get _batching => _batchTotal > 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if ((await widget.store.listBucketObjects()).isEmpty) {
      await BucketIndexer(
        targetsStore: widget.targetsStore,
        recordStore: widget.store,
      ).refresh();
    }
    final items = await _flags.detect(inspect: _fixer.inspect);
    if (!mounted) return;
    setState(() => _items = items);
    for (final item in items) {
      if (item.kind != FlagKind.offProtocol || item.isVideo) continue;
      final ok = await _fixer.canReformat(item);
      if (!mounted) return;
      setState(() => _reformatable[item.object.key] = ok);
    }
  }

  /// Library-side only: the bucket keeps the file, this page stops listing
  /// it, and no scan offers it again.
  Future<void> _ignore(FlaggedObject item) async {
    await IgnoredBucketKeys(widget.store).addAll([item.object.key]);
    if (!mounted) return;
    setState(() => _items = [..._items]..remove(item));
  }

  Future<void> _rescan() async {
    setState(() {
      _busy = true;
      _batchNote = null;
    });
    await BucketIndexer(
      targetsStore: widget.targetsStore,
      recordStore: widget.store,
    ).refresh();
    await _load();
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _fix(
    FlaggedObject item,
    Future<FixResult> Function() run,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    setState(() => _busy = true);
    final result = await run();
    if (!mounted) return;
    if (result.ok) {
      await _rescan();
    } else {
      setState(() {
        _busy = false;
        _notes[item.object.key] = result.outcome == FixOutcome.needsAlbum
            ? l10n.flaggedNeedsAlbum
            : result.detail == null
            ? l10n.flaggedFailed
            : '${l10n.flaggedFailed} (${result.detail})';
      });
    }
  }

  Future<void> _fixAll(
    List<FlaggedObject> items,
    String body,
    String confirm,
    Future<FixResult> Function(FlaggedObject) run,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final go = await showCupertinoDialog<bool>(
      context: context,
      builder: (dialogContext) => CupertinoAlertDialog(
        content: Text(body),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.actionCancel),
          ),
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(confirm),
          ),
        ],
      ),
    );
    if (go != true || !mounted) return;
    unawaited(_runBatch(items, run));
  }

  /// Runs in the background of the screen: the list stays scrollable, each
  /// fixed item drops out as it lands, and Stop ends it after the one in
  /// flight. Nothing is lost by stopping or leaving the app: every fix is
  /// done and recorded per item, so a rescan lists exactly what is left.
  Future<void> _runBatch(
    List<FlaggedObject> items,
    Future<FixResult> Function(FlaggedObject) run,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    setState(() {
      _batchDone = 0;
      _batchTotal = items.length;
      _batchStop = false;
      _batchNote = null;
    });
    var left = 0;
    for (final item in items) {
      if (_batchStop || !mounted) break;
      final ok = (await run(item)).ok;
      if (!mounted) return;
      setState(() {
        _batchDone++;
        if (ok) {
          _items = [
            for (final i in _items)
              if (i.object.key != item.object.key) i,
          ];
        } else {
          left++;
        }
      });
    }
    if (!mounted) return;
    setState(() => _batchTotal = 0);
    await _rescan();
    if (left > 0 && mounted) {
      setState(() => _batchNote = l10n.flaggedBatchLeft(left));
    }
  }

  Widget _batchBar(AppLocalizations l10n) {
    // Likely duplicates stay out of the batch: one at a time, with the
    // reason shown on the card.
    final renamable = [
      for (final i in _items)
        if (i.kind == FlagKind.offProtocol && i.likelyDuplicateOf == null) i,
    ];
    final orphans = [
      for (final i in _items)
        if (i.kind == FlagKind.orphanThumbnail) i,
    ];
    if (_batching) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(settingsPagePadding, 0, 8, 6),
        child: Row(
          children: [
            const CupertinoActivityIndicator(radius: 8),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                l10n.flaggedBatchProgress(_batchDone, _batchTotal),
                style: settingsRowSubtitleStyle,
              ),
            ),
            CupertinoButton(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              minimumSize: const Size(0, 32),
              onPressed: _batchStop
                  ? null
                  : () => setState(() => _batchStop = true),
              child: Text(l10n.flaggedBatchStop),
            ),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(settingsPagePadding, 0, 8, 6),
      child: Wrap(
        children: [
          if (renamable.length > 1)
            _button(
              l10n.flaggedRenameAll(renamable.length),
              () => _fixAll(
                renamable,
                l10n.flaggedBatchRenameBody(renamable.length),
                l10n.flaggedRename,
                _fixer.rename,
              ),
            ),
          if (orphans.length > 1)
            _button(
              l10n.flaggedRemoveAll(orphans.length),
              () => _fixAll(
                orphans,
                l10n.flaggedBatchRemoveBody(orphans.length),
                l10n.flaggedRemove,
                _fixer.removeOrphan,
              ),
            ),
          if (_batchNote != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(_batchNote!, style: settingsErrorStyle),
            ),
        ],
      ),
    );
  }

  Future<void> _reformat(FlaggedObject item) async {
    final l10n = AppLocalizations.of(context)!;
    final megabytes = (item.object.size / 1048576).toStringAsFixed(1);
    final go = await showCupertinoDialog<bool>(
      context: context,
      builder: (dialogContext) => CupertinoAlertDialog(
        title: Text(l10n.flaggedReformatTitle),
        content: Text(l10n.flaggedReformatBody(megabytes)),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.actionCancel),
          ),
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.flaggedReformat),
          ),
        ],
      ),
    );
    if (go == true) await _fix(item, () => _fixer.reformat(item));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return CupertinoPageScaffold(
      backgroundColor: settingsPageBackground,
      navigationBar: CupertinoNavigationBar(
        backgroundColor: settingsPageBackground,
        middle: Text(l10n.flaggedTitle),
        trailing: _busy
            ? const CupertinoActivityIndicator()
            : CupertinoButton(
                padding: EdgeInsets.zero,
                onPressed: _rescan,
                child: Text(l10n.flaggedRescan),
              ),
      ),
      child: SafeArea(
        child: ListView(
          children: [
            SettingsRow(
              leading: const SettingsIconTile(
                icon: CupertinoIcons.chart_pie_fill,
              ),
              title: l10n.flaggedStorageRow,
              trailing: const Icon(
                CupertinoIcons.chevron_forward,
                size: 16,
                color: settingsSecondary,
              ),
              onTap: () => Navigator.of(context).push(
                CupertinoPageRoute<void>(
                  builder: (_) => StorageOptimizationScreen(
                    advisor: widget.advisor,
                    optimizer: widget.optimizer,
                    onOpenAsset: widget.onOpenAsset,
                  ),
                ),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(settingsPagePadding, 20, 16, 6),
              child: SizedBox.shrink(),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                settingsPagePadding,
                0,
                settingsPagePadding,
                6,
              ),
              child: Text(l10n.flaggedBucketHeader, style: settingsFooterStyle),
            ),
            if (_items.isEmpty)
              Padding(
                padding: const EdgeInsets.all(32),
                child: Center(
                  child: Text(
                    l10n.flaggedNone,
                    textAlign: TextAlign.center,
                    style: settingsHintStyle,
                  ),
                ),
              ),
            _batchBar(l10n),
            for (final item in _items) _card(l10n, item),
          ],
        ),
      ),
    );
  }

  Widget _card(AppLocalizations l10n, FlaggedObject item) {
    final key = item.object.key;
    final orphan = item.kind == FlagKind.orphanThumbnail;
    final unclaimed = item.kind == FlagKind.unclaimed;
    final leftover = item.kind == FlagKind.likelyLeftover;
    final megabytes = (item.object.size / 1048576).toStringAsFixed(1);
    final date = DateFormat.yMMMd().format(item.object.lastModified);
    return Container(
      margin: const EdgeInsets.fromLTRB(
        settingsPagePadding,
        0,
        settingsPagePadding,
        10,
      ),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: settingsControlFill,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(item.name, style: settingsRowTitleStyle, maxLines: 1),
          const SizedBox(height: 2),
          Text(
            orphan
                ? l10n.flaggedOrphanReason
                : unclaimed
                ? l10n.flaggedUnclaimedReason
                : leftover
                ? l10n.flaggedLeftoverReason
                : l10n.flaggedOffProtocolReason,
            style: settingsRowSubtitleStyle,
          ),
          if (item.likelyDuplicateOf != null)
            Text(
              l10n.flaggedLikelyDuplicate(
                item.likelyDuplicateOf!.split('/').last,
              ),
              style: settingsRowDetailStyle,
            ),
          Text('$megabytes MB · $date', style: settingsRowDetailStyle),
          if (_notes[key] != null)
            Text(_notes[key]!, style: settingsErrorStyle),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (orphan)
                _button(
                  l10n.flaggedRemove,
                  () => _fix(item, () => _fixer.removeOrphan(item)),
                )
              else if (unclaimed)
                _button(
                  l10n.flaggedImport,
                  () => _fix(item, () => _fixer.adopt(item)),
                )
              else if (leftover) ...[
                _button(l10n.flaggedIgnore, () => _ignore(item)),
                _button(
                  l10n.flaggedImportAnyway,
                  () => _fix(
                    item,
                    () => fitsProtocol(item.name)
                        ? _fixer.adopt(item)
                        : _fixer.rename(item),
                  ),
                ),
              ] else ...[
                if (_reformatable[key] == true)
                  _button(l10n.flaggedReformat, () => _reformat(item)),
                _button(
                  l10n.flaggedRename,
                  () => _fix(item, () => _fixer.rename(item)),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _button(String label, VoidCallback onPressed) => CupertinoButton(
    padding: const EdgeInsets.symmetric(horizontal: 12),
    minimumSize: const Size(0, 32),
    onPressed: _busy || _batching ? null : onPressed,
    child: Text(label),
  );
}
