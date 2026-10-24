import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../photos/person.dart';
import '../photos/person_detail.dart';
import '../photos/person_store.dart';
import '../settings/settings_section.dart';
import 'person_event_sheet.dart' show eventTypeLabel;
import 'person_profile_screen.dart' show relationshipTypeLabel;

/// Everything changed on one person, newest first: names they went by,
/// details, photos, groups, events, places and links.
class PersonChangeLogScreen extends StatefulWidget {
  const PersonChangeLogScreen({
    super.key,
    required this.person,
    required this.personStore,
  });

  final Person person;
  final PersonStore personStore;

  @override
  State<PersonChangeLogScreen> createState() => _PersonChangeLogScreenState();
}

/// Runs of photo adds or removes on one day read as one line.
class _Line {
  _Line(this.change) : count = 1;
  final PersonChange change;
  int count;
}

bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

class _PersonChangeLogScreenState extends State<PersonChangeLogScreen> {
  List<_Line>? _lines;
  Map<String, String> _names = const {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final changes = await widget.personStore.changesOf(widget.person.id);
    final names = {
      for (final p in await widget.personStore.listAll()) p.id: p.name,
    };
    final lines = <_Line>[];
    for (final c in changes) {
      final last = lines.lastOrNull;
      if (last != null &&
          c.kind.startsWith('photo_') &&
          last.change.kind == c.kind &&
          _sameDay(last.change.at, c.at)) {
        last.count++;
      } else {
        lines.add(_Line(c));
      }
    }
    if (!mounted) return;
    setState(() {
      _lines = lines;
      _names = names;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final lines = _lines;
    return CupertinoPageScaffold(
      backgroundColor: settingsPageBackground,
      navigationBar: CupertinoNavigationBar(
        backgroundColor: settingsPageBackground,
        middle: Text(l10n.personChangesTitle),
      ),
      child: SafeArea(
        child: lines == null
            ? const Center(child: CupertinoActivityIndicator())
            : lines.isEmpty
            ? Center(
                child: Text(l10n.personChangesEmpty, style: settingsHintStyle),
              )
            : ListView.separated(
                padding: const EdgeInsets.all(settingsPagePadding),
                itemCount: lines.length,
                separatorBuilder: (_, _) => const SizedBox(height: 14),
                itemBuilder: (context, i) => _row(l10n, lines[i]),
              ),
      ),
    );
  }

  Widget _row(AppLocalizations l10n, _Line line) {
    final c = line.change;
    final at = DateFormat.yMMMd().add_jm().format(c.at);
    final (title, details) = describeChange(l10n, c, line.count, _names);
    return Column(
      key: ValueKey('personChange-${c.kind}-${c.at.millisecondsSinceEpoch}'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: settingsRowTitleStyle),
        for (final d in details)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(d, style: const TextStyle(fontSize: 13)),
          ),
        const SizedBox(height: 2),
        Text(at, style: settingsHintStyle),
      ],
    );
  }
}

/// A change in words: a title and the lines under it.
(String, List<String>) describeChange(
  AppLocalizations l10n,
  PersonChange c,
  int count,
  Map<String, String> names,
) {
  Map<String, Object?> json(String? s) {
    if (s == null || s.isEmpty) return const {};
    try {
      return (jsonDecode(s) as Map).cast<String, Object?>();
    } catch (_) {
      return const {};
    }
  }

  String arrow(String? a, String? b) =>
      '${(a ?? '').isEmpty ? '—' : a} → ${(b ?? '').isEmpty ? '—' : b}';

  String event(Map<String, Object?> e) {
    final type = PersonEventType.values
        .where((t) => t.name == e['type'])
        .firstOrNull;
    final at = e['at'] as int?;
    return [
      if (type != null) eventTypeLabel(l10n, type),
      if (at != null)
        DateFormat.yMMMd().format(DateTime.fromMillisecondsSinceEpoch(at)),
    ].join(' · ');
  }

  String link(Map<String, Object?> e) {
    final type = RelationshipType.values
        .where((t) => t.name == e['type'])
        .firstOrNull;
    return [
      names[e['person']] ?? '?',
      if (type != null) relationshipTypeLabel(l10n, type),
    ].join(' · ');
  }

  String background(Map<String, Object?> e) => [
    e['category'] == 'education'
        ? l10n.personProfileEducationLabel
        : l10n.personProfileJobLabel,
    '${e['title'] ?? ''}',
  ].join(' · ');

  return switch (c.kind) {
    'created' => (l10n.personChangeCreated, [?c.after]),
    'name' => (l10n.personChangeName, [arrow(c.before, c.after)]),
    'merged' => (l10n.personChangeMerged(c.before ?? ''), const []),
    'picture' => (l10n.personChangePicture, const []),
    'locked' => (
      c.after == '1' ? l10n.personChangeLocked : l10n.personChangeUnlocked,
      const [],
    ),
    'photo_added' => (l10n.personChangePhotosAdded(count), const []),
    'photo_removed' => (l10n.personChangePhotosRemoved(count), const []),
    'details' => (
      l10n.personChangeDetails,
      detailDiff(l10n, json(c.before), json(c.after)),
    ),
    'group_joined' => (l10n.personChangeGroupJoined, [?c.after]),
    'group_left' => (l10n.personChangeGroupLeft, [?c.before]),
    'event_added' => (l10n.personChangeEventAdded, [event(json(c.after))]),
    'event_changed' => (
      l10n.personChangeEventChanged,
      [arrow(event(json(c.before)), event(json(c.after)))],
    ),
    'event_removed' => (l10n.personChangeEventRemoved, [event(json(c.before))]),
    'place_added' => (l10n.personChangePlaceAdded, [?c.after]),
    'place_removed' => (l10n.personChangePlaceRemoved, [?c.before]),
    'background_added' => (
      l10n.personChangeBackgroundAdded,
      [background(json(c.after))],
    ),
    'background_removed' => (
      l10n.personChangeBackgroundRemoved,
      [background(json(c.before))],
    ),
    'link_added' => (l10n.personChangeLinkAdded, [link(json(c.after))]),
    'link_removed' => (l10n.personChangeLinkRemoved, [link(json(c.before))]),
    _ => (c.kind, const []),
  };
}

/// The fields of the details that differ, one line each.
List<String> detailDiff(
  AppLocalizations l10n,
  Map<String, Object?> before,
  Map<String, Object?> after,
) {
  final a = PersonDetail.fromJson(before);
  final b = PersonDetail.fromJson(after);
  String short(String s) =>
      s.length > 80 ? '${s.substring(0, 80).trimRight()}…' : s;
  String arrow(String x, String y) =>
      '${x.isEmpty ? '—' : short(x)} → ${y.isEmpty ? '—' : short(y)}';
  String day(DateTime? d) => d == null ? '' : DateFormat.yMMMd().format(d);
  final out = <String>[
    if (a.bio != b.bio) '${l10n.personChangeBio}: ${arrow(a.bio, b.bio)}',
    if (a.birthDate != b.birthDate)
      '${l10n.personChangeBirthday}: ${arrow(day(a.birthDate), day(b.birthDate))}',
    if (a.gender != b.gender)
      '${l10n.personChangeGender}: '
          '${arrow(a.gender?.name ?? '', b.gender?.name ?? '')}',
  ];
  final fieldsA = {for (final f in a.customFields) f.label: f.value};
  final fieldsB = {for (final f in b.customFields) f.label: f.value};
  for (final label in {...fieldsA.keys, ...fieldsB.keys}) {
    if (fieldsA[label] != fieldsB[label]) {
      out.add('$label: ${arrow(fieldsA[label] ?? '', fieldsB[label] ?? '')}');
    }
  }
  for (final key in {...a.traits.keys, ...b.traits.keys}) {
    if (a.traits[key] != b.traits[key]) {
      out.add('$key: ${arrow(a.traits[key] ?? '', b.traits[key] ?? '')}');
    }
  }
  if (jsonEncode(before['impression']) != jsonEncode(after['impression'])) {
    out.add(l10n.personChangeImpression);
  }
  return out;
}
