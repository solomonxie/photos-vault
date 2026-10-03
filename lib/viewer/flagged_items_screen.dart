import 'package:flutter/cupertino.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../photos/storage_advice.dart';
import '../photos/storage_optimizer.dart';
import '../settings/backup_targets_store.dart';
import '../settings/settings_section.dart';
import '../storage/asset_record_store.dart';
import '../upload/bucket_flagged.dart';
import '../upload/bucket_import.dart';
import '../upload/s3_uploader.dart';
import '../vault/keys.dart';
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
    final items = await _flags.detect();
    if (!mounted) return;
    setState(() => _items = items);
    for (final item in items) {
      if (item.kind != FlagKind.offProtocol || item.isVideo) continue;
      final ok = await _fixer.canReformat(item);
      if (!mounted) return;
      setState(() => _reformatable[item.object.key] = ok);
    }
  }

  Future<void> _rescan() async {
    setState(() => _busy = true);
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
            : l10n.flaggedFailed;
      });
    }
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
            for (final item in _items) _card(l10n, item),
          ],
        ),
      ),
    );
  }

  Widget _card(AppLocalizations l10n, FlaggedObject item) {
    final key = item.object.key;
    final orphan = item.kind == FlagKind.orphanThumbnail;
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
            orphan ? l10n.flaggedOrphanReason : l10n.flaggedOffProtocolReason,
            style: settingsRowSubtitleStyle,
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
              else ...[
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
    onPressed: _busy ? null : onPressed,
    child: Text(label),
  );
}
