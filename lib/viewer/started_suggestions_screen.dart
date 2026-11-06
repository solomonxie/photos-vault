import 'package:flutter/cupertino.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../photos/person.dart';
import '../photos/person_owner.dart';
import '../photos/person_store.dart';
import '../photos/started_suggestions.dart';
import '../settings/settings_section.dart';
import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import 'person_avatar.dart';

/// Every suggestion, with its person, by name. Ignored people are left out.
Future<List<(Person, StartedSuggestion)>> loadStartedSuggestions(
  PersonStore people,
  AssetRecordStore settings,
) async {
  final ownerId = await PersonOwner(settings).id();
  if (ownerId == null) return const [];
  final spans = await people.openEventSpans();
  final found = startedSuggestions(
    ownerId: ownerId,
    groups: await people.allGroups(),
    started: {
      for (final MapEntry(:key, :value) in spans.entries) key: ?value.firstMet,
    },
  );
  if (found.isEmpty) return const [];
  final byId = {for (final p in await people.listAll()) p.id: p};
  return [
    for (final s in found)
      if (byId[s.personId] case final p? when !p.ignored) (p, s),
  ]..sort((a, b) => a.$1.name.toLowerCase().compareTo(b.$1.name.toLowerCase()));
}

/// Suggestions → Started dates from groups: pick, then Apply.
class StartedSuggestionsScreen extends StatefulWidget {
  const StartedSuggestionsScreen({
    super.key,
    required this.personStore,
    required this.assetRecordStore,
  });

  final PersonStore personStore;
  final AssetRecordStore assetRecordStore;

  @override
  State<StartedSuggestionsScreen> createState() =>
      _StartedSuggestionsScreenState();
}

class _StartedSuggestionsScreenState extends State<StartedSuggestionsScreen> {
  List<(Person, StartedSuggestion)> _items = const [];
  Map<String, List<String>> _members = const {};
  Map<String, AssetRecord> _records = const {};
  final _picked = <String>{};
  bool _loaded = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final items = await loadStartedSuggestions(
      widget.personStore,
      widget.assetRecordStore,
    );
    final members = await widget.personStore.allMemberships();
    final records = await widget.assetRecordStore.listOf({
      for (final (p, _) in items)
        ?(p.avatarLocalId ?? members[p.id]?.firstOrNull),
    });
    if (!mounted) return;
    setState(() {
      _items = items;
      _members = members;
      _records = {for (final r in records) r.localId: r};
      _picked.retainAll({for (final (p, _) in items) p.id});
      _loaded = true;
    });
  }

  void _toggle(String id) => setState(() {
    if (!_picked.remove(id)) _picked.add(id);
  });

  void _selectAll() => setState(() {
    if (_picked.length == _items.length) {
      _picked.clear();
    } else {
      _picked.addAll([for (final (p, _) in _items) p.id]);
    }
  });

  Future<void> _apply() async {
    if (_busy || _picked.isEmpty) return;
    setState(() => _busy = true);
    try {
      for (final (p, s) in _items) {
        if (_picked.contains(p.id)) {
          await widget.personStore.markMet(p.id, s.suggested);
        }
      }
      _picked.clear();
      await _load();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final day = DateFormat.yMMMd();
    return CupertinoPageScaffold(
      backgroundColor: settingsPageBackground,
      navigationBar: CupertinoNavigationBar(
        backgroundColor: settingsPageBackground,
        middle: Text(l10n.startedSuggestTitle),
        trailing: _items.isEmpty
            ? null
            : SettingsAccentButton(
                key: const ValueKey('startedSelectAll'),
                label: l10n.suggestionsSelectAll,
                onPressed: _selectAll,
              ),
      ),
      child: SafeArea(
        child: !_loaded
            ? const Center(child: CupertinoActivityIndicator())
            : _items.isEmpty
            ? Center(
                child: Text(
                  l10n.startedSuggestEmpty,
                  key: const ValueKey('startedEmpty'),
                  style: settingsHintStyle,
                ),
              )
            : Column(
                children: [
                  Expanded(
                    child: ListView.builder(
                      padding: const EdgeInsets.all(settingsPagePadding),
                      itemCount: _items.length,
                      itemBuilder: (context, i) {
                        final (person, s) = _items[i];
                        final picked = _picked.contains(person.id);
                        return CupertinoListTile(
                          key: ValueKey('started-${person.id}'),
                          backgroundColor: settingsPageBackground,
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          leadingSize: 40,
                          leading: PersonAvatar.forPerson(
                            assetRecordStore: widget.assetRecordStore,
                            person: person,
                            firstTaggedLocalId:
                                _members[person.id]?.firstOrNull,
                            records: _records,
                            size: 40,
                          ),
                          title: Text(person.name),
                          subtitle: Text(
                            '${s.current == null ? l10n.startedSuggestNone : day.format(s.current!)}'
                            ' → ${day.format(s.suggested)} · '
                            '${l10n.startedSuggestFrom(s.group.name)}',
                          ),
                          trailing: Icon(
                            picked
                                ? CupertinoIcons.checkmark_circle_fill
                                : CupertinoIcons.circle,
                            color: picked
                                ? settingsAccent
                                : CupertinoColors.systemGrey2,
                          ),
                          onTap: () => _toggle(person.id),
                        );
                      },
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(settingsPagePadding),
                    child: SizedBox(
                      width: double.infinity,
                      child: CupertinoButton.filled(
                        key: const ValueKey('startedApply'),
                        onPressed: _picked.isEmpty || _busy ? null : _apply,
                        child: Text(l10n.startedSuggestApply(_picked.length)),
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
