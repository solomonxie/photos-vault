import 'package:flutter/cupertino.dart';

import '../l10n/app_localizations.dart';
import '../photos/ai_analysis_store.dart';
import '../photos/face_identity.dart';
import '../photos/face_import.dart';
import '../photos/people_order.dart';
import '../photos/person.dart';
import '../photos/person_store.dart';
import '../settings/settings_section.dart';
import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import 'back_swipe_edge.dart';
import 'imported_group_screen.dart';
import 'person_avatar.dart';
import 'person_page_screen.dart';

/// People → Faces to Name: the imported groups, biggest first. Select to
/// ignore several at once; ignored groups wait under Ignored, kept, so a
/// later import puts the same faces back there. With [ignored], the one
/// Ignored page: ignored people, then ignored unnamed faces.
class FaceGroupsScreen extends StatefulWidget {
  const FaceGroupsScreen({
    super.key,
    required this.analysisStore,
    required this.assetRecordStore,
    required this.personStore,
    this.onOpenAsset,
    this.faceIdentity,
    this.ignored = false,
  });

  final AiAnalysisStore? analysisStore;
  final AssetRecordStore assetRecordStore;
  final PersonStore personStore;
  final Future<void> Function(String localId)? onOpenAsset;
  final FaceIdentityService? faceIdentity;
  final bool ignored;

  @override
  State<FaceGroupsScreen> createState() => _FaceGroupsScreenState();
}

class _FaceGroupsScreenState extends State<FaceGroupsScreen> {
  static const _faceSize = 66.0;

  List<StoredFaceGroup> _groups = const [];
  Map<String, AssetRecord> _records = const {};
  List<Person> _ignoredPeople = const [];
  int _ignoredCount = 0;
  bool _loaded = false;
  bool _selecting = false;
  bool _busy = false;

  /// Groups on fewer photos than this wait behind one row, opened by a tap.
  static const _foldUnder = 4;
  bool _showSmall = false;

  static int _photos(StoredFaceGroup g) =>
      {for (final f in g.faces) f.localId}.length;
  final _picked = <String>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final analysis = widget.analysisStore;
    final found = analysis == null
        ? (groups: const <StoredFaceGroup>[], records: <String, AssetRecord>{})
        : await loadFaceGroups(
            analysis,
            widget.assetRecordStore,
            ignored: widget.ignored,
          );
    final ignoredGroups = widget.ignored || analysis == null
        ? 0
        : (await analysis.faceGroups(ignored: true)).length;
    final ignoredPeople = [
      for (final p in await widget.personStore.listAll())
        if (p.ignored) p,
    ]..sort((a, b) => nameSortKey(a.name).compareTo(nameSortKey(b.name)));
    if (!mounted) return;
    setState(() {
      _groups = found.groups;
      _records = found.records;
      _ignoredPeople = ignoredPeople;
      _ignoredCount = ignoredGroups + ignoredPeople.length;
      _loaded = true;
      _picked.retainAll({for (final g in _groups) g.id});
      if (_groups.isEmpty) _selecting = false;
    });
  }

  Future<void> _open(StoredFaceGroup group) async {
    await Navigator.of(context).push(
      CupertinoPageRoute<void>(
        builder: (_) => ImportedGroupScreen(
          group: group,
          records: _records,
          analysisStore: widget.analysisStore!,
          assetRecordStore: widget.assetRecordStore,
          personStore: widget.personStore,
          onOpenAsset: widget.onOpenAsset,
          ignored: widget.ignored,
        ),
      ),
    );
    await _load();
  }

  Future<void> _openIgnored() async {
    await Navigator.of(context).push(
      CupertinoPageRoute<void>(
        builder: (_) => FaceGroupsScreen(
          analysisStore: widget.analysisStore,
          assetRecordStore: widget.assetRecordStore,
          personStore: widget.personStore,
          onOpenAsset: widget.onOpenAsset,
          faceIdentity: widget.faceIdentity,
          ignored: true,
        ),
      ),
    );
    await _load();
  }

  /// Ignores the picked groups, or in the Ignored list brings them back.
  Future<void> _applyPicked() async {
    if (_busy || _picked.isEmpty) return;
    setState(() => _busy = true);
    try {
      for (final id in _picked) {
        await widget.analysisStore!.ignoreGroup(id, ignored: !widget.ignored);
      }
      _picked.clear();
      _selecting = false;
      await _load();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _stopIgnoring(Person person) async {
    await widget.personStore.update(person.copyWith(ignored: false));
    await _load();
  }

  Future<void> _openPerson(Person person) async {
    await Navigator.of(context).push(
      CupertinoPageRoute<void>(
        builder: (_) => PersonPageScreen(
          person: person,
          personStore: widget.personStore,
          assetRecordStore: widget.assetRecordStore,
          aiAnalysisStore: widget.analysisStore,
          faceIdentity: widget.faceIdentity,
        ),
      ),
    );
    await _load();
  }

  Widget _heading(String text, int count) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
    child: Row(
      children: [
        Expanded(
          child: Text(
            text,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: CupertinoColors.systemGrey,
            ),
          ),
        ),
        Text(
          '$count',
          style: const TextStyle(
            fontSize: 13,
            color: CupertinoColors.systemGrey,
          ),
        ),
      ],
    ),
  );

  Widget _personRow(AppLocalizations l10n, Person person) => Row(
    children: [
      Expanded(
        child: CupertinoListTile(
          key: ValueKey('people-row-${person.id}'),
          leadingSize: _faceSize + 4,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          leading: PersonAvatar.forPerson(
            assetRecordStore: widget.assetRecordStore,
            person: person,
            size: _faceSize,
          ),
          title: Text(person.name, overflow: TextOverflow.ellipsis),
          onTap: () => _openPerson(person),
        ),
      ),
      CupertinoButton(
        key: ValueKey('people-unignore-${person.id}'),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        onPressed: () => _stopIgnoring(person),
        child: Text(
          l10n.faceGroupsUnignore,
          style: const TextStyle(fontSize: 15),
        ),
      ),
    ],
  );

  void _toggle(String id) => setState(
    () => _picked.contains(id) ? _picked.remove(id) : _picked.add(id),
  );

  Widget _row(AppLocalizations l10n, StoredFaceGroup group) {
    final on = _picked.contains(group.id);
    return CupertinoListTile(
      key: ValueKey('people-imported-${group.id}'),
      leadingSize: _faceSize + 4,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      leading: Container(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: CupertinoColors.systemGrey, width: 1.5),
        ),
        padding: const EdgeInsets.all(2),
        child: PersonAvatar(
          assetRecordStore: widget.assetRecordStore,
          localId: group.faces.first.localId,
          face: group.faces.first.face,
          records: _records,
          size: _faceSize,
        ),
      ),
      title: Text(
        group.suggest == null
            ? l10n.peopleUnnamedFace
            : l10n.peopleSuggestedFace(group.suggest!),
        style: const TextStyle(color: CupertinoColors.systemGrey),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '${group.faces.length}',
            style: const TextStyle(color: CupertinoColors.systemGrey),
          ),
          const SizedBox(width: 8),
          if (_selecting)
            Icon(
              on ? CupertinoIcons.checkmark_circle_fill : CupertinoIcons.circle,
              size: 22,
              color: on ? settingsAccent : CupertinoColors.systemGrey,
            )
          else
            const Icon(
              CupertinoIcons.chevron_forward,
              size: 18,
              color: CupertinoColors.systemGrey2,
            ),
        ],
      ),
      onTap: _selecting ? () => _toggle(group.id) : () => _open(group),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(
          widget.ignored
              ? l10n.faceGroupsIgnoredTitle
              : l10n.peopleUnnamedHeading,
        ),
        trailing: _groups.isEmpty
            ? null
            : CupertinoButton(
                key: const ValueKey('faceGroupsSelect'),
                padding: EdgeInsets.zero,
                onPressed: () => setState(() {
                  _selecting = !_selecting;
                  _picked.clear();
                }),
                child: Text(_selecting ? l10n.actionCancel : l10n.albumSelect),
              ),
      ),
      child: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: BackSwipeEdge<Object>(
                child: ListView(
                  key: ValueKey(
                    widget.ignored
                        ? 'people-ignored-page'
                        : 'people-faces-page',
                  ),
                  children: [
                    if (widget.ignored && _ignoredPeople.isNotEmpty) ...[
                      _heading(
                        l10n.peopleSectionNamed.toUpperCase(),
                        _ignoredPeople.length,
                      ),
                      for (final p in _ignoredPeople) _personRow(l10n, p),
                    ],
                    if (widget.ignored && _groups.isNotEmpty) ...[
                      _heading(l10n.peopleIgnoredFacesSection, _groups.length),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                        child: Text(
                          l10n.faceGroupsIgnoredHint,
                          style: settingsHintStyle,
                        ),
                      ),
                    ],
                    if (_loaded &&
                        _groups.isEmpty &&
                        (!widget.ignored || _ignoredPeople.isEmpty))
                      Padding(
                        padding: const EdgeInsets.only(top: 48),
                        child: Center(
                          child: Text(
                            widget.ignored
                                ? l10n.faceGroupsIgnoredEmpty
                                : l10n.faceGroupsAllNamed,
                            style: const TextStyle(
                              color: CupertinoColors.systemGrey,
                            ),
                          ),
                        ),
                      ),
                    if (!widget.ignored && !_selecting && _ignoredCount > 0)
                      CupertinoListTile(
                        key: const ValueKey('faceGroupsIgnored'),
                        leading: const Icon(
                          CupertinoIcons.eye_slash,
                          color: CupertinoColors.systemGrey,
                        ),
                        title: Text(l10n.faceGroupsIgnoredTitle),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              '$_ignoredCount',
                              style: const TextStyle(
                                color: CupertinoColors.systemGrey,
                              ),
                            ),
                            const SizedBox(width: 4),
                            const Icon(
                              CupertinoIcons.chevron_forward,
                              size: 18,
                              color: CupertinoColors.systemGrey2,
                            ),
                          ],
                        ),
                        onTap: _openIgnored,
                      ),
                    if (_groups.where((g) => _photos(g) < _foldUnder).toList()
                        case final small when small.isNotEmpty) ...[
                      CupertinoListTile(
                        key: const ValueKey('faceGroupsSmall'),
                        leading: const Icon(
                          CupertinoIcons.square_stack,
                          color: CupertinoColors.systemGrey,
                        ),
                        title: Text(l10n.faceGroupsSmall(_foldUnder)),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              '${small.length}',
                              style: const TextStyle(
                                color: CupertinoColors.systemGrey,
                              ),
                            ),
                            const SizedBox(width: 4),
                            Icon(
                              _showSmall
                                  ? CupertinoIcons.chevron_up
                                  : CupertinoIcons.chevron_down,
                              size: 18,
                              color: CupertinoColors.systemGrey2,
                            ),
                          ],
                        ),
                        onTap: () => setState(() => _showSmall = !_showSmall),
                      ),
                      if (_showSmall)
                        for (final g in small) _row(l10n, g),
                    ],
                    for (final g in _groups)
                      if (_photos(g) >= _foldUnder) _row(l10n, g),
                  ],
                ),
              ),
            ),
            if (_selecting)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: SizedBox(
                  width: double.infinity,
                  child: CupertinoButton.filled(
                    key: const ValueKey('faceGroupsApply'),
                    onPressed: _busy || _picked.isEmpty ? null : _applyPicked,
                    child: Text(
                      widget.ignored
                          ? l10n.faceGroupsUnignoreCount(_picked.length)
                          : l10n.faceGroupsIgnoreCount(_picked.length),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
