import 'package:flutter/cupertino.dart';

import '../l10n/app_localizations.dart';
import '../photos/person.dart';
import '../photos/person_detail.dart';
import 'person_traits_editor.dart';
import 'profile_section.dart';

enum DetailGroup { general, contact, records }

/// One shown row: every field under the same label, merged.
typedef DetailRow = ({String label, List<String> values, List<int> fields});

const _contactWords = [
  'phone',
  'mobile',
  'email',
  'e-mail',
  'qq',
  'wechat',
  'whatsapp',
  'telegram',
  'instagram',
  'facebook',
  'linkedin',
  'twitter',
  'website',
  'address',
  '电话',
  '手机',
  '邮箱',
  '微信',
  '地址',
  '网站',
];

DetailGroup detailGroupOf(String label) {
  final l = label.toLowerCase();
  if (l.contains('record') || l == 'messages' || l.contains('记录')) {
    return DetailGroup.records;
  }
  if (!l.contains('group') && _contactWords.any(l.contains)) {
    return DetailGroup.contact;
  }
  return DetailGroup.general;
}

final _source = RegExp(r'\s*\([^)]*\)$');

/// Same-named fields as one row each, grouped. Imports write one set per
/// source, so "First record" keeps the earliest date and "Last record" the
/// latest, without the source; lists of phones or message counts are split
/// and deduplicated.
Map<DetailGroup, List<DetailRow>> groupDetails(List<PersonCustomField> fields) {
  final order = <String>[];
  final labels = <String, String>{};
  final byLabel = <String, List<int>>{};
  for (var i = 0; i < fields.length; i++) {
    final label = fields[i].label.trim();
    if (label.isEmpty && fields[i].value.trim().isEmpty) continue;
    final key = label.toLowerCase();
    if (!byLabel.containsKey(key)) order.add(key);
    labels.putIfAbsent(key, () => label);
    (byLabel[key] ??= []).add(i);
  }
  final groups = <DetailGroup, List<DetailRow>>{};
  for (final key in order) {
    final label = labels[key]!;
    final group = detailGroupOf(label);
    final raw = [
      for (final i in byLabel[key]!)
        if (fields[i].value.trim().isNotEmpty) fields[i].value.trim(),
    ];
    final List<String> values;
    if (group == DetailGroup.records && key.contains('record')) {
      final dates = [for (final v in raw) v.replaceFirst(_source, '')]..sort();
      values = dates.isEmpty
          ? const []
          : [key.contains('last') ? dates.last : dates.first];
    } else if (group != DetailGroup.general) {
      values = {
        for (final v in raw)
          for (final part in v.split(RegExp(r',\s*')))
            if (part.isNotEmpty) part,
      }.toList();
    } else {
      values = raw.toSet().toList();
    }
    (groups[group] ??= []).add((
      label: label,
      values: values,
      fields: byLabel[key]!,
    ));
  }
  for (final rows in groups.values) {
    rows.sort((a, b) => _rank(a.label).compareTo(_rank(b.label)));
  }
  return groups;
}

int _rank(String label) {
  final l = label.toLowerCase();
  if (l.contains('first')) return 0;
  if (l.contains('last')) return 1;
  return 2;
}

/// More Details as read: filled traits and merged fields in one card, then
/// Contact and Records. Editing the raw list is the header's Edit.
class ProfileDetails extends StatelessWidget {
  const ProfileDetails({
    super.key,
    required this.traits,
    required this.fields,
    required this.onTrait,
    required this.onRow,
  });

  final Map<String, String> traits;
  final List<PersonCustomField> fields;
  final ValueChanged<PersonTrait> onTrait;
  final ValueChanged<DetailRow> onRow;

  static int rowCount(Map<String, String> traits, List<PersonCustomField> f) =>
      traits.values.where((v) => v.isNotEmpty).length +
      groupDetails(f).values.fold(0, (n, rows) => n + rows.length);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final groups = groupDetails(fields);
    final filled = [
      for (final t in personTraits)
        if ((traits[t.key] ?? '').isNotEmpty) t,
    ];
    final general = [
      for (final t in filled)
        _Row(
          key: traitRowKey(t.key),
          label: traitLabel(l10n, t.key),
          values: [traitValueLabel(l10n, t.key, traits[t.key]!)],
          onTap: () => onTrait(t),
        ),
      for (final r in groups[DetailGroup.general] ?? const <DetailRow>[])
        _rowOf(r),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (general.isNotEmpty) _card(null, general),
        for (final (group, title) in [
          (DetailGroup.contact, l10n.traitContact),
          (DetailGroup.records, l10n.profileDetailsRecords),
        ])
          if (groups[group] case final rows? when rows.isNotEmpty)
            _card(title, [for (final r in rows) _rowOf(r)]),
      ],
    );
  }

  Widget _rowOf(DetailRow r) => _Row(
    key: ValueKey('detail:${r.label}'),
    label: r.label,
    values: r.values,
    onTap: () => onRow(r),
  );

  Widget _card(String? title, List<Widget> rows) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (title != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
            child: Text(
              title.toUpperCase(),
              style: const TextStyle(
                fontSize: 12,
                color: CupertinoColors.systemGrey,
              ),
            ),
          ),
        Container(
          decoration: profileCardDecoration,
          child: Column(
            children: [
              for (var i = 0; i < rows.length; i++) ...[
                if (i > 0)
                  const Padding(
                    padding: EdgeInsets.only(left: 16),
                    child: SizedBox(
                      height: 0.5,
                      width: double.infinity,
                      child: ColoredBox(color: CupertinoColors.separator),
                    ),
                  ),
                rows[i],
              ],
            ],
          ),
        ),
      ],
    ),
  );
}

class _Row extends StatelessWidget {
  const _Row({
    super.key,
    required this.label,
    required this.values,
    required this.onTap,
  });

  final String label;
  final List<String> values;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 2,
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 15,
                color: CupertinoColors.systemGrey,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 3,
            child: Text(
              values.join('\n'),
              textAlign: TextAlign.end,
              style: const TextStyle(
                fontSize: 15,
                color: CupertinoColors.white,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
