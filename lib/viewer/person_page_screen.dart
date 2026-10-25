import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/rendering.dart';

import '../l10n/app_localizations.dart';
import '../photos/library_metadata.dart';
import '../photos/person.dart';
import '../photos/ai_analysis_store.dart';
import '../photos/face_identity.dart';
import '../photos/person_store.dart';
import '../photos/alias_folders.dart';
import '../photos/asset_removal.dart';
import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import 'asset_grid.dart';
import 'asset_grid_view.dart';
import 'asset_picker_screen.dart';
import 'delete_confirmation.dart';
import 'detail_screen.dart';
import 'person_avatar.dart';
import 'person_picker_sheet.dart';
import 'person_profile_screen.dart';
import 'private_album_gate.dart';
import 'private_album_screen.dart' show PrivateAlbumScreen;
import 'select_all.dart';
import 'select_sweep.dart';
import 'zoom_page_route.dart';

/// One person's page: avatar, name (the whole name line opens the full
/// editable profile), and their tagged photos. See DESIGN.md's "People
/// profiles" section and IMPLEMENTATION_PLAN.md T7.3.
class PersonPageScreen extends StatefulWidget {
  /// The name-and-chevron line, which opens the profile.
  static const nameLineKey = Key('personNameLine');

  const PersonPageScreen({
    super.key,
    required this.person,
    required this.personStore,
    required this.assetRecordStore,
    this.aiAnalysisStore,
    this.faceIdentity,
  });

  final Person person;
  final PersonStore personStore;
  final AssetRecordStore assetRecordStore;

  /// Where a confirmed face is looked up when picking a profile photo.
  /// Absent, one is opened on demand — see [faceOfPersonIn].
  final AiAnalysisStore? aiAnalysisStore;

  /// The library's own, so Find More shares its database and matcher;
  /// absent, one is made for the page.
  final FaceIdentityService? faceIdentity;

  @override
  State<PersonPageScreen> createState() => _PersonPageScreenState();
}

class _PersonPageScreenState extends State<PersonPageScreen> {
  late Person _person = widget.person;
  List<AssetRecord> _records = const [];

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _picked.dispose();
    super.dispose();
  }

  /// Select mode is on; [_picked] is what the bar acts on.
  bool _selecting = false;
  final _picked = ValueNotifier<Set<String>>(const {});
  final _sweep = SelectSweep<String>();

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

  /// The tile under the finger: each carries its record in a `MetaData`
  /// (see `AssetTile`).
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

  /// Into this person's own hidden folder, not a general one: the code
  /// typed is turned into theirs ([personAlbumCode]).
  Future<void> _hideSelected() async {
    final records = _selectedRecords;
    if (records.isEmpty) return;
    final hidden = await hideIntoPrivateAlbum(
      context,
      assetRecordStore: widget.assetRecordStore,
      records: records,
      codeFor: (digits) => personAlbumCode(_person.id, digits),
      onSettled: () {
        if (mounted) _reload();
      },
    );
    if (!mounted) return;
    if (hidden) _endSelecting();
    await _reload();
  }

  /// To someone else: off this person, onto them, faces and all.
  Future<void> _moveSelected() async {
    final l10n = AppLocalizations.of(context)!;
    final ids = _picked.value.toList();
    if (ids.isEmpty) return;
    final others = [
      for (final p in await widget.personStore.listAll())
        if (p.id != _person.id) p,
    ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    if (!mounted) return;
    final to = await showPersonPickerSheet(
      context: context,
      candidates: others,
      personStore: widget.personStore,
      title: l10n.personMoveTo,
      autofocus: false,
    );
    if (to == null || to.id == _person.id) return;
    await widget.personStore.addAssets(to.id, ids);
    await widget.personStore.removeAssets(_person.id, ids);
    try {
      await _identity.analysisStore.movePersonOn(_person.id, to.id, ids);
    } catch (_) {}
    _endSelecting();
    await _reload();
  }

  Future<void> _removeSelected() async {
    final ids = _picked.value.toList();
    if (ids.isEmpty) return;
    await widget.personStore.removeAssets(_person.id, ids);
    await _identity.unrememberPhotos(_person.id, ids);
    _endSelecting();
    await _reload();
  }

  /// Into the main library: out of Archive, and no longer only theirs.
  Future<void> _toLibrarySelected() async {
    final ids = [
      for (final r in _selectedRecords)
        if (r.isArchived) r.localId,
    ];
    if (ids.isNotEmpty) await widget.assetRecordStore.setArchived(ids, false);
    _endSelecting();
    await _reload();
  }

  Future<void> _favoriteSelected() async {
    final records = _selectedRecords;
    final value = !records.every((r) => r.isFavorite);
    for (final r in records) {
      if (r.isFavorite != value) {
        await setFavoriteEverywhere(widget.assetRecordStore, r, value);
      }
    }
    _endSelecting();
    await _reload();
  }

  Future<void> _hide(AssetRecord record) async {
    await hideIntoPrivateAlbum(
      context,
      assetRecordStore: widget.assetRecordStore,
      records: [record],
      codeFor: (digits) => personAlbumCode(_person.id, digits),
      onSettled: () {
        if (mounted) _reload();
      },
    );
    await _reload();
  }

  Future<void> _reload() async {
    final ids = await widget.personStore.localIdsIn(_person.id);
    // From the library's cache: no rows, no file checks.
    final members = await widget.assetRecordStore.listOf(ids);
    if (!mounted) return;
    setState(
      () => _records = [
        for (final r in members)
          if (r.isVisibleInLibrary) r,
      ],
    );
  }

  Future<void> _openProfile() async {
    await Navigator.of(context).push(
      CupertinoPageRoute(
        builder: (_) => PersonProfileScreen(
          person: _person,
          personStore: widget.personStore,
          assetRecordStore: widget.assetRecordStore,
        ),
      ),
    );
    if (!mounted) return;
    // The profile screen persists edits as they're made rather than
    // returning a value — re-fetch, and if it deleted the person, pop this
    // page too (nothing left here to show).
    final refreshed = await widget.personStore.getById(_person.id);
    if (refreshed == null) {
      if (mounted) Navigator.of(context).pop();
      return;
    }
    setState(() => _person = refreshed);
    await _reload();
  }

  Future<void> _addPhotos() async {
    final l10n = AppLocalizations.of(context)!;
    final picked = await Navigator.of(context).push<List<AssetRecord>>(
      CupertinoPageRoute(
        builder: (_) => AssetPickerScreen(
          title: l10n.personPageAddPhotos,
          assetRecordStore: widget.assetRecordStore,
          excludeIds: _records.map((r) => r.localId).toSet(),
        ),
      ),
    );
    if (picked == null || picked.isEmpty) return;
    await widget.personStore.addAssets(
      _person.id,
      picked.map((r) => r.localId),
    );
    // Linking a photo is also where somebody with no picture gets one, and
    // the store does that itself — read back rather than second-guess it.
    final refreshed = await widget.personStore.getById(_person.id);
    if (refreshed != null) _person = refreshed;
    await _reload();
  }

  /// Their picture, cropped to nothing in particular: a photo picked whole
  /// carries no face box, so any one left over from a face tapped in a
  /// different photo has to go with it.
  /// Their face in that photo, not the whole photo. It used to write
  /// `avatarFace: null` outright, so picking a picture of two people on a
  /// beach made the beach their portrait.
  Future<void> _setProfilePhoto(AssetRecord record) async {
    final face = await faceOfPersonIn(
      record.localId,
      _person.id,
      analysisStore: widget.aiAnalysisStore,
    );
    await widget.personStore.update(
      _person.copyWith(avatarLocalId: record.localId, avatarFace: () => face),
    );
    // Read back rather than trusting the copy in hand: if the write
    // didn't land, the header should show that instead of the value we
    // hoped for.
    final saved = await widget.personStore.getById(_person.id);
    if (!mounted || saved == null) return;
    setState(() => _person = saved);
  }

  late final FaceIdentityService _identity =
      widget.faceIdentity ??
      FaceIdentityService(
        analysisStore: widget.aiAnalysisStore ?? AiAnalysisStore(),
        onSeen: widget.personStore.markSeen,
      );

  Future<void> _removeFromPerson(AssetRecord record) async {
    await widget.personStore.removeAsset(_person.id, record.localId);
    await _identity.unrememberPhotos(_person.id, [record.localId]);
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
          onDelete: _delete,
          onToggleFavorite: _toggleFavorite,
          assetRecordStore: widget.assetRecordStore,
          personStore: widget.personStore,
        ),
      ),
    );
  }

  Future<void> _showMenu() async {
    final l10n = AppLocalizations.of(context)!;
    final choice = await showCupertinoModalPopup<VoidCallback>(
      context: context,
      builder: (sheetContext) => CupertinoActionSheet(
        actions: [
          CupertinoActionSheetAction(
            onPressed: () => Navigator.of(sheetContext).pop(_addPhotos),
            child: Text(l10n.personPageAddPhotos),
          ),
          CupertinoActionSheetAction(
            onPressed: () => Navigator.of(sheetContext).pop(_openHidden),
            child: Text(l10n.personPageHidden),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(sheetContext).pop(),
          child: Text(l10n.actionCancel),
        ),
      ),
    );
    choice?.call();
  }

  /// This person's own hidden folder — see [personAlbumCode]. Photos go in
  /// by hand only, never by face recognition, and they show nowhere else.
  /// Folders of people merged into them, under the same digits, join it.
  Future<void> _openHidden() => openPrivateAlbums(
    context,
    assetRecordStore: widget.assetRecordStore,
    codeFor: (digits) => personAlbumCode(_person.id, digits),
    beforeOpen: (digits, keys) async {
      final aliases = await widget.personStore.aliasesOf(_person.id);
      if (aliases.isEmpty) return const [];
      try {
        final left = await AliasFolders(
          store: widget.assetRecordStore,
          vaultKeys: keys,
        ).fold(_person.id, aliases, digits);
        unawaited(PrivateAlbumScreen.hiddenBackup?.run());
        return left;
      } catch (_) {
        // Not folded this time: each alias folder opens on its own.
        return [for (final a in aliases) personAlbumCode(a, digits)];
      }
    },
    title: AppLocalizations.of(context)!.personPageHiddenTitle(_person.name),
  );

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(_person.name),
        leading: _selecting
            ? ValueListenableBuilder(
                valueListenable: _picked,
                builder: (context, picked, _) => SelectAllButton(
                  unlimited: true,
                  total: _records.length,
                  selectedCount: picked.length,
                  onSelectNext: () =>
                      _picked.value = {for (final r in _records) r.localId},
                  onDeselectAll: () => _picked.value = const {},
                ),
              )
            : null,
        trailing: _selecting
            ? SelectionDoneButton(
                key: const ValueKey('personSelectionDone'),
                onPressed: _endSelecting,
              )
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_records.isNotEmpty)
                    CupertinoButton(
                      key: const ValueKey('personPageSelect'),
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      onPressed: () => setState(() => _selecting = true),
                      child: Text(l10n.albumSelect),
                    ),
                  CupertinoButton(
                    key: const ValueKey('personPageMenu'),
                    padding: EdgeInsets.zero,
                    onPressed: _showMenu,
                    child: const Icon(CupertinoIcons.ellipsis_circle),
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
                  builder: (context, picked, _) => _PersonSelectionBar(
                    count: picked.length,
                    onHide: _hideSelected,
                    onRemove: _removeSelected,
                    onFavorite: _favoriteSelected,
                    onToLibrary: _toLibrarySelected,
                    onMove: _moveSelected,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _body(AppLocalizations l10n) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Column(
            children: [
              PersonAvatar.forPerson(
                assetRecordStore: widget.assetRecordStore,
                person: _person,
                firstTaggedLocalId: _records.firstOrNull?.localId,
                size: 88,
              ),
              const SizedBox(height: 8),
              // The whole line, not the glyphs on it: a bare
              // `GestureDetector` around a min-width Row is only
              // hit-testable where something is painted, so the gaps
              // between the letters — and most of the line — did
              // nothing, leaving the chevron looking like the only
              // target.
              GestureDetector(
                key: PersonPageScreen.nameLineKey,
                behavior: HitTestBehavior.opaque,
                onTap: _openProfile,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Flexible(
                        child: Text(
                          _person.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      const Icon(
                        CupertinoIcons.chevron_forward,
                        size: 18,
                        color: CupertinoColors.systemGrey,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: _records.isEmpty
              ? Center(
                  child: Text(
                    l10n.personPagePhotosEmpty,
                    style: const TextStyle(color: CupertinoColors.systemGrey),
                  ),
                )
              : AssetGridView(
                  records: _records,
                  onTap: _selecting ? _toggleSelected : _open,
                  // Hold still opens the menu; sweeping is for select mode.
                  onSelectDragUpdate: _selecting ? _onSelectDragUpdate : null,
                  onSelectDragEnd: _selecting ? _sweep.end : null,
                  selection: _selecting ? _picked : null,
                  trailingSlivers: [
                    // Clear of the selection bar.
                    if (_selecting)
                      const SliverToBoxAdapter(child: SizedBox(height: 120)),
                  ],
                  actionsFor: (r) => [
                    TileAction(
                      icon: CupertinoIcons.checkmark_circle,
                      label: l10n.albumSelect,
                      onPressed: () => setState(() {
                        _selecting = true;
                        _picked.value = {r.localId};
                      }),
                    ),
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
                      icon: CupertinoIcons.person_crop_circle,
                      label: l10n.personPageUseAsProfilePhoto,
                      onPressed: () => _setProfilePhoto(r),
                    ),
                    TileAction(
                      icon: CupertinoIcons.person_badge_minus,
                      label: l10n.personPageRemoveFromPerson,
                      onPressed: () => _removeFromPerson(r),
                    ),
                    TileAction(
                      icon: CupertinoIcons.eye_slash,
                      label: l10n.personPageHideUnder,
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
      ],
    );
  }
}

class _PersonSelectionBar extends StatelessWidget {
  const _PersonSelectionBar({
    required this.count,
    required this.onHide,
    required this.onRemove,
    required this.onFavorite,
    required this.onToLibrary,
    required this.onMove,
  });

  final int count;
  final VoidCallback onHide;
  final VoidCallback onRemove;
  final VoidCallback onFavorite;
  final VoidCallback onToLibrary;
  final VoidCallback onMove;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    Widget action(
      IconData icon,
      String label,
      VoidCallback onPressed,
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
                        ? l10n.personPageSelectHint
                        : l10n.selectionTitle(count),
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
          Row(
            children: [
              action(
                CupertinoIcons.eye_slash,
                l10n.personPageHideUnder,
                onHide,
                const ValueKey('personHideSelected'),
              ),
              action(
                CupertinoIcons.person_badge_minus,
                l10n.personPageRemoveFromPerson,
                onRemove,
                const ValueKey('personRemoveSelected'),
              ),
              action(
                CupertinoIcons.heart,
                l10n.libraryFavorite,
                onFavorite,
                const ValueKey('personFavoriteSelected'),
              ),
              action(
                CupertinoIcons.photo_on_rectangle,
                l10n.personToLibrary,
                onToLibrary,
                const ValueKey('personToLibrarySelected'),
              ),
              action(
                CupertinoIcons.arrow_right_arrow_left,
                l10n.personMoveTo,
                onMove,
                const ValueKey('personMoveSelected'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
