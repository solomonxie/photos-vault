import 'package:flutter/cupertino.dart';
import 'package:flutter/rendering.dart';

import '../photos/library_metadata.dart';
import '../l10n/app_localizations.dart';
import '../storage/album.dart';
import '../storage/album_store.dart';
import '../photos/asset_removal.dart';
import '../photos/photo_library_service.dart';
import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import 'asset_grid.dart';
import 'asset_picker_screen.dart';
import 'asset_grid_view.dart';
import 'delete_confirmation.dart';
import 'detail_screen.dart';
import 'album_notes.dart';
import 'private_album_gate.dart';
import 'search_picker_sheet.dart';
import 'select_all.dart';
import 'select_sweep.dart';
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
    this.photoLibraryService,
  });

  final Album album;
  final AssetRecordStore assetRecordStore;
  final AlbumStore albumStore;

  /// The library's, so a batch delete asks Photos the way the library does.
  final PhotoLibraryService? photoLibraryService;

  @override
  State<AlbumScreen> createState() => _AlbumScreenState();
}

class _AlbumScreenState extends State<AlbumScreen> {
  late Album _album = widget.album;
  late final TextEditingController _description = TextEditingController(
    text: widget.album.description,
  );
  List<AssetRecord> _records = const [];
  late final Widget _notes = AlbumNotes(
    book: widget.albumStore.noteBook(widget.album.id),
  );

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _description.dispose();
    _picked.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------- selection

  /// Select mode is on; [_picked] is what the bar acts on.
  bool _selecting = false;
  final _picked = ValueNotifier<Set<String>>(const {});
  final _sweep = SelectSweep<String>();

  void _startSelecting(AssetRecord record) {
    setState(() => _selecting = true);
    _picked.value = {..._picked.value, record.localId};
    _sweep.begin(record.localId, base: _picked.value);
  }

  void _endSelecting() => setState(() {
    _selecting = false;
    _picked.value = const {};
  });

  void _toggleSelected(AssetRecord record) {
    final next = {..._picked.value};
    if (!next.remove(record.localId)) next.add(record.localId);
    _picked.value = next;
  }

  void _onSelectDragUpdate(Offset globalPosition) {
    final record = _recordUnder(globalPosition);
    if (record == null) return;
    final next = _sweep.over(
      record.localId,
      _picked.value,
      () => [for (final r in _records) r.localId],
    );
    if (next != null) _picked.value = next;
  }

  /// The tile under the finger, asked of the tiles: each carries its
  /// record in a `MetaData` (see `AssetTile`).
  AssetRecord? _recordUnder(Offset globalPosition) {
    final view = View.maybeOf(context);
    if (view == null) return null;
    final result = HitTestResult();
    WidgetsBinding.instance.hitTestInView(result, globalPosition, view.viewId);
    for (final entry in result.path) {
      final target = entry.target;
      if (target is RenderMetaData && target.metaData is AssetRecord) {
        return target.metaData as AssetRecord;
      }
    }
    return null;
  }

  List<AssetRecord> get _selectedRecords {
    final ids = _picked.value;
    return [
      for (final r in _records)
        if (ids.contains(r.localId)) r,
    ];
  }

  Future<void> _removeSelected() async {
    final ids = _picked.value;
    if (ids.isEmpty) return;
    await widget.albumStore.removeAssets(_album.id, ids);
    if (!mounted) return;
    _endSelecting();
    await _reload();
  }

  Future<void> _favoriteSelected() async {
    final records = _selectedRecords;
    final value = !records.every((r) => r.isFavorite);
    // One Photos change per photo: bounded by the selection.
    for (final r in records) {
      await setFavoriteEverywhere(widget.assetRecordStore, r, value);
    }
    if (!mounted) return;
    _endSelecting();
    await _reload();
  }

  Future<void> _archiveSelected() async {
    await widget.assetRecordStore.setArchived(_picked.value, true);
    if (!mounted) return;
    _endSelecting();
    await _reload();
  }

  late final PhotoLibraryService _library =
      widget.photoLibraryService ??
      PhotoLibraryService(store: widget.assetRecordStore);

  /// Into Recently Deleted, as the library's batch delete does: one sheet,
  /// one Photos prompt for the lot. Locked photos are left alone; freeing
  /// space instead is the library's (it needs the backup check).
  Future<void> _deleteSelected() async {
    final unlocked = _selectedRecords.where((r) => !r.isLocked).toList();
    if (unlocked.isEmpty) return;
    const limit = PhotoLibraryService.deleteBatchLimit;
    final batch = unlocked.take(limit).toList();
    final choice = await chooseBatchDelete(
      context,
      count: batch.length,
      removable: 0,
      cloudOnly: batch.where((r) => r.localDeleted).length,
    );
    if (choice != DeleteChoice.everywhere) return;
    final fromLibrary = [
      for (final r in batch)
        if (r.sourceType == AssetSourceType.photoManager &&
            !r.localDeleted &&
            r.libraryId != null)
          r,
    ];
    Set<String> gone;
    try {
      gone = fromLibrary.isEmpty
          ? const {}
          : await _library.deleteManyFromLibrary(
              fromLibrary,
              missingCountsAsDeleted: true,
            );
    } catch (_) {
      // No plugin, or already out of Photos: nothing there to delete.
      gone = {for (final r in fromLibrary) r.localId};
    }
    final needsLibrary = {for (final r in fromLibrary) r.localId};
    for (final r in batch) {
      // Declined at the Photos prompt: left as it is.
      if (needsLibrary.contains(r.localId) && !gone.contains(r.localId)) {
        continue;
      }
      await _removal.binOrPurge(r);
    }
    if (!mounted) return;
    _endSelecting();
    await _reload();
  }

  Future<void> _hideSelected() async {
    final records = _selectedRecords;
    if (records.isEmpty) return;
    final hidden = await hideIntoPrivateAlbum(
      context,
      assetRecordStore: widget.assetRecordStore,
      records: records,
      onSettled: () {
        if (mounted) _reload();
      },
    );
    if (!mounted) return;
    if (hidden) _endSelecting();
    await _reload();
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
    final memberIds = await widget.albumStore.localIdsIn(_album.id);
    // From the library's cache: no row reads.
    final members = await widget.assetRecordStore.listOf(memberIds);
    if (!mounted) return;
    if (refreshed != null) _album = refreshed;
    setState(
      () => _records = [
        for (final r in members)
          if (r.isVisibleInLibrary) r,
      ],
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
      onSettled: () {
        if (mounted) _reload();
      },
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
        trailing: _selecting
            ? null
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_records.isNotEmpty)
                    CupertinoButton(
                      key: const ValueKey('albumSelect'),
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      onPressed: () => setState(() => _selecting = true),
                      child: Text(l10n.albumSelect),
                    ),
                  CupertinoButton(
                    padding: EdgeInsets.zero,
                    onPressed: _addPhotos,
                    child: const Icon(CupertinoIcons.add),
                  ),
                ],
              ),
      ),
      child: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(child: _body(l10n)),
            if (_selecting)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: ValueListenableBuilder(
                  valueListenable: _picked,
                  builder: (context, picked, _) => _AlbumSelectionBar(
                    count: picked.length,
                    selectAll: SelectAllButton(
                      total: _records.length,
                      selectedCount: picked.length,
                      onSelectNext: () => _picked.value = selectNextBatch(
                        _records.reversed.map((r) => r.localId),
                        picked,
                      ),
                      onDeselectAll: () => _picked.value = const {},
                    ),
                    onRemove: _removeSelected,
                    onHide: _hideSelected,
                    onFavorite: _favoriteSelected,
                    allFavorite:
                        picked.isNotEmpty &&
                        _selectedRecords.every((r) => r.isFavorite),
                    onArchive: _archiveSelected,
                    onDelete: _deleteSelected,
                    onCover: picked.length == 1
                        ? () {
                            _setCover(_selectedRecords.single);
                            _endSelecting();
                          }
                        : null,
                    onDone: _endSelecting,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _body(AppLocalizations l10n) {
    return _records.isEmpty
        ? ListView(
            children: [
              _header(l10n),
              _notes,
              Padding(
                padding: const EdgeInsets.only(top: 32),
                child: Center(
                  child: Text(
                    l10n.libraryAlbumEmpty,
                    style: const TextStyle(color: CupertinoColors.systemGrey),
                  ),
                ),
              ),
            ],
          )
        : AssetGridView(
            records: _records,
            onTap: _selecting ? _toggleSelected : _open,
            onLongPress: _startSelecting,
            onSelectDragUpdate: _onSelectDragUpdate,
            onSelectDragEnd: _sweep.end,
            selection: _selecting ? _picked : null,
            onAdd: _selecting ? null : _addPhotos,
            leadingSlivers: [SliverToBoxAdapter(child: _header(l10n))],
            trailingSlivers: [
              SliverToBoxAdapter(child: _notes),
              // Clear of the selection bar.
              if (_selecting)
                const SliverToBoxAdapter(child: SizedBox(height: 120)),
            ],
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

/// The bar select mode puts at the bottom: what is picked, and what can
/// be done to all of it at once.
class _AlbumSelectionBar extends StatelessWidget {
  const _AlbumSelectionBar({
    required this.count,
    required this.selectAll,
    required this.onRemove,
    required this.onHide,
    required this.onFavorite,
    required this.allFavorite,
    required this.onArchive,
    required this.onDelete,
    required this.onCover,
    required this.onDone,
  });

  final int count;
  final Widget selectAll;
  final VoidCallback onRemove;
  final VoidCallback onHide;
  final VoidCallback onFavorite;
  final bool allFavorite;
  final VoidCallback onArchive;
  final VoidCallback onDelete;

  /// One photo picked: it can be the cover.
  final VoidCallback? onCover;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    Widget action(
      IconData icon,
      String label,
      VoidCallback? onPressed,
      Key key,
    ) => Expanded(
      child: CupertinoButton(
        key: key,
        padding: const EdgeInsets.symmetric(vertical: 8),
        onPressed: count == 0 ? null : onPressed,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 22),
            const SizedBox(height: 2),
            Text(label, style: const TextStyle(fontSize: 12)),
          ],
        ),
      ),
    );
    return Container(
      decoration: BoxDecoration(
        color: CupertinoDynamicColor.resolve(
          CupertinoColors.systemBackground,
          context,
        ),
        border: Border(
          top: BorderSide(
            color: CupertinoDynamicColor.resolve(
              CupertinoColors.separator,
              context,
            ),
          ),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    count == 0
                        ? l10n.selectionHint
                        : l10n.selectionTitle(count),
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                selectAll,
                CupertinoButton(
                  key: const ValueKey('albumSelectionDone'),
                  padding: EdgeInsets.zero,
                  onPressed: onDone,
                  child: Text(l10n.selectionDone),
                ),
              ],
            ),
          ),
          Row(
            children: [
              action(
                CupertinoIcons.rectangle_stack_badge_minus,
                l10n.libraryRemoveFromAlbum,
                onRemove,
                const ValueKey('albumRemoveSelected'),
              ),
              action(
                CupertinoIcons.eye_slash,
                l10n.libraryHide,
                onHide,
                const ValueKey('albumHideSelected'),
              ),
              action(
                CupertinoIcons.ellipsis_circle,
                l10n.selectionMore,
                () => _showMore(context, l10n),
                const ValueKey('albumSelectionMore'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// The rarer ones, as the library's More sheet keeps them.
  void _showMore(BuildContext context, AppLocalizations l10n) {
    void run(BuildContext sheet, VoidCallback action) {
      Navigator.of(sheet).pop();
      action();
    }

    showCupertinoModalPopup<void>(
      context: context,
      builder: (sheet) => CupertinoActionSheet(
        title: Text(l10n.selectionTitle(count)),
        actions: [
          if (onCover case final cover?)
            CupertinoActionSheetAction(
              onPressed: () => run(sheet, cover),
              child: Text(l10n.albumUseAsCover),
            ),
          CupertinoActionSheetAction(
            key: const ValueKey('albumFavoriteSelected'),
            onPressed: () => run(sheet, onFavorite),
            child: Text(
              allFavorite ? l10n.libraryUnfavorite : l10n.libraryFavorite,
            ),
          ),
          CupertinoActionSheetAction(
            key: const ValueKey('albumArchiveSelected'),
            onPressed: () => run(sheet, onArchive),
            child: Text(l10n.archiveAction),
          ),
          CupertinoActionSheetAction(
            key: const ValueKey('albumDeleteSelected'),
            isDestructiveAction: true,
            onPressed: () => run(sheet, onDelete),
            child: Text(l10n.selectionDelete),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(sheet).pop(),
          child: Text(l10n.actionCancel),
        ),
      ),
    );
  }
}
