import 'package:flutter/cupertino.dart';

import '../l10n/app_localizations.dart';
import '../storage/album.dart';
import '../storage/album_store.dart';
import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import 'asset_grid.dart';
import 'asset_grid_view.dart';
import 'delete_confirmation.dart';
import 'detail_screen.dart';
import 'private_album_gate.dart';

/// One album's contents — same active-library set as the main grid, filtered
/// to this album's membership (`AlbumStore.localIdsIn`). Shares the
/// Favorite/Hide/Delete actions with [LibraryScreenState], plus a
/// "Remove from Album" action that only affects membership, not the asset.
class AlbumScreen extends StatefulWidget {
  const AlbumScreen({
    super.key,
    required this.album,
    required this.assetRecordStore,
    required this.albumStore,
  });

  final Album album;
  final AssetRecordStore assetRecordStore;
  final AlbumStore albumStore;

  @override
  State<AlbumScreen> createState() => _AlbumScreenState();
}

class _AlbumScreenState extends State<AlbumScreen> {
  List<AssetRecord> _records = const [];

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final memberIds = (await widget.albumStore.localIdsIn(widget.album.id))
        .toSet();
    final all = await widget.assetRecordStore.listAll();
    if (!mounted) return;
    setState(
      () => _records =
          all
              .where(
                (r) =>
                    !r.isDeleted &&
                    !r.isHidden &&
                    r.passcodeHash == null &&
                    memberIds.contains(r.localId),
              )
              .toList()
            ..sort((a, b) => a.createdAt.compareTo(b.createdAt)),
    );
  }

  Future<void> _toggleFavorite(AssetRecord record) async {
    await widget.assetRecordStore.setFavorite(
      record.localId,
      !record.isFavorite,
    );
    await _reload();
  }

  Future<void> _hide(AssetRecord record) async {
    await hideIntoPrivateAlbum(
      context,
      assetRecordStore: widget.assetRecordStore,
      record: record,
    );
    await _reload();
  }

  Future<bool> _delete(AssetRecord record) async {
    if (!await confirmSoftDelete(context)) return false;
    await widget.assetRecordStore.softDelete(record.localId);
    await _reload();
    return true;
  }

  Future<void> _removeFromAlbum(AssetRecord record) async {
    await widget.albumStore.removeAsset(widget.album.id, record.localId);
    await _reload();
  }

  void _open(AssetRecord record) {
    Navigator.of(context).push(
      CupertinoPageRoute(
        builder: (_) => DetailScreen(
          records: _records,
          initialIndex: _records.indexOf(record),
          assetRecordStore: widget.assetRecordStore,
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
      navigationBar: CupertinoNavigationBar(middle: Text(widget.album.name)),
      child: SafeArea(
        child: _records.isEmpty
            ? Center(
                child: Text(
                  l10n.libraryAlbumEmpty,
                  style: const TextStyle(color: CupertinoColors.systemGrey),
                ),
              )
            : AssetGridView(
                records: _records,
                onTap: _open,
                actionsFor: (r) => [
                  TileAction(
                    icon: r.isFavorite
                        ? CupertinoIcons.heart_slash
                        : CupertinoIcons.heart,
                    label: r.isFavorite
                        ? l10n.libraryUnfavorite
                        : l10n.libraryFavorite,
                    onPressed: () => _toggleFavorite(r),
                  ),
                  TileAction(
                    icon: CupertinoIcons.rectangle_stack_badge_minus,
                    label: l10n.libraryRemoveFromAlbum,
                    onPressed: () => _removeFromAlbum(r),
                  ),
                  TileAction(
                    icon: CupertinoIcons.eye_slash,
                    label: l10n.libraryHide,
                    onPressed: () => _hide(r),
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
    );
  }
}
