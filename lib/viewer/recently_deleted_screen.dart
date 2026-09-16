import 'package:flutter/cupertino.dart';

import '../photos/library_metadata.dart';
import '../l10n/app_localizations.dart';
import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import 'asset_grid.dart';
import 'asset_grid_view.dart';
import 'detail_screen.dart';
import 'zoom_page_route.dart';

class RecentlyDeletedScreen extends StatefulWidget {
  const RecentlyDeletedScreen({
    super.key,
    required this.assetRecordStore,
    this.deleteBackup,
  });

  final AssetRecordStore assetRecordStore;

  /// Purges a record's objects from the bucket. This is the one place in
  /// the app that does — everything short of emptying this bin leaves the
  /// backup alone, because it's the copy that outlives the phone.
  ///
  /// Returns whether the bucket came away clean; `false` keeps the record
  /// so the user can try again rather than orphaning objects with nothing
  /// left pointing at them. Absent (standalone/test use) nothing remote is
  /// touched.
  final Future<bool> Function(AssetRecord record)? deleteBackup;

  @override
  State<RecentlyDeletedScreen> createState() => _RecentlyDeletedScreenState();
}

class _RecentlyDeletedScreenState extends State<RecentlyDeletedScreen> {
  List<AssetRecord> _records = const [];

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final all = await widget.assetRecordStore.listAll();
    if (!mounted) return;
    setState(
      () =>
          _records = all.where((r) => r.isDeleted).toList()
            ..sort((a, b) => a.createdAt.compareTo(b.createdAt)),
    );
  }

  Future<void> _recover(AssetRecord record) async {
    await widget.assetRecordStore.restore(record.localId);
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
    final deleteBackup = widget.deleteBackup;
    if (deleteBackup != null && !await deleteBackup(record)) {
      if (mounted) await _showBackupDeleteFailed(l10n);
      return false;
    }
    await widget.assetRecordStore.remove(record.localId);
    await _reload();
    return true;
  }

  Future<void> _showBackupDeleteFailed(AppLocalizations l10n) =>
      showCupertinoDialog<void>(
        context: context,
        builder: (context) => CupertinoAlertDialog(
          title: Text(l10n.libraryDeletePermanentlyTitle),
          content: Text(l10n.libraryDeleteBackupFailed),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(l10n.actionOk),
            ),
          ],
        ),
      );

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
      ),
      child: SafeArea(
        child: _records.isEmpty
            ? Center(
                child: Text(
                  l10n.libraryRecentlyDeletedEmpty,
                  style: const TextStyle(color: CupertinoColors.systemGrey),
                ),
              )
            : AssetGridView(
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
    );
  }
}
