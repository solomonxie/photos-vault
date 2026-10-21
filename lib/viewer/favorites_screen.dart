import 'package:flutter/cupertino.dart';

import '../photos/library_metadata.dart';
import '../l10n/app_localizations.dart';
import '../photos/asset_removal.dart';
import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import '../storage/note.dart';
import 'album_notes.dart';
import 'asset_grid.dart';
import 'built_in_album.dart';
import 'asset_grid_view.dart';
import 'delete_confirmation.dart';
import 'detail_screen.dart';
import 'library_index.dart';
import 'zoom_page_route.dart';

class FavoritesScreen extends StatefulWidget {
  const FavoritesScreen({
    super.key,
    required this.assetRecordStore,
    this.notes,
  });

  final AssetRecordStore assetRecordStore;

  /// Its notes, as an album's: under its built-in id.
  final NoteBook? notes;

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
    // The library screen's own list for this library when it has one; in
    // grid order either way, so no sort.
    setState(() => _records = LibraryIndex.forList(all).favorites);
  }

  Future<void> _unfavorite(AssetRecord record) async {
    await setFavoriteEverywhere(widget.assetRecordStore, record, false);
    await _reload();
  }

  /// The viewer's heart toggles, so one tapped by mistake can be tapped back.
  Future<void> _toggleFavorite(AssetRecord record) async {
    await setFavoriteEverywhere(
      widget.assetRecordStore,
      record,
      !record.isFavorite,
    );
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
        middle: Text(l10n.collectionsFavoritesRow),
      ),
      child: SafeArea(
        child: _records.isEmpty
            ? ListView(
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 32),
                    child: Center(
                      child: Text(
                        l10n.libraryFavoritesEmpty,
                        style: const TextStyle(
                          color: CupertinoColors.systemGrey,
                        ),
                      ),
                    ),
                  ),
                  if (widget.notes case final notes?) AlbumNotes(book: notes),
                ],
              )
            : AssetGridView(
                records: _records,
                onTap: _open,
                trailingSlivers: [
                  if (widget.notes case final notes?)
                    SliverToBoxAdapter(child: AlbumNotes(book: notes)),
                ],
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
