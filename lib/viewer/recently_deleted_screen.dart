import 'package:flutter/cupertino.dart';

import '../photos/asset_removal.dart';
import '../photos/library_metadata.dart';
import '../l10n/app_localizations.dart';
import '../settings/backup_targets_store.dart';
import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import '../upload/pending_deletes.dart';
import 'asset_grid.dart';
import 'asset_grid_view.dart';
import 'detail_screen.dart';
import 'zoom_page_route.dart';

class RecentlyDeletedScreen extends StatefulWidget {
  const RecentlyDeletedScreen({
    super.key,
    required this.assetRecordStore,
    this.removal,
    this.pendingDeletes,
    this.targetsStore,
  });

  final AssetRecordStore assetRecordStore;

  /// What a permanent delete and Recover go through. A permanent delete
  /// leaves the bucket's copies on the durable queue (`PendingDeletes`)
  /// rather than attempting them here: the photo is gone from this phone
  /// at once and each bucket lets go whenever it can be reached.
  final AssetRemoval? removal;
  final PendingDeletes? pendingDeletes;
  final BackupTargetsStore? targetsStore;

  @override
  State<RecentlyDeletedScreen> createState() => _RecentlyDeletedScreenState();
}

class _RecentlyDeletedScreenState extends State<RecentlyDeletedScreen> {
  List<AssetRecord> _records = const [];
  List<BlockedTarget> _blocked = const [];

  late final AssetRemoval _removal =
      widget.removal ?? AssetRemoval(store: widget.assetRecordStore);
  late final PendingDeletes _pending =
      widget.pendingDeletes ?? PendingDeletes(store: widget.assetRecordStore);
  late final BackupTargetsStore _targets =
      widget.targetsStore ?? BackupTargetsStore();

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    await _removal.expireBin();
    final all = await widget.assetRecordStore.listAll();
    final binned = await _removal.purgeVanished(
      // A hidden photo never shows here: this page opens without a
      // passcode. Hidden deletes are permanent (`HiddenRemoval`); this only
      // catches one binned before that existed.
      all.where((r) => r.isDeleted && r.passcodeHash == null).toList(),
    );
    if (!mounted) return;
    setState(() {
      _records = binned..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    });
    final blocked = await _loadBlocked();
    if (mounted) setState(() => _blocked = blocked);
  }

  Future<List<BlockedTarget>> _loadBlocked() async {
    try {
      return await _pending.blocked(await _targets.loadAll());
    } catch (_) {
      return const [];
    }
  }

  Future<void> _recover(AssetRecord record) async {
    await _removal.recover(record);
    await _reload();
  }

  Future<bool> _deletePermanently(AssetRecord record) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showCupertinoDialog<bool>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: Text(l10n.libraryDeletePermanentlyTitle),
        content: Text(l10n.libraryDeletePermanentlyBody),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.actionCancel),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.actionDelete),
          ),
        ],
      ),
    );
    if (confirmed != true) return false;
    final gone = await _removal.deletePermanently(record);
    await _reload();
    return gone;
  }

  Future<void> _emptyBin() async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showCupertinoDialog<bool>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: Text(l10n.libraryEmptyBinTitle),
        content: Text(l10n.libraryEmptyBinBody),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.actionCancel),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.libraryEmptyBin),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _removal.emptyBin();
    await _reload();
  }

  Future<void> _forget(BlockedTarget blocked) async {
    final l10n = AppLocalizations.of(context)!;
    final name = blocked.target.bucket;
    final confirmed = await showCupertinoDialog<bool>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: Text(l10n.pendingDeletesForgetTitle(name)),
        content: Text(l10n.pendingDeletesForgetBody),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.actionCancel),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.pendingDeletesForget),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _pending.forgetTarget(blocked.target.id);
    await _reload();
  }

  Future<void> _toggleFavorite(AssetRecord record) async {
    await setFavoriteEverywhere(
      widget.assetRecordStore,
      record,
      !record.isFavorite,
    );
    await _reload();
  }

  void _open(AssetRecord record) {
    Navigator.of(context).push(
      ZoomPageRoute(
        builder: (_) => DetailScreen(
          records: _records,
          initialIndex: _records.indexOf(record),
          assetRecordStore: widget.assetRecordStore,
          onDelete: _deletePermanently,
          onToggleFavorite: _toggleFavorite,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(l10n.collectionsRecentlyDeletedRow),
        trailing: _records.isEmpty
            ? null
            : CupertinoButton(
                padding: EdgeInsets.zero,
                onPressed: _emptyBin,
                child: Text(l10n.libraryEmptyBin),
              ),
      ),
      child: SafeArea(
        child: Column(
          children: [
            for (final blocked in _blocked)
              CupertinoButton(
                padding: const EdgeInsets.all(12),
                onPressed: () => _forget(blocked),
                child: Text(
                  l10n.pendingDeletesBlocked(
                    blocked.waiting,
                    blocked.target.bucket,
                  ),
                  style: const TextStyle(
                    color: CupertinoColors.systemOrange,
                    fontSize: 13,
                  ),
                ),
              ),
            Expanded(
              child: _records.isEmpty
                  ? Center(
                      child: Text(
                        l10n.libraryRecentlyDeletedEmpty,
                        style: const TextStyle(
                          color: CupertinoColors.systemGrey,
                        ),
                      ),
                    )
                  : Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(8),
                          child: Text(
                            l10n.libraryRecentlyDeletedNote,
                            style: const TextStyle(
                              color: CupertinoColors.systemGrey,
                              fontSize: 12,
                            ),
                          ),
                        ),
                        Expanded(
                          child: AssetGridView(
                            records: _records,
                            onTap: _open,
                            actionsFor: (r) => [
                              TileAction(
                                icon: CupertinoIcons.arrow_uturn_left,
                                label: l10n.libraryRecover,
                                onPressed: () => _recover(r),
                              ),
                              TileAction(
                                icon: CupertinoIcons.delete,
                                label: l10n.libraryDeletePermanentlyAction,
                                isDestructive: true,
                                onPressed: () => _deletePermanently(r),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
