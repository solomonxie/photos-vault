import 'package:flutter/cupertino.dart';

import '../l10n/app_localizations.dart';
import '../photos/person.dart';
import '../photos/person_store.dart';
import '../settings/settings_section.dart';
import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import 'group_picker.dart';
import 'person_avatar.dart';
import 'select_all.dart';

/// People in no group yet, most photos first, so the ones worth filing
/// come first.
Future<List<Person>> ungroupedPeople(PersonStore store) async {
  final people = await store.listAll();
  final grouped = {for (final ids in (await store.allGroups()).values) ...ids};
  final members = await store.allMemberships();
  int photos(Person p) => members[p.id]?.length ?? 0;
  return [
    // Locked people stay out: an open group would name them.
    for (final p in people)
      if (!p.locked && !grouped.contains(p.id)) p,
  ]..sort((a, b) {
    final byPhotos = photos(b).compareTo(photos(a));
    return byPhotos != 0
        ? byPhotos
        : a.name.toLowerCase().compareTo(b.name.toLowerCase());
  });
}

/// Suggestions → People Without a Group: tick some, add them to a group.
class UngroupedPeopleScreen extends StatefulWidget {
  const UngroupedPeopleScreen({
    super.key,
    required this.people,
    required this.personStore,
    required this.assetRecordStore,
  });

  final List<Person> people;
  final PersonStore personStore;
  final AssetRecordStore assetRecordStore;

  @override
  State<UngroupedPeopleScreen> createState() => _UngroupedPeopleScreenState();
}

class _UngroupedPeopleScreenState extends State<UngroupedPeopleScreen> {
  late List<Person> _left = widget.people;
  final _picked = <String>{};
  Map<String, List<String>> _members = const {};
  Map<String, AssetRecord> _records = const {};
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadAvatars();
  }

  Future<void> _loadAvatars() async {
    final members = await widget.personStore.allMemberships();
    final firsts = {
      for (final p in _left) ?(p.avatarLocalId ?? members[p.id]?.firstOrNull),
    };
    final records = await widget.assetRecordStore.listOf(firsts);
    if (!mounted) return;
    setState(() {
      _members = members;
      _records = {for (final r in records) r.localId: r};
    });
  }

  Future<void> _addToGroup() async {
    if (_busy || _picked.isEmpty) return;
    setState(() => _busy = true);
    try {
      final groups = (await widget.personStore.allGroups()).keys;
      if (!mounted) return;
      final added = await addPeopleToGroup(
        context,
        personStore: widget.personStore,
        groups: groups,
        personIds: _picked,
      );
      if (added == null || !mounted) return;
      setState(() {
        _left = [
          for (final p in _left)
            if (!_picked.contains(p.id)) p,
        ];
        _picked.clear();
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toggle(String id) => setState(
    () => _picked.contains(id) ? _picked.remove(id) : _picked.add(id),
  );

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return CupertinoPageScaffold(
      backgroundColor: settingsPageBackground,
      navigationBar: CupertinoNavigationBar(
        backgroundColor: settingsPageBackground,
        middle: Text(l10n.ungroupedTitle),
        trailing: SelectAllButton(
          unlimited: true,
          total: _left.length,
          selectedCount: _picked.length,
          onSelectNext: () =>
              setState(() => _picked.addAll(_left.map((p) => p.id))),
          onDeselectAll: () => setState(_picked.clear),
        ),
      ),
      child: SafeArea(
        child: _left.isEmpty
            ? Center(child: Text(l10n.ungroupedEmpty, style: settingsHintStyle))
            : Column(
                children: [
                  Expanded(
                    child: ListView.builder(
                      padding: const EdgeInsets.all(settingsPagePadding),
                      itemCount: _left.length,
                      itemBuilder: (context, i) => _row(_left[i]),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      settingsPagePadding,
                      8,
                      settingsPagePadding,
                      8,
                    ),
                    child: SizedBox(
                      width: double.infinity,
                      child: CupertinoButton.filled(
                        key: const ValueKey('ungroupedAddToGroup'),
                        onPressed: _busy || _picked.isEmpty
                            ? null
                            : _addToGroup,
                        child: Text(l10n.peopleBatchAddToGroup),
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _row(Person p) {
    final selected = _picked.contains(p.id);
    return GestureDetector(
      key: ValueKey('ungrouped-${p.id}'),
      behavior: HitTestBehavior.opaque,
      onTap: () => _toggle(p.id),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            PersonAvatar.forPerson(
              assetRecordStore: widget.assetRecordStore,
              person: p,
              firstTaggedLocalId: _members[p.id]?.firstOrNull,
              records: _records,
              size: 44,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                p.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: settingsRowTitleStyle,
              ),
            ),
            Icon(
              selected
                  ? CupertinoIcons.checkmark_circle_fill
                  : CupertinoIcons.circle,
              size: 22,
              color: selected ? settingsAccent : settingsTertiary,
            ),
          ],
        ),
      ),
    );
  }
}
