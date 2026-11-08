import 'package:flutter/cupertino.dart';

import '../l10n/app_localizations.dart';
import '../photos/ai_analysis_store.dart';
import '../photos/asset_removal.dart';
import '../photos/face_analyzer.dart';
import '../photos/face_import.dart';
import '../photos/person.dart' show FaceRect;
import '../photos/person_store.dart';
import '../photos/photo_library_service.dart';
import '../settings/settings_section.dart';
import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import 'asset_grid.dart';
import 'back_swipe_edge.dart';
import 'delete_confirmation.dart';
import 'person_avatar.dart';
import 'person_picker_sheet.dart';

typedef _Face = ({String localId, FaceRect face});

/// One imported group's faces (see
/// `docs/design/face-recognition/MAC-PIPELINE.md`), all ticked: tap leaves one out, touch and hold opens
/// its photo. Name the ticked ones, take them out of the group, ignore
/// them, or delete their photos. Faces or whole photos, one selection.
/// With [ignored], an ignored group: its faces, Stop Ignoring, and Name;
/// a person made here stays ignored.
class ImportedGroupScreen extends StatefulWidget {
  const ImportedGroupScreen({
    super.key,
    required this.group,
    required this.records,
    required this.analysisStore,
    required this.assetRecordStore,
    required this.personStore,
    this.onOpenAsset,
    this.onLeft,
    this.ignored = false,
    this.photoLibraryService,
  });

  final PhotoLibraryService? photoLibraryService;

  final bool ignored;

  final StoredFaceGroup group;

  /// See [PersonAvatar.records]: every tile resolves with no query.
  final Map<String, AssetRecord> records;
  final AiAnalysisStore analysisStore;
  final AssetRecordStore assetRecordStore;
  final PersonStore personStore;
  final Future<void> Function(String localId)? onOpenAsset;

  /// The faces still unnamed here, after every change: the list behind
  /// updates at once instead of after a full reload.
  final ValueChanged<List<({String localId, FaceRect face})>>? onLeft;

  @override
  State<ImportedGroupScreen> createState() => _ImportedGroupScreenState();
}

class _ImportedGroupScreenState extends State<ImportedGroupScreen> {
  late List<_Face> _faces = widget.group.faces;

  /// Indexes left out; empty is everything ticked.
  final _off = <int>{};
  bool _busy = false;
  String? _note;

  /// Whole photos instead of face crops, with a select mode of its own:
  /// nothing picked to start, for deleting a few or all.
  bool _asPhotos = false;
  final _picked = <_Face>{};

  late final _library =
      widget.photoLibraryService ??
      PhotoLibraryService(store: widget.assetRecordStore);
  late final _removal = AssetRemoval(store: widget.assetRecordStore);

  /// [faces]' photos to Recently Deleted; they leave this page.
  Future<void> _deletePhotos(List<_Face> faces) async {
    final ticked = faces;
    if (_busy || ticked.isEmpty) return;
    final l10n = AppLocalizations.of(context)!;
    final records = [
      for (final id in {for (final f in ticked) f.localId}) ?widget.records[id],
    ];
    setState(() {
      _busy = true;
      _undo = null;
    });
    try {
      final result = await binSelection(
        context,
        records,
        library: _library,
        removal: _removal,
      );
      if (result == null || !mounted) return;
      if (result.allLocked) {
        setState(() => _note = l10n.lockBlockedDelete);
        return;
      }
      final off = {for (final i in _off) _faces[i]};
      final rest = [
        for (final f in _faces)
          if (!result.deleted.contains(f.localId)) f,
      ];
      widget.onLeft?.call(rest);
      if (rest.isEmpty) {
        Navigator.of(context).pop();
        return;
      }
      setState(() {
        _faces = rest;
        _picked.removeWhere((f) => result.deleted.contains(f.localId));
        _off
          ..clear()
          ..addAll([
            for (final (i, f) in rest.indexed)
              if (off.contains(f)) i,
          ]);
        _note = result.kept > 0
            ? l10n.libraryDeleteKeptByPhotos(result.kept)
            : null;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _photoTile(int i, double extent) {
    final f = _faces[i];
    final record = widget.records[f.localId];
    if (record == null) return const SizedBox.shrink();
    void toggle() => setState(
      () => _picked.contains(f) ? _picked.remove(f) : _picked.add(f),
    );
    final open = widget.onOpenAsset == null
        ? null
        : () => widget.onOpenAsset!(f.localId);
    return MetaData(
      metaData: EdgeTap(toggle, open),
      child: AssetTile(
        key: ValueKey('photo|${f.localId}|${f.face.encode()}'),
        record: record,
        extent: extent,
        cornerColor: settingsPageBackground,
        selected: _picked.contains(f),
        onTap: toggle,
        onLongPress: open,
      ),
    );
  }

  /// The last naming, until the next action: Undo takes it back.
  ({String personId, List<_Face> faces})? _undo;

  List<_Face> get _ticked => [
    for (final (i, f) in _faces.indexed)
      if (!_off.contains(i)) f,
  ];

  void _toggle(int i) =>
      setState(() => _off.contains(i) ? _off.remove(i) : _off.add(i));

  void _toggleAll() => setState(() {
    if (_off.isEmpty) {
      _off.addAll(List.generate(_faces.length, (i) => i));
    } else {
      _off.clear();
    }
  });

  /// What's left once the ticked faces are dealt with. None left closes,
  /// unless they were named: the page stays to offer Undo.
  void _keepUnticked(String? note) {
    final rest = [
      for (final (i, f) in _faces.indexed)
        if (_off.contains(i)) f,
    ];
    widget.onLeft?.call(rest);
    if (rest.isEmpty && _undo == null) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _faces = rest;
      _off.clear();
      _note = note;
    });
  }

  FaceImport get _import => FaceImport(
    personStore: widget.personStore,
    assetRecordStore: widget.assetRecordStore,
    analysisStore: widget.analysisStore,
    analyzer: FaceAnalyzer.shared,
  );

  Future<void> _takeBack() async {
    final undo = _undo;
    if (_busy || undo == null) return;
    setState(() => _busy = true);
    try {
      await _import.unname(undo.personId, widget.group.id, undo.faces);
      if (!mounted) return;
      widget.onLeft?.call([...undo.faces, ..._faces]);
      setState(() {
        _faces = [...undo.faces, ..._faces];
        _off.clear();
        _note = null;
        _undo = null;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _name() async {
    final ticked = _ticked;
    if (_busy || ticked.isEmpty) return;
    final l10n = AppLocalizations.of(context)!;
    final candidates = await widget.personStore.listAll();
    if (!mounted) return;
    final person = await showPersonPickerSheet(
      context: context,
      candidates: candidates,
      personStore: widget.personStore,
      title: l10n.faceGroupsPickTitle,
      initialQuery: widget.group.suggest,
    );
    if (person == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final isNew = !candidates.any((c) => c.id == person.id);
      if (widget.ignored && isNew) {
        await widget.personStore.update(person.copyWith(ignored: true));
      }
      final named = await _import.name(person.id, ticked);
      if (!mounted) return;
      _undo = (personId: person.id, faces: named);
      _keepUnticked(l10n.faceGroupsNamed(named.length, person.name));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _notThisGroup() async {
    final ticked = _ticked;
    if (_busy || ticked.isEmpty) return;
    setState(() {
      _busy = true;
      _undo = null;
    });
    try {
      await widget.analysisStore.ungroupFaces(ticked);
      if (mounted) _keepUnticked(null);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Ticked faces stop being asked about; all of them ignores the group.
  Future<void> _ignore() async {
    final ticked = _ticked;
    if (_busy || ticked.isEmpty) return;
    final l10n = AppLocalizations.of(context)!;
    setState(() {
      _busy = true;
      _undo = null;
    });
    try {
      if (ticked.length == _faces.length) {
        await widget.analysisStore.ignoreGroup(widget.group.id);
      } else {
        await widget.analysisStore.ignoreFaces(widget.group, ticked);
      }
      if (mounted) _keepUnticked(l10n.faceGroupsIgnoredNote(ticked.length));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _unignore() async {
    if (_busy) return;
    setState(() => _busy = true);
    await widget.analysisStore.ignoreGroup(widget.group.id, ignored: false);
    widget.onLeft?.call(const []);
    if (mounted) Navigator.of(context).pop();
  }

  /// Every face named: what was done, Undo, and the way out.
  Widget _finished(AppLocalizations l10n) => CupertinoPageScaffold(
    backgroundColor: settingsPageBackground,
    navigationBar: CupertinoNavigationBar(
      backgroundColor: settingsPageBackground,
      middle: Text(widget.group.suggest ?? l10n.faceGroupsUnnamed),
    ),
    child: SafeArea(
      child: Column(
        children: [
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      CupertinoIcons.check_mark_circled,
                      size: 56,
                      color: settingsAccent,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      _note ?? '',
                      key: const ValueKey('faceGroupDoneNote'),
                      textAlign: TextAlign.center,
                    ),
                    if (_undo != null)
                      CupertinoButton(
                        key: const ValueKey('faceGroupUndo'),
                        onPressed: _busy ? null : _takeBack,
                        child: Text(l10n.faceGroupsUndo),
                      ),
                  ],
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: SizedBox(
              width: double.infinity,
              child: CupertinoButton.filled(
                key: const ValueKey('faceGroupDone'),
                onPressed: _busy ? null : () => Navigator.of(context).pop(),
                child: Text(l10n.actionDone),
              ),
            ),
          ),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final ticked = _faces.length - _off.length;
    if (_faces.isEmpty) return _finished(l10n);
    return CupertinoPageScaffold(
      backgroundColor: settingsPageBackground,
      navigationBar: CupertinoNavigationBar(
        backgroundColor: settingsPageBackground,
        middle: Text(widget.group.suggest ?? l10n.faceGroupsUnnamed),
        trailing: widget.ignored
            ? null
            : CupertinoButton(
                key: const ValueKey('faceGroupIgnore'),
                padding: EdgeInsets.zero,
                onPressed: _busy || ticked == 0 ? null : _ignore,
                child: Text(l10n.faceGroupsIgnore),
              ),
      ),
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: SizedBox(
                width: double.infinity,
                child: CupertinoSlidingSegmentedControl<bool>(
                  key: const ValueKey('faceGroupView'),
                  groupValue: _asPhotos,
                  onValueChanged: (v) => setState(() {
                    _asPhotos = v ?? false;
                    _picked.clear();
                  }),
                  children: {
                    false: Text(l10n.faceGroupsViewFaces),
                    true: Text(l10n.faceGroupsViewPhotos),
                  },
                ),
              ),
            ),
            if (_asPhotos)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _picked.isEmpty
                            ? l10n.faceGroupsPhotosHint
                            : l10n.selectionTitle(_picked.length),
                        style: settingsHintStyle,
                      ),
                    ),
                    CupertinoButton(
                      key: const ValueKey('faceGroupPhotosAll'),
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: Size.zero,
                      onPressed: () => setState(() {
                        if (_picked.length == _faces.length) {
                          _picked.clear();
                        } else {
                          _picked.addAll(_faces);
                        }
                      }),
                      child: Text(
                        _picked.length == _faces.length
                            ? l10n.selectionDeselectAll
                            : l10n.selectionSelectAll,
                        style: const TextStyle(
                          fontSize: 13,
                          color: settingsAccent,
                        ),
                      ),
                    ),
                  ],
                ),
              )
            else if (!widget.ignored)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _note ?? l10n.faceGroupsSelected(ticked, _faces.length),
                        style: settingsHintStyle,
                      ),
                    ),
                    if (_undo != null)
                      CupertinoButton(
                        key: const ValueKey('faceGroupUndo'),
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        minimumSize: Size.zero,
                        onPressed: _busy ? null : _takeBack,
                        child: Text(
                          l10n.faceGroupsUndo,
                          style: const TextStyle(
                            fontSize: 13,
                            color: settingsAccent,
                          ),
                        ),
                      ),
                    CupertinoButton(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: Size.zero,
                      onPressed: _toggleAll,
                      child: Text(
                        _off.isEmpty
                            ? l10n.faceGroupsSelectNone
                            : l10n.faceGroupsSelectAll,
                        style: const TextStyle(
                          fontSize: 13,
                          color: settingsAccent,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            if (_asPhotos)
              Expanded(
                child: backSwipeTiles(
                  child: LayoutBuilder(
                    builder: (context, box) {
                      final across = (box.maxWidth / 120).ceil().clamp(3, 8);
                      final extent = (box.maxWidth - (across - 1) * 2) / across;
                      return GridView.builder(
                        key: const ValueKey('faceGroupPhotos'),
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: across,
                          mainAxisSpacing: 2,
                          crossAxisSpacing: 2,
                        ),
                        itemCount: _faces.length,
                        itemBuilder: (context, i) => _photoTile(i, extent),
                      );
                    },
                  ),
                ),
              )
            else
              Expanded(
                child: backSwipeTiles(
                  child: GridView.builder(
                    padding: const EdgeInsets.all(8),
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 88,
                          mainAxisSpacing: 8,
                          crossAxisSpacing: 8,
                        ),
                    itemCount: _faces.length,
                    itemBuilder: (context, i) {
                      final f = _faces[i];
                      final tap = widget.ignored
                          ? () => widget.onOpenAsset?.call(f.localId)
                          : () => _toggle(i);
                      final hold = widget.onOpenAsset == null
                          ? null
                          : () => widget.onOpenAsset!(f.localId);
                      return MetaData(
                        metaData: EdgeTap(tap, hold),
                        child: _FaceTile(
                          key: ValueKey('${f.localId}|${f.face.encode()}'),
                          face: f,
                          on: widget.ignored || !_off.contains(i),
                          tick: !widget.ignored,
                          records: widget.records,
                          assetRecordStore: widget.assetRecordStore,
                          onTap: tap,
                          onLongPress: hold,
                        ),
                      );
                    },
                  ),
                ),
              ),
            if (_asPhotos)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: SizedBox(
                  width: double.infinity,
                  child: CupertinoButton(
                    key: const ValueKey('faceGroupDeletePicked'),
                    color: settingsControlFill,
                    onPressed: _busy || _picked.isEmpty
                        ? null
                        : () => _deletePhotos([
                            for (final f in _faces)
                              if (_picked.contains(f)) f,
                          ]),
                    child: Text(
                      _picked.isEmpty
                          ? l10n.selectionDelete
                          : l10n.selectionDeleteAction(
                              {for (final f in _picked) f.localId}.length,
                            ),
                      style: const TextStyle(color: CupertinoColors.systemRed),
                    ),
                  ),
                ),
              )
            else if (widget.ignored)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: CupertinoButton(
                        key: const ValueKey('faceGroupUnignore'),
                        color: settingsControlFill,
                        onPressed: _busy ? null : _unignore,
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(l10n.faceGroupsUnignore, maxLines: 1),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: CupertinoButton.filled(
                        key: const ValueKey('faceGroupName'),
                        onPressed: _busy ? null : _name,
                        child: Text(l10n.faceGroupsName),
                      ),
                    ),
                  ],
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Row(
                  children: [
                    CupertinoButton(
                      key: const ValueKey('faceGroupDeletePhotos'),
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      color: settingsControlFill,
                      onPressed: _busy || ticked == 0
                          ? null
                          : () => _deletePhotos(_ticked),
                      child: const Icon(
                        CupertinoIcons.trash,
                        color: CupertinoColors.systemRed,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: CupertinoButton(
                        key: const ValueKey('faceGroupNotThis'),
                        color: settingsControlFill,
                        onPressed: _busy || ticked == 0 ? null : _notThisGroup,
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(l10n.faceGroupsNotThis, maxLines: 1),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: CupertinoButton.filled(
                        key: const ValueKey('faceGroupName'),
                        onPressed: _busy || ticked == 0 ? null : _name,
                        child: Text(l10n.faceGroupsName),
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

class _FaceTile extends StatelessWidget {
  const _FaceTile({
    super.key,
    required this.face,
    required this.on,
    this.tick = true,
    required this.records,
    required this.assetRecordStore,
    required this.onTap,
    this.onLongPress,
  });

  final _Face face;
  final bool on;
  final bool tick;
  final Map<String, AssetRecord> records;
  final AssetRecordStore assetRecordStore;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    onLongPress: onLongPress,
    child: LayoutBuilder(
      builder: (context, box) => Stack(
        children: [
          Opacity(
            opacity: on ? 1 : 0.35,
            child: PersonAvatar(
              assetRecordStore: assetRecordStore,
              localId: face.localId,
              face: face.face,
              records: records,
              size: box.maxWidth,
            ),
          ),
          if (tick)
            Positioned(
              right: 2,
              bottom: 2,
              child: Icon(
                on
                    ? CupertinoIcons.checkmark_circle_fill
                    : CupertinoIcons.circle,
                size: 22,
                color: on ? settingsAccent : CupertinoColors.systemGrey,
              ),
            ),
        ],
      ),
    ),
  );
}
