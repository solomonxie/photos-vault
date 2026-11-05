import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/rendering.dart';

import '../photos/library_metadata.dart';
import '../l10n/app_localizations.dart';
import '../photos/asset_removal.dart';
import '../photos/photo_library_service.dart';
import '../photos/travel_store.dart';
import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import '../storage/note.dart';
import 'album_notes.dart';
import 'asset_grid.dart';
import 'built_in_album.dart';
import 'asset_grid_view.dart';
import 'delete_confirmation.dart';
import 'detail_screen.dart';
import 'photo_grid_layout.dart';
import 'private_album_gate.dart';
import 'select_all.dart';
import 'select_sweep.dart';
import 'zoom_page_route.dart';

/// Grid screen for a fixed list of records — used to drill into one place,
/// or one People group from [SmartCollectionScreen].
class AssetGroupScreen extends StatefulWidget {
  const AssetGroupScreen({
    super.key,
    required this.title,
    required this.records,
    required this.assetRecordStore,
    this.coverFor,
    this.dateOf = PhotoGridLayout.takenAt,
    this.notes,
    this.archive = false,
    this.travelStore,
  });

  /// See [DetailScreen.travelStore].
  final TravelStore? travelStore;

  /// This is the Archive: tiles and the detail toolbar offer Unarchive.
  final bool archive;

  /// A built-in album's notes, under its id; null for a place or People
  /// group, which has no lasting id to keep them under.
  final NoteBook? notes;

  /// See [PhotoGridLayout.dateOf].
  final DateTime Function(AssetRecord) dateOf;

  final String title;
  final List<AssetRecord> records;
  final AssetRecordStore assetRecordStore;

  /// Set when this screen *is* one of the built-in albums, which is what
  /// puts "Use as Cover" on its tiles. A place or People group has no
  /// card to be the cover of.
  final BuiltInAlbum? coverFor;

  @override
  State<AssetGroupScreen> createState() => _AssetGroupScreenState();
}

class _AssetGroupScreenState extends State<AssetGroupScreen> {
  late List<AssetRecord> _records = widget.records;

  // ------------------------------------------------------------- selection

  bool _selecting = false;
  final _picked = ValueNotifier<Set<String>>(const {});
  final _sweep = SelectSweep<String>();

  @override
  void dispose() {
    _picked.dispose();
    super.dispose();
  }

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
    final view = View.maybeOf(context);
    if (view == null) return;
    final result = HitTestResult();
    WidgetsBinding.instance.hitTestInView(result, globalPosition, view.viewId);
    for (final entry in result.path) {
      final target = entry.target;
      if (target is RenderMetaData && target.metaData is AssetRecord) {
        final next = _sweep.over(
          (target.metaData as AssetRecord).localId,
          _picked.value,
          () => [for (final r in _records) r.localId],
        );
        if (next != null) _picked.value = next;
        return;
      }
    }
  }

  List<AssetRecord> get _selectedRecords => [
    for (final r in _records)
      if (_picked.value.contains(r.localId)) r,
  ];

  void _drop(Set<String> ids) => setState(
    () => _records = [
      for (final r in _records)
        if (!ids.contains(r.localId)) r,
    ],
  );

  Future<void> _favoriteSelected() async {
    final picked = _selectedRecords;
    final value = !picked.every((r) => r.isFavorite);
    for (final r in picked) {
      await setFavoriteEverywhere(widget.assetRecordStore, r, value);
    }
    if (!mounted) return;
    setState(
      () => _records = [
        for (final r in _records)
          _picked.value.contains(r.localId) ? r.withFavorite(value) : r,
      ],
    );
    _endSelecting();
  }

  /// Archive, or out of it in the Archive itself.
  Future<void> _archiveSelected() async {
    final ids = _picked.value;
    await widget.assetRecordStore.setArchived(ids, !widget.archive);
    if (!mounted) return;
    _drop(ids);
    _endSelecting();
  }

  Future<void> _hideSelected() async {
    final picked = _selectedRecords;
    final hidden = await hideIntoPrivateAlbum(
      context,
      assetRecordStore: widget.assetRecordStore,
      records: picked,
    );
    if (!hidden || !mounted) return;
    _drop({for (final r in picked) r.localId});
    _endSelecting();
  }

  late final _library = PhotoLibraryService(store: widget.assetRecordStore);

  Future<void> _deleteSelected() async {
    final result = await binSelection(
      context,
      _selectedRecords,
      library: _library,
      removal: _removal,
    );
    if (result == null || !mounted) return;
    _drop(result.deleted);
    _endSelecting();
  }

  Future<void> _toggleFavorite(AssetRecord record) async {
    final value = !record.isFavorite;
    await setFavoriteEverywhere(widget.assetRecordStore, record, value);
    if (!mounted) return;
    setState(
      () => _records = [
        for (final r in _records)
          r.localId == record.localId ? r.withFavorite(value) : r,
      ],
    );
  }

  Future<void> _hide(AssetRecord record) async {
    final hidden = await hideIntoPrivateAlbum(
      context,
      assetRecordStore: widget.assetRecordStore,
      records: [record],
    );
    if (!hidden) return;
    setState(
      () => _records = _records
          .where((r) => r.localId != record.localId)
          .toList(),
    );
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
    if (!outcome.leftTheList || !mounted) return false;
    setState(
      () => _records = _records
          .where((r) => r.localId != record.localId)
          .toList(),
    );
    return true;
  }

  /// What the built-in card draws, if this screen is one. Held in state so
  /// picking a cover updates the action on the tiles without a round trip
  /// back through the library.
  String? _cover;
  bool _loadedCover = false;

  Future<void> _loadCover() async {
    final album = widget.coverFor;
    if (album == null || _loadedCover) return;
    _loadedCover = true;
    final chosen = await builtInAlbumCover(widget.assetRecordStore, album);
    if (mounted) setState(() => _cover = chosen);
  }

  Future<void> _setCover(String? localId) async {
    final album = widget.coverFor;
    if (album == null) return;
    await setBuiltInAlbumCover(widget.assetRecordStore, album, localId);
    if (mounted) setState(() => _cover = localId);
  }

  Future<void> _unarchive(AssetRecord record) async {
    await widget.assetRecordStore.setArchived([record.localId], false);
    if (!mounted) return;
    setState(
      () => _records = _records
          .where((r) => r.localId != record.localId)
          .toList(),
    );
  }

  /// Toggled in the detail view: the toolbar shows the new state at once,
  /// the grid catches up when it is closed.
  final _toggled = <String>{};

  Future<void> _toggleArchiveInDetail(AssetRecord record) async {
    await widget.assetRecordStore.setArchived([
      record.localId,
    ], !record.isArchived);
    if (!_toggled.remove(record.localId)) _toggled.add(record.localId);
  }

  Future<void> _open(AssetRecord record) async {
    await Navigator.of(context).push(
      ZoomPageRoute(
        builder: (_) => DetailScreen(
          records: _records,
          initialIndex: _records.indexOf(record),
          assetRecordStore: widget.assetRecordStore,
          onDelete: _delete,
          onToggleFavorite: _toggleFavorite,
          onToggleArchive: widget.archive ? _toggleArchiveInDetail : null,
          travelStore: widget.travelStore,
        ),
      ),
    );
    if (_toggled.isEmpty || !mounted) return;
    final gone = {..._toggled};
    _toggled.clear();
    setState(
      () =>
          _records = _records.where((r) => !gone.contains(r.localId)).toList(),
    );
  }

  @override
  void initState() {
    super.initState();
    unawaited(_loadCover());
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(widget.title),
        leading: _selecting
            ? ValueListenableBuilder(
                valueListenable: _picked,
                builder: (context, picked, _) => SelectAllButton(
                  total: _records.length,
                  selectedCount: picked.length,
                  onSelectNext: () => _picked.value = selectEverything(
                    _records.map((r) => r.localId),
                    picked,
                  ),
                  onDeselectAll: () => _picked.value = const {},
                ),
              )
            : null,
        trailing: _selecting
            ? SelectionDoneButton(
                key: const ValueKey('groupSelectionDone'),
                onPressed: _endSelecting,
              )
            : _records.isEmpty
            ? null
            : CupertinoButton(
                key: const ValueKey('groupSelect'),
                padding: EdgeInsets.zero,
                onPressed: () => setState(() => _selecting = true),
                child: Text(l10n.albumSelect),
              ),
      ),
      child: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(child: _grid(l10n)),
            if (_selecting)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: ValueListenableBuilder(
                  valueListenable: _picked,
                  builder: (context, picked, _) => _GroupSelectionBar(
                    count: picked.length,
                    archive: widget.archive,
                    onFavorite: _favoriteSelected,
                    onArchive: _archiveSelected,
                    onHide: _hideSelected,
                    onDelete: _deleteSelected,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _grid(AppLocalizations l10n) => AssetGridView(
    records: _records,
    dateOf: widget.dateOf,
    onTap: _selecting ? _toggleSelected : _open,
    onLongPress: _startSelecting,
    onSelectDragUpdate: _onSelectDragUpdate,
    onSelectDragEnd: _sweep.end,
    selection: _selecting ? _picked : null,
    trailingSlivers: [
      if (widget.notes case final notes?)
        SliverToBoxAdapter(child: AlbumNotes(book: notes)),
      if (_selecting) const SliverToBoxAdapter(child: SizedBox(height: 110)),
    ],
    actionsFor: (r) => [
      TileAction(
        icon: r.isFavorite ? CupertinoIcons.heart_slash : CupertinoIcons.heart,
        label: r.isFavorite ? l10n.libraryUnfavorite : l10n.libraryFavorite,
        onPressed: () => _toggleFavorite(r),
      ),
      if (widget.archive)
        TileAction(
          icon: CupertinoIcons.archivebox,
          label: l10n.archiveUndoAction,
          onPressed: () => _unarchive(r),
        ),
      ...coverActions(
        l10n,
        isCover: widget.coverFor != null && _cover == r.localId,
        enabled: widget.coverFor != null,
        onUse: () => _setCover(r.localId),
        onDefault: () => _setCover(null),
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

class _GroupSelectionBar extends StatelessWidget {
  const _GroupSelectionBar({
    required this.count,
    required this.archive,
    required this.onFavorite,
    required this.onArchive,
    required this.onHide,
    required this.onDelete,
  });

  final int count;
  final bool archive;
  final VoidCallback onFavorite;
  final VoidCallback onArchive;
  final VoidCallback onHide;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    Widget action(IconData icon, String label, VoidCallback on, String key) =>
        Expanded(
          child: CupertinoButton(
            key: ValueKey(key),
            padding: const EdgeInsets.symmetric(vertical: 8),
            onPressed: count == 0 ? null : on,
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
        color: CupertinoColors.systemBackground.resolveFrom(context),
        border: Border(
          top: BorderSide(
            color: CupertinoColors.separator.resolveFrom(context),
          ),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                count == 0 ? l10n.selectionHint : l10n.selectionTitle(count),
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          ),
          Row(
            children: [
              action(
                CupertinoIcons.heart,
                l10n.libraryFavorite,
                onFavorite,
                'groupFavoriteSelected',
              ),
              action(
                CupertinoIcons.archivebox,
                archive ? l10n.archiveUndoAction : l10n.archiveAction,
                onArchive,
                'groupArchiveSelected',
              ),
              action(
                CupertinoIcons.eye_slash,
                l10n.libraryHide,
                onHide,
                'groupHideSelected',
              ),
              action(
                CupertinoIcons.delete,
                l10n.selectionDelete,
                onDelete,
                'groupDeleteSelected',
              ),
            ],
          ),
        ],
      ),
    );
  }
}
