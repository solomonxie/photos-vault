import 'package:flutter/cupertino.dart';

import '../l10n/app_localizations.dart';
import '../photos/family_suggestions.dart';
import '../photos/person.dart';
import '../photos/person_store.dart';
import '../settings/settings_section.dart';
import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import 'person_avatar.dart';

Future<(List<FamilySuggestion>, Map<String, Person>)> loadFamilySuggestions(
  PersonStore people,
) async {
  final all = await people.listAll();
  final found = familySuggestions(
    people: all,
    groups: await people.allGroups(),
    relationships: await people.allRelationships(),
    photosOf: await people.allMemberships(),
  );
  return (found, {for (final p in all) p.id: p});
}

/// Suggestions → Families by surname: one section per surname, everyone
/// in it ticked; untick who doesn't belong, then Apply.
class FamilySuggestionsScreen extends StatefulWidget {
  const FamilySuggestionsScreen({
    super.key,
    required this.personStore,
    required this.assetRecordStore,
  });

  final PersonStore personStore;
  final AssetRecordStore assetRecordStore;

  @override
  State<FamilySuggestionsScreen> createState() =>
      _FamilySuggestionsScreenState();
}

class _FamilySuggestionsScreenState extends State<FamilySuggestionsScreen> {
  List<FamilySuggestion> _items = const [];
  Map<String, Person> _byId = const {};
  Map<String, List<String>> _members = const {};
  Map<String, AssetRecord> _records = const {};

  /// Unticked, per suggestion (by surname): everyone else is in.
  final _left = <String, Set<String>>{};
  bool _loaded = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final (items, byId) = await loadFamilySuggestions(widget.personStore);
    final members = await widget.personStore.allMemberships();
    final records = await widget.assetRecordStore.listOf({
      for (final s in items)
        for (final id in s.personIds)
          ?(byId[id]?.avatarLocalId ?? members[id]?.firstOrNull),
    });
    if (!mounted) return;
    setState(() {
      _items = items;
      _byId = byId;
      _members = members;
      _records = {for (final r in records) r.localId: r};
      _left.clear();
      _loaded = true;
    });
  }

  List<String> _pickedOf(FamilySuggestion s) => [
    for (final id in s.personIds)
      if (!(_left[s.surname]?.contains(id) ?? false)) id,
  ];

  /// Two or more ticked: there's a family to make.
  int get _ready => _items.where((s) => _pickedOf(s).length > 1).length;

  void _toggle(FamilySuggestion s, String id) => setState(() {
    final left = _left[s.surname] ??= {};
    if (!left.remove(id)) left.add(id);
  });

  Future<void> _apply() async {
    if (_busy || _ready == 0) return;
    final l10n = AppLocalizations.of(context)!;
    setState(() => _busy = true);
    try {
      final store = widget.personStore;
      for (final s in _items) {
        final picked = _pickedOf(s);
        if (picked.length < 2) continue;
        final group =
            s.into ??
            PersonGroup(
              id: store.newId(),
              name: l10n.familySuggestGroupName(s.surname),
              kind: GroupKind.family,
            );
        for (final id in picked) {
          await store.joinGroup(id, group, scope: PersonScope.open);
        }
      }
      await _load();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return CupertinoPageScaffold(
      backgroundColor: settingsPageBackground,
      navigationBar: CupertinoNavigationBar(
        backgroundColor: settingsPageBackground,
        middle: Text(l10n.familySuggestTitle),
      ),
      child: SafeArea(
        child: !_loaded
            ? const Center(child: CupertinoActivityIndicator())
            : _items.isEmpty
            ? Center(
                child: Text(
                  l10n.familySuggestEmpty,
                  key: const ValueKey('familyEmpty'),
                  style: settingsHintStyle,
                ),
              )
            : Column(
                children: [
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.all(settingsPagePadding),
                      children: [for (final s in _items) ..._section(l10n, s)],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(settingsPagePadding),
                    child: SizedBox(
                      width: double.infinity,
                      child: CupertinoButton.filled(
                        key: const ValueKey('familyApply'),
                        onPressed: _ready == 0 || _busy ? null : _apply,
                        child: Text(l10n.familySuggestApply(_ready)),
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  List<Widget> _section(AppLocalizations l10n, FamilySuggestion s) => [
    Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 4, left: 4),
      child: Text(
        s.into == null
            ? l10n.familySuggestGroupName(s.surname)
            : l10n.familySuggestJoins(s.into!.name),
        style: settingsHintStyle,
      ),
    ),
    for (final id in s.personIds)
      if (_byId[id] case final person?)
        CupertinoListTile(
          key: ValueKey('family-${s.surname}-$id'),
          backgroundColor: settingsPageBackground,
          padding: const EdgeInsets.symmetric(vertical: 6),
          leadingSize: 40,
          leading: PersonAvatar.forPerson(
            assetRecordStore: widget.assetRecordStore,
            person: person,
            firstTaggedLocalId: _members[id]?.firstOrNull,
            records: _records,
            size: 40,
          ),
          title: Text(person.name),
          trailing: Icon(
            _pickedOf(s).contains(id)
                ? CupertinoIcons.checkmark_circle_fill
                : CupertinoIcons.circle,
            color: _pickedOf(s).contains(id)
                ? settingsAccent
                : CupertinoColors.systemGrey2,
          ),
          onTap: () => _toggle(s, id),
        ),
  ];
}
