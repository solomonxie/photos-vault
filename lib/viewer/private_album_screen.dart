import 'dart:io';

import 'package:flutter/cupertino.dart';

import '../l10n/app_localizations.dart';
import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import '../storage/private_album.dart';
import '../storage/private_album_store.dart';
import 'asset_grid.dart';
import 'asset_picker_screen.dart';
import 'delete_confirmation.dart';
import 'detail_screen.dart';

/// Contents of one passcode-gated private album — reached via Utilities'
/// "Hidden" row through `private_album_gate.dart`. Header shows item count +
/// total size; the "..." menu offers Move/Copy from the full library and
/// deleting the album itself (moved-in assets return to the library, mirrors
/// `AlbumStore.remove` — nothing is destroyed). See DESIGN.md.
class PrivateAlbumScreen extends StatefulWidget {
  const PrivateAlbumScreen({
    super.key,
    required this.album,
    required this.assetRecordStore,
    required this.privateAlbumStore,
  });

  final PrivateAlbum album;
  final AssetRecordStore assetRecordStore;
  final PrivateAlbumStore privateAlbumStore;

  @override
  State<PrivateAlbumScreen> createState() => _PrivateAlbumScreenState();
}

class _PrivateAlbumScreenState extends State<PrivateAlbumScreen> {
  List<AssetRecord> _records = const [];
  int _totalBytes = 0;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final ids = (await widget.privateAlbumStore.localIdsIn(widget.album.id)).toSet();
    final all = await widget.assetRecordStore.listAll();
    if (!mounted) return;
    final records = all.where((r) => !r.isDeleted && ids.contains(r.localId)).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    setState(() {
      _records = records;
      // Best-effort: only sums files already resolvable on disk
      // (`manualFile` records, or `photoManager` ones already downloaded) —
      // doesn't trigger an iCloud fetch just to render a header stat.
      _totalBytes = records.fold(0, (sum, r) {
        final path = r.sourcePath;
        if (path == null) return sum;
        final file = File(path);
        return sum + (file.existsSync() ? file.lengthSync() : 0);
      });
    });
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  Future<void> _removeFromAlbum(AssetRecord record) async {
    final moved = (await widget.privateAlbumStore.movedLocalIdsIn(widget.album.id)).contains(record.localId);
    await widget.privateAlbumStore.removeAsset(widget.album.id, record.localId);
    if (moved) await widget.assetRecordStore.setHidden(record.localId, false);
    await _reload();
  }

  Future<bool> _delete(AssetRecord record) async {
    if (!await confirmSoftDelete(context)) return false;
    await widget.assetRecordStore.softDelete(record.localId);
    await _reload();
    return true;
  }

  Future<void> _addFromLibrary({required bool move}) async {
    final l10n = AppLocalizations.of(context)!;
    final picked = await Navigator.of(context).push<List<AssetRecord>>(
      CupertinoPageRoute(
        builder: (_) => AssetPickerScreen(
          title: move ? l10n.privateAlbumPickerMoveTitle : l10n.privateAlbumPickerCopyTitle,
          assetRecordStore: widget.assetRecordStore,
          excludeIds: _records.map((r) => r.localId).toSet(),
        ),
      ),
    );
    if (picked == null || picked.isEmpty) return;
    final album = await widget.privateAlbumStore.ensureById(widget.album.id);
    final ids = picked.map((r) => r.localId);
    await widget.privateAlbumStore.addAssets(album.id, ids, moved: move);
    if (move) {
      for (final id in ids) {
        await widget.assetRecordStore.setHidden(id, true);
      }
    }
    await _reload();
  }

  Future<void> _confirmDeleteAlbum() async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showCupertinoDialog<bool>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: Text(l10n.privateAlbumDeleteConfirmTitle),
        content: Text(l10n.privateAlbumDeleteConfirmBody),
        actions: [
          CupertinoDialogAction(onPressed: () => Navigator.of(context).pop(false), child: Text(l10n.actionCancel)),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.actionDelete),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final movedIds = await widget.privateAlbumStore.movedLocalIdsIn(widget.album.id);
    for (final id in movedIds) {
      await widget.assetRecordStore.setHidden(id, false);
    }
    await widget.privateAlbumStore.remove(widget.album.id);
    if (mounted) Navigator.of(context).pop();
  }

  void _showMenu() {
    final l10n = AppLocalizations.of(context)!;
    showCupertinoModalPopup<void>(
      context: context,
      builder: (context) => CupertinoActionSheet(
        actions: [
          CupertinoActionSheetAction(
            onPressed: () {
              Navigator.of(context).pop();
              _addFromLibrary(move: true);
            },
            child: Text(l10n.privateAlbumMoveFromLibrary),
          ),
          CupertinoActionSheetAction(
            onPressed: () {
              Navigator.of(context).pop();
              _addFromLibrary(move: false);
            },
            child: Text(l10n.privateAlbumCopyFromLibrary),
          ),
          CupertinoActionSheetAction(
            isDestructiveAction: true,
            onPressed: () {
              Navigator.of(context).pop();
              _confirmDeleteAlbum();
            },
            child: Text(l10n.privateAlbumDeleteAlbum),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.actionCancel),
        ),
      ),
    );
  }

  Future<void> _toggleFavorite(AssetRecord record) async {
    await widget.assetRecordStore.setFavorite(record.localId, !record.isFavorite);
    await _reload();
  }

  void _open(AssetRecord record) {
    Navigator.of(context).push(
      CupertinoPageRoute(
        builder: (_) => DetailScreen(
          records: _records,
          initialIndex: _records.indexOf(record),
          onDelete: _delete,
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
        middle: Text(l10n.privateAlbumScreenTitle),
        trailing: CupertinoButton(padding: EdgeInsets.zero, onPressed: _showMenu, child: const Icon(CupertinoIcons.ellipsis_circle)),
      ),
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '${l10n.privateAlbumItemCount(_records.length)} · ${_formatSize(_totalBytes)}',
                  style: const TextStyle(color: CupertinoColors.systemGrey),
                ),
              ),
            ),
            Expanded(
              child: _records.isEmpty
                  ? Center(
                      child: Text(l10n.privateAlbumEmpty, style: const TextStyle(color: CupertinoColors.systemGrey)),
                    )
                  : CustomScrollView(
                      slivers: assetGridSlivers(
                        context: context,
                        records: _records,
                        onTap: _open,
                        actionsFor: (r) => [
                          TileAction(
                            icon: r.isFavorite ? CupertinoIcons.heart_slash : CupertinoIcons.heart,
                            label: r.isFavorite ? l10n.libraryUnfavorite : l10n.libraryFavorite,
                            onPressed: () => _toggleFavorite(r),
                          ),
                          TileAction(
                            icon: CupertinoIcons.eye,
                            label: l10n.privateAlbumRemove,
                            onPressed: () => _removeFromAlbum(r),
                          ),
                          TileAction(
                            icon: CupertinoIcons.delete,
                            label: l10n.libraryDeleteTooltip,
                            isDestructive: true,
                            onPressed: () => _delete(r),
                          ),
                        ],
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
