import 'package:flutter/cupertino.dart';

import '../photos/library_metadata.dart';
import '../l10n/app_localizations.dart';
import '../storage/album.dart';
import '../storage/album_store.dart';
import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import 'asset_grid.dart';
import 'asset_picker_screen.dart';
import 'asset_grid_view.dart';
import 'delete_confirmation.dart';
import 'detail_screen.dart';
import 'private_album_gate.dart';
import 'search_picker_sheet.dart';
import 'zoom_page_route.dart';

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
  late Album _album = widget.album;
  late final TextEditingController _description = TextEditingController(
    text: widget.album.description,
  );
  List<AssetRecord> _records = const [];

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _description.dispose();
    super.dispose();
  }

  /// Saved as it's typed, like the photo's own caption — an album note is a
  /// sentence, not a form, and a Save button on one field is a button that
  /// only exists to be forgotten.
  Future<void> _saveDescription(String value) async {
    final updated = _album.copyWith(description: value);
    await widget.albumStore.update(updated);
    _album = updated;
  }

  Future<void> _addTag() async {
    final l10n = AppLocalizations.of(context)!;
    final existing = await widget.albumStore.allTags();
    if (!mounted) return;
    final tag = await showSearchPickerSheet(
      context: context,
      title: l10n.albumTagsHeading,
      options: existing.difference(_album.tags.toSet()),
    );
    if (tag == null || tag.isEmpty) return;
    await _setTags([..._album.tags, tag]);
  }

  Future<void> _removeTag(String tag) =>
      _setTags(_album.tags.where((t) => t != tag).toList());

  Future<void> _setTags(List<String> tags) async {
    final updated = _album.copyWith(tags: tags);
    await widget.albumStore.update(updated);
    if (!mounted) return;
    setState(() => _album = updated);
  }

  /// Picks from the library rather than the OS picker: what belongs in an
  /// album is almost always already here, and importing a second copy of a
  /// photo the app is already backing up is the wrong answer to "add".
  Future<void> _addPhotos() async {
    final l10n = AppLocalizations.of(context)!;
    final picked = await Navigator.of(context).push<List<AssetRecord>>(
      CupertinoPageRoute(
        builder: (_) => AssetPickerScreen(
          title: l10n.albumAddPhotos,
          assetRecordStore: widget.assetRecordStore,
          excludeIds: _records.map((r) => r.localId).toSet(),
        ),
      ),
    );
    if (picked == null || picked.isEmpty) return;
    await widget.albumStore.addAssets(_album.id, picked.map((r) => r.localId));
    await _reload();
  }

  Future<void> _reload() async {
    final refreshed = await widget.albumStore.getById(_album.id);
    final memberIds = (await widget.albumStore.localIdsIn(_album.id)).toSet();
    final all = await widget.assetRecordStore.listAll();
    if (!mounted) return;
    if (refreshed != null) _album = refreshed;
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
    await setFavoriteEverywhere(
      widget.assetRecordStore,
      record,
      !record.isFavorite,
    );
    await _reload();
  }

  Future<void> _hide(AssetRecord record) async {
    await hideIntoPrivateAlbum(
      context,
      assetRecordStore: widget.assetRecordStore,
      records: [record],
    );
    await _reload();
  }

  Future<bool> _delete(AssetRecord record) async {
    if (!await confirmSoftDelete(context)) return false;
    await widget.assetRecordStore.softDelete(record.localId);
    await _reload();
    return true;
  }

  /// The album's own picture. Videos count: a poster frame is what the
  /// grid already draws for one, so an album of videos has a cover like
  /// any other.
  Future<void> _setCover(AssetRecord record) async {
    final updated = _album.copyWith(coverLocalId: record.localId);
    await widget.albumStore.update(updated);
    if (!mounted) return;
    setState(() => _album = updated);
  }

  Future<void> _removeFromAlbum(AssetRecord record) async {
    await widget.albumStore.removeAsset(_album.id, record.localId);
    await _reload();
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
        middle: Text(_album.name),
        trailing: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: _addPhotos,
          child: const Icon(CupertinoIcons.add),
        ),
      ),
      child: SafeArea(
        child: _records.isEmpty
            ? ListView(
                children: [
                  _header(l10n),
                  Padding(
                    padding: const EdgeInsets.only(top: 32),
                    child: Center(
                      child: Text(
                        l10n.libraryAlbumEmpty,
                        style: const TextStyle(
                          color: CupertinoColors.systemGrey,
                        ),
                      ),
                    ),
                  ),
                ],
              )
            : AssetGridView(
                records: _records,
                onTap: _open,
                onAdd: _addPhotos,
                leadingSlivers: [SliverToBoxAdapter(child: _header(l10n))],
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
                    icon: CupertinoIcons.rectangle_on_rectangle,
                    label: l10n.albumUseAsCover,
                    onPressed: () => _setCover(r),
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

  /// What the album is, above what's in it: a note and its tags. Both
  /// describe the set — saying "Kyoto, October" on four hundred photos
  /// says it four hundred times.
  Widget _header(AppLocalizations l10n) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CupertinoTextField.borderless(
          controller: _description,
          placeholder: l10n.albumDescriptionPlaceholder,
          maxLines: null,
          padding: EdgeInsets.zero,
          style: const TextStyle(color: CupertinoColors.white, fontSize: 15),
          onChanged: _saveDescription,
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final tag in _album.tags)
              GestureDetector(
                onTap: () => _removeTag(tag),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF2C2C2E),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        tag,
                        style: const TextStyle(
                          color: CupertinoColors.white,
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(width: 4),
                      const Icon(
                        CupertinoIcons.xmark,
                        size: 11,
                        color: CupertinoColors.systemGrey,
                      ),
                    ],
                  ),
                ),
              ),
            CupertinoButton(
              padding: EdgeInsets.zero,
              minimumSize: Size.zero,
              onPressed: _addTag,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    CupertinoIcons.add,
                    size: 14,
                    color: CupertinoColors.activeBlue,
                  ),
                  const SizedBox(width: 3),
                  Text(
                    l10n.albumTagsHeading,
                    style: const TextStyle(
                      color: CupertinoColors.activeBlue,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    ),
  );
}
