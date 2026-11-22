import 'package:flutter/cupertino.dart';

import '../l10n/app_localizations.dart';
import '../photos/person.dart';
import '../photos/person_detail.dart';
import 'person_traits_editor.dart';

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

/// More Details as two-column cards: filled traits and merged fields, then
/// Contact and Records each under its own heading, rows shaded in turn. Editing the
/// raw list is the header's Edit.
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
    final general = <Widget Function(bool)>[
      for (final t in filled)
        (odd) => _Row(
          key: traitRowKey(t.key),
          label: traitLabel(l10n, t.key),
          values: [traitValueLabel(l10n, t.key, traits[t.key]!)],
          odd: odd,
          onTap: () => onTrait(t),
        ),
      for (final r in groups[DetailGroup.general] ?? const <DetailRow>[])
        _rowOf(r),
    ];
    final sections = [
      if (general.isNotEmpty) (null, general),
      for (final (group, title) in [
        (DetailGroup.contact, l10n.traitContact),
        (DetailGroup.records, l10n.profileDetailsRecords),
      ])
        if (groups[group] case final rows? when rows.isNotEmpty)
          (title, [for (final r in rows) _rowOf(r)]),
    ];
    return Padding(
      key: const ValueKey('detailsSheet'),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (i, (title, rows)) in sections.indexed) ...[
            if (title != null)
              Padding(
                padding: EdgeInsets.fromLTRB(4, i == 0 ? 0 : 18, 4, 6),
                child: Text(
                  title.toUpperCase(),
                  style: const TextStyle(
                    fontSize: 12,
                    letterSpacing: 0.4,
                    color: CupertinoColors.systemGrey,
                  ),
                ),
              )
            else if (i > 0)
              const SizedBox(height: 18),
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [for (final (n, row) in rows.indexed) row(n.isOdd)],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget Function(bool odd) _rowOf(DetailRow r) =>
      (odd) => _Row(
        key: ValueKey('detail:${r.label}'),
        label: r.label,
        values: r.values,
        odd: odd,
        onTap: () => onRow(r),
      );
}

/// One row: label, then value; every other row shaded.
class _Row extends StatelessWidget {
  const _Row({
    super.key,
    required this.label,
    required this.values,
    required this.odd,
    required this.onTap,
  });

  final String label;
  final List<String> values;
  final bool odd;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: onTap,
    child: ColoredBox(
      color: odd ? const Color(0xFF242426) : const Color(0xFF1C1C1E),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 112,
              child: Text(
                label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 15,
                  height: 1.3,
                  color: CupertinoColors.systemGrey,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                values.join('\n'),
                style: const TextStyle(
                  fontSize: 15,
                  height: 1.3,
                  color: CupertinoColors.white,
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
