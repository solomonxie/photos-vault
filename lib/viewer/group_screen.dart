import 'package:flutter/cupertino.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../photos/person.dart';
import '../photos/person_store.dart';
import '../settings/settings_section.dart';
import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import 'asset_group_screen.dart';
import 'person_avatar.dart';
import 'person_page_screen.dart';
import 'profile_chip.dart' show groupKindLabel;
import 'search_picker_sheet.dart';

/// One group: its name, kind and dates to change, who is in it, people to add or
/// take out, and the group itself to delete. Open set only.
class GroupScreen extends StatefulWidget {
  const GroupScreen({
    super.key,
    required this.group,
    required this.personStore,
    required this.assetRecordStore,
  });

  final PersonGroup group;
  final PersonStore personStore;
  final AssetRecordStore assetRecordStore;

  @override
  State<GroupScreen> createState() => _GroupScreenState();
}

class _GroupScreenState extends State<GroupScreen> {
  late final _name = TextEditingController(text: widget.group.name);
  late GroupKind _kind = widget.group.kind;
  late DateTime? _start = widget.group.start;
  late DateTime? _end = widget.group.end;
  List<Person> _members = const [];
  List<Person> _everyone = const [];
  Map<String, List<String>> _photos = const {};

  void _setMembers(List<Person> members) {
    _members = members;
    _groupPhotos = _photosOfMembers();
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final groups = await widget.personStore.allGroups();
    final ids = {
      for (final e in groups.entries)
        if (e.key.id == widget.group.id) ...e.value,
    };
    final stored = groups.keys
        .where((g) => g.id == widget.group.id)
        .firstOrNull;
    final everyone = await widget.personStore.listAll()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    final photos = await widget.personStore.allMemberships();
    if (!mounted) return;
    setState(() {
      if (stored != null) {
        _start = stored.start;
        _end = stored.end;
      }
      _everyone = everyone;
      _photos = photos;
      _setMembers([
        for (final p in everyone)
          if (ids.contains(p.id)) p,
      ]);
    });
  }

  Future<void> _rename(String value) async {
    final name = value.trim();
    if (name.isEmpty) return;
    await widget.personStore.updateGroup(widget.group.id, name: name);
  }

  Future<void> _setKind(GroupKind kind) async {
    setState(() => _kind = kind);
    await widget.personStore.updateGroup(widget.group.id, kind: kind);
  }

  Future<void> _pickDate({required bool start}) async {
    final picked = await _pickDay(context, start ? _start : _end);
    if (picked == null || !mounted) return;
    setState(() {
      if (start) {
        _start = picked.value;
      } else {
        _end = picked.value;
      }
    });
    await widget.personStore.updateGroup(
      widget.group.id,
      range: (start: _start, end: _end),
    );
  }

  PersonGroup get _current => PersonGroup(
    id: widget.group.id,
    name: _name.text.trim().isEmpty ? widget.group.name : _name.text.trim(),
    kind: _kind,
    start: _start,
    end: _end,
  );

  Widget _dateRow(AppLocalizations l10n, {required bool start}) {
    final value = start ? _start : _end;
    return CupertinoListTile(
      key: ValueKey(start ? 'groupStart' : 'groupEnd'),
      backgroundColor: settingsPageBackground,
      padding: const EdgeInsets.symmetric(vertical: 6),
      leading: Icon(start ? CupertinoIcons.calendar : CupertinoIcons.flag),
      title: Text(start ? l10n.groupStart : l10n.groupEnd),
      additionalInfo: Text(
        value == null ? l10n.groupDateNone : DateFormat.yMMMd().format(value),
      ),
      trailing: const CupertinoListTileChevron(),
      onTap: () => _pickDate(start: start),
    );
  }

  Future<void> _add() async {
    final l10n = AppLocalizations.of(context)!;
    final inGroup = {for (final p in _members) p.id};
    final chosen = await showSearchPickerSheetMulti<Person>(
      context: context,
      title: l10n.groupAddPeople,
      options: [
        for (final p in _everyone)
          if (!inGroup.contains(p.id)) p,
      ],
      labelOf: (p) => p.name,
    );
    if (chosen == null || chosen.isEmpty) return;
    for (final p in chosen) {
      await widget.personStore.joinGroup(
        p.id,
        _current,
        scope: PersonScope.open,
      );
    }
    // In place: a reload re-reads everyone's photos for one more name.
    final ids = {
      for (final p in [..._members, ...chosen]) p.id,
    };
    if (!mounted) return;
    setState(
      () => _setMembers([
        for (final p in _everyone)
          if (ids.contains(p.id)) p,
      ]),
    );
  }

  Future<void> _remove(Person person) async {
    await widget.personStore.leaveGroup(
      person.id,
      widget.group.id,
      scope: PersonScope.open,
    );
    if (!mounted) return;
    setState(
      () => _setMembers([
        for (final p in _members)
          if (p.id != person.id) p,
      ]),
    );
  }

  Future<void> _delete() async {
    final l10n = AppLocalizations.of(context)!;
    final ok = await showCupertinoDialog<bool>(
      context: context,
      builder: (dialog) => CupertinoAlertDialog(
        title: Text(l10n.peopleDeleteGroupTitle(_current.name)),
        content: Text(l10n.peopleDeleteGroupBody(_members.length)),
        actions: [
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () => Navigator.of(dialog).pop(false),
            child: Text(l10n.actionCancel),
          ),
          CupertinoDialogAction(
            key: const ValueKey('groupDeleteConfirm'),
            isDestructiveAction: true,
            onPressed: () => Navigator.of(dialog).pop(true),
            child: Text(l10n.actionDelete),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await widget.personStore.deleteGroup(
      widget.group.id,
      scope: PersonScope.open,
    );
    if (mounted) Navigator.of(context).pop();
  }

  /// Everyone's photos together, newest first; kept with [_members].
  List<AssetRecord> _groupPhotos = const [];

  List<AssetRecord> _photosOfMembers() {
    final byId = widget.assetRecordStore.visibleById;
    final ids = {for (final p in _members) ...?_photos[p.id]};
    return [for (final id in ids) ?byId[id]]
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  Future<void> _openPhotos() async {
    await Navigator.of(context).push(
      CupertinoPageRoute<void>(
        builder: (_) => AssetGroupScreen(
          title: _current.name,
          records: _groupPhotos,
          assetRecordStore: widget.assetRecordStore,
        ),
      ),
    );
  }

  Future<void> _mergeInto() async {
    final l10n = AppLocalizations.of(context)!;
    final others = [
      for (final g in (await widget.personStore.allGroups()).keys)
        if (g.id != widget.group.id) g,
    ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    if (!mounted || others.isEmpty) return;
    final into = await showSearchPickerSheetOf<PersonGroup>(
      context: context,
      title: l10n.groupMerge,
      options: others,
      labelOf: (g) => g.name,
      autofocus: false,
    );
    if (into == null || !mounted) return;
    final from = _current.name;
    final ok = await showCupertinoDialog<bool>(
      context: context,
      builder: (dialog) => CupertinoAlertDialog(
        title: Text(l10n.groupMergeConfirmTitle(from, into.name)),
        content: Text(l10n.groupMergeConfirmBody(from, into.name)),
        actions: [
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () => Navigator.of(dialog).pop(false),
            child: Text(l10n.actionCancel),
          ),
          CupertinoDialogAction(
            key: const ValueKey('groupMergeConfirm'),
            onPressed: () => Navigator.of(dialog).pop(true),
            child: Text(l10n.groupMergeAction),
          ),
        ],
      ),
    );
    if (ok != true) return;
    for (final p in _members) {
      await widget.personStore.joinGroup(p.id, into, scope: PersonScope.open);
    }
    await widget.personStore.deleteGroup(
      widget.group.id,
      scope: PersonScope.open,
    );
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _open(Person person) async {
    await Navigator.of(context).push(
      CupertinoPageRoute<void>(
        builder: (_) => PersonPageScreen(
          person: person,
          personStore: widget.personStore,
          assetRecordStore: widget.assetRecordStore,
        ),
      ),
    );
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return CupertinoPageScaffold(
      backgroundColor: settingsPageBackground,
      navigationBar: CupertinoNavigationBar(
        backgroundColor: settingsPageBackground,
        middle: Text(_current.name),
      ),
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(settingsPagePadding),
          children: [
            CupertinoTextField(
              key: const ValueKey('groupName'),
              controller: _name,
              placeholder: l10n.groupNameLabel,
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w600,
                color: CupertinoColors.white,
              ),
              onChanged: (v) {
                setState(() {});
                _rename(v);
              },
            ),
            const SizedBox(height: 12),
            CupertinoSlidingSegmentedControl<GroupKind>(
              groupValue: _kind,
              onValueChanged: (k) {
                if (k != null) _setKind(k);
              },
              children: {
                for (final k in GroupKind.values)
                  k: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Text(
                      groupKindLabel(l10n, k),
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
              },
            ),
            const SizedBox(height: 12),
            _dateRow(l10n, start: true),
            _dateRow(l10n, start: false),
            if (_groupPhotos.isNotEmpty)
              CupertinoListTile(
                key: const ValueKey('groupPhotos'),
                backgroundColor: settingsPageBackground,
                padding: const EdgeInsets.symmetric(vertical: 6),
                leading: const Icon(CupertinoIcons.photo_on_rectangle),
                title: Text(l10n.groupPhotos),
                additionalInfo: Text('${_groupPhotos.length}'),
                trailing: const CupertinoListTileChevron(),
                onTap: _openPhotos,
              ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    l10n.groupMembers(_members.length),
                    style: settingsRowTitleStyle,
                  ),
                ),
                CupertinoButton(
                  key: const ValueKey('groupAddPeople'),
                  padding: EdgeInsets.zero,
                  onPressed: _add,
                  child: Text(l10n.groupAddPeople),
                ),
              ],
            ),
            for (final person in _members)
              CupertinoListTile(
                key: ValueKey('groupMember-${person.id}'),
                backgroundColor: settingsPageBackground,
                padding: const EdgeInsets.symmetric(vertical: 6),
                leadingSize: 40,
                leading: PersonAvatar.forPerson(
                  assetRecordStore: widget.assetRecordStore,
                  person: person,
                  firstTaggedLocalId: _photos[person.id]?.firstOrNull,
                  records: widget.assetRecordStore.visibleById,
                  size: 40,
                ),
                title: Text(person.name),
                subtitle: Text(
                  l10n.mergePeoplePhotos(_photos[person.id]?.length ?? 0),
                ),
                trailing: CupertinoButton(
                  key: ValueKey('groupRemove-${person.id}'),
                  padding: EdgeInsets.zero,
                  minimumSize: const Size(36, 36),
                  onPressed: () => _remove(person),
                  child: const Icon(
                    CupertinoIcons.minus_circle,
                    color: CupertinoColors.systemRed,
                    size: 22,
                  ),
                ),
                onTap: () => _open(person),
              ),
            const SizedBox(height: 28),
            CupertinoButton(
              key: const ValueKey('groupMergeInto'),
              onPressed: _mergeInto,
              child: Text(l10n.groupMerge),
            ),
            CupertinoButton(
              key: const ValueKey('groupDelete'),
              onPressed: _delete,
              child: Text(
                l10n.groupDelete,
                style: const TextStyle(color: CupertinoColors.systemRed),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A day, or no day: null when dismissed, a record (even holding null)
/// when chosen.
Future<({DateTime? value})?> _pickDay(BuildContext context, DateTime? initial) {
  final l10n = AppLocalizations.of(context)!;
  final from = initial ?? DateTime.now();
  var chosen = DateTime(from.year, from.month, from.day);
  return showCupertinoModalPopup<({DateTime? value})>(
    context: context,
    builder: (sheet) => Container(
      height: 300,
      color: CupertinoColors.systemBackground.resolveFrom(sheet),
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            Row(
              children: [
                CupertinoButton(
                  key: const ValueKey('groupDateClear'),
                  onPressed: () => Navigator.of(sheet).pop((value: null)),
                  child: Text(l10n.actionClear),
                ),
                const Spacer(),
                CupertinoButton(
                  key: const ValueKey('groupDateDone'),
                  onPressed: () => Navigator.of(sheet).pop((value: chosen)),
                  child: Text(l10n.actionDone),
                ),
              ],
            ),
            Expanded(
              child: CupertinoDatePicker(
                mode: CupertinoDatePickerMode.date,
                initialDateTime: chosen,
                minimumYear: 1900,
                onDateTimeChanged: (d) =>
                    chosen = DateTime(d.year, d.month, d.day),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
