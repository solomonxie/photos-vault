import 'package:flutter/cupertino.dart';

import '../photos/library_metadata.dart';
import '../l10n/app_localizations.dart';
import '../photos/asset_removal.dart';
import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import 'asset_grid.dart';
import 'built_in_album.dart';
import 'asset_grid_view.dart';
import 'delete_confirmation.dart';
import 'detail_screen.dart';
import 'zoom_page_route.dart';

class FavoritesScreen extends StatefulWidget {
  const FavoritesScreen({super.key, required this.assetRecordStore});

  final AssetRecordStore assetRecordStore;

  @override
  State<FavoritesScreen> createState() => _FavoritesScreenState();
}

class _FavoritesScreenState extends State<FavoritesScreen> {
  List<AssetRecord> _records = const [];

  @override
  void initState() {
    super.initState();
    _reload();
    _loadCover();
  }

  Future<void> _reload() async {
    final all = await widget.assetRecordStore.listAll();
    if (!mounted) return;
    setState(
      () =>
          _records = all.where((r) => r.isFavorite && !r.isDeleted).toList()
            ..sort((a, b) => a.createdAt.compareTo(b.createdAt)),
    );
  }

  Future<void> _unfavorite(AssetRecord record) async {
    await setFavoriteEverywhere(widget.assetRecordStore, record, false);
    await _reload();
  }

  /// Deleting is the same decision on every screen: keep the cloud copy
  /// and free the space, or bin it. See `../photos/asset_removal.dart`.
  late final AssetRemoval _removal = AssetRemoval(
    store: widget.assetRecordStore,
  );

  Future<bool> _delete(AssetRecord record) async {
    final outcome = await deleteAsset(
      context,
      record: record,
      removal: _removal,
    );
    await _reload();
    return outcome.leftTheList;
  }

  /// What the Favourites card draws — see [BuiltInAlbum].
  String? _cover;

  Future<void> _loadCover() async {
    final chosen = await builtInAlbumCover(
      widget.assetRecordStore,
      BuiltInAlbum.favorites,
    );
    if (mounted) setState(() => _cover = chosen);
  }

  Future<void> _setCover(String? localId) async {
    await setBuiltInAlbumCover(
      widget.assetRecordStore,
      BuiltInAlbum.favorites,
      localId,
    );
    if (mounted) setState(() => _cover = localId);
  }

  void _open(AssetRecord record) {
    Navigator.of(context).push(
      ZoomPageRoute(
        builder: (_) => DetailScreen(
          records: _records,
          initialIndex: _records.indexOf(record),
          assetRecordStore: widget.assetRecordStore,
          onDelete: _delete,
          onToggleFavorite: _unfavorite,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(l10n.collectionsFavoritesRow),
      ),
      child: SafeArea(
        child: _records.isEmpty
            ? Center(
                child: Text(
                  l10n.libraryFavoritesEmpty,
                  style: const TextStyle(color: CupertinoColors.systemGrey),
                ),
              )
            : AssetGridView(
                records: _records,
                onTap: _open,
                actionsFor: (r) => [
                  TileAction(
                    icon: CupertinoIcons.heart_slash,
                    label: l10n.libraryUnfavorite,
                    onPressed: () => _unfavorite(r),
                  ),
                  ...coverActions(
                    l10n,
                    enabled: true,
                    isCover: _cover == r.localId,
                    onUse: () => _setCover(r.localId),
                    onDefault: () => _setCover(null),
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
