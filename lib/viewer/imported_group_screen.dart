import 'package:flutter/cupertino.dart';

import '../l10n/app_localizations.dart';
import '../photos/ai_analysis_store.dart';
import '../photos/face_analyzer.dart';
import '../photos/face_import.dart';
import '../photos/person.dart' show FaceRect;
import '../photos/person_store.dart';
import '../settings/settings_section.dart';
import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import 'person_avatar.dart';
import 'person_picker_sheet.dart';

typedef _Face = ({String localId, FaceRect face});

/// One imported group's faces (see
/// `docs/design/face-recognition/MAC-PIPELINE.md`), all ticked: tap leaves one out, touch and hold opens
/// its photo. Name the ticked ones, or take them out of the group.
class ImportedGroupScreen extends StatefulWidget {
  const ImportedGroupScreen({
    super.key,
    required this.group,
    required this.records,
    required this.analysisStore,
    required this.assetRecordStore,
    required this.personStore,
    this.onOpenAsset,
  });

  final StoredFaceGroup group;

  /// See [PersonAvatar.records]: every tile resolves with no query.
  final Map<String, AssetRecord> records;
  final AiAnalysisStore analysisStore;
  final AssetRecordStore assetRecordStore;
  final PersonStore personStore;
  final Future<void> Function(String localId)? onOpenAsset;

  @override
  State<ImportedGroupScreen> createState() => _ImportedGroupScreenState();
}

class _ImportedGroupScreenState extends State<ImportedGroupScreen> {
  late List<_Face> _faces = widget.group.faces;

  /// Indexes left out; empty is everything ticked.
  final _off = <int>{};
  bool _busy = false;
  String? _note;

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

  Future<void> _delete() async {
    final l10n = AppLocalizations.of(context)!;
    final yes = await showCupertinoModalPopup<bool>(
      context: context,
      builder: (sheet) => CupertinoActionSheet(
        message: Text(l10n.faceGroupsDeleteConfirm),
        actions: [
          CupertinoActionSheetAction(
            key: const ValueKey('faceGroupDeleteConfirm'),
            isDestructiveAction: true,
            onPressed: () => Navigator.of(sheet).pop(true),
            child: Text(l10n.faceGroupsDelete),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(sheet).pop(false),
          child: Text(l10n.actionCancel),
        ),
      ),
    );
    if (yes != true || !mounted) return;
    await widget.analysisStore.dismissGroup(widget.group.id);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final ticked = _faces.length - _off.length;
    return CupertinoPageScaffold(
      backgroundColor: settingsPageBackground,
      navigationBar: CupertinoNavigationBar(
        backgroundColor: settingsPageBackground,
        middle: Text(widget.group.suggest ?? l10n.faceGroupsUnnamed),
        trailing: CupertinoButton(
          key: const ValueKey('faceGroupDelete'),
          padding: EdgeInsets.zero,
          onPressed: _busy ? null : _delete,
          child: const Icon(CupertinoIcons.trash),
        ),
      ),
      child: SafeArea(
        child: Column(
          children: [
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
                  if (_faces.isNotEmpty)
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
            Expanded(
              child: GridView.builder(
                padding: const EdgeInsets.all(8),
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 88,
                  mainAxisSpacing: 8,
                  crossAxisSpacing: 8,
                ),
                itemCount: _faces.length,
                itemBuilder: (context, i) {
                  final f = _faces[i];
                  return _FaceTile(
                    key: ValueKey('${f.localId}|${f.face.encode()}'),
                    face: f,
                    on: !_off.contains(i),
                    records: widget.records,
                    assetRecordStore: widget.assetRecordStore,
                    onTap: () => _toggle(i),
                    onLongPress: widget.onOpenAsset == null
                        ? null
                        : () => widget.onOpenAsset!(f.localId),
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Row(
                children: [
                  Expanded(
                    child: CupertinoButton(
                      key: const ValueKey('faceGroupNotThis'),
                      color: settingsControlFill,
                      onPressed: _busy || ticked == 0 ? null : _notThisGroup,
                      child: Text(l10n.faceGroupsNotThis),
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
    required this.records,
    required this.assetRecordStore,
    required this.onTap,
    this.onLongPress,
  });

  final _Face face;
  final bool on;
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
          Positioned(
            right: 2,
            bottom: 2,
            child: Icon(
              on ? CupertinoIcons.checkmark_circle_fill : CupertinoIcons.circle,
              size: 22,
              color: on ? settingsAccent : CupertinoColors.systemGrey,
            ),
          ),
        ],
      ),
    ),
  );
}
