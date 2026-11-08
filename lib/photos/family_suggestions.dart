import 'name_parts.dart';
import 'person.dart';

/// People sharing a surname who may be one family. Applying it puts them in
/// one family group ([into], or a new one) — the links follow from that.
class FamilySuggestion {
  const FamilySuggestion({
    required this.surname,
    required this.personIds,
    this.into,
  });

  final String surname;
  final List<String> personIds;

  /// A family group some of them are already in; the rest join it.
  final PersonGroup? into;
}

/// A surname alone is evidence only when it's rare. Chinese surnames, and
/// the romanized ones most common across East and Southeast Asia, are each
/// shared by tens of millions, so those need more:
///
/// - written in Chinese: the same generation character (王**小**明, 王**小**红
///   — siblings and cousins are often named that way) and at least one
///   photo together;
/// - romanized: at least [romanizedPhotos] photos together.
///
/// Locked people are left out (ignored ones count), and so is a cluster every pair
/// of which is already family. Bounded by people, plus the photos of those
/// with common surnames.
List<FamilySuggestion> familySuggestions({
  required List<Person> people,
  required Map<PersonGroup, List<String>> groups,
  required List<PersonRelationship> relationships,
  required Map<String, List<String>> photosOf,
  int romanizedPhotos = 2,
}) {
  final bySurname = <String, List<Person>>{};
  final shown = <String, String>{};
  for (final p in people) {
    if (p.locked) continue;
    final surname = surnameOf(p);
    if (surname.isEmpty) continue;
    final key = _isChinese(surname) ? surname : surname.toLowerCase();
    (bySurname[key] ??= []).add(p);
    shown[key] ??= surname;
  }

  final clusters = <(String, List<String>)>[];
  final needPhotos = <List<Person>>[];
  for (final MapEntry(key: key, value: members) in bySurname.entries) {
    if (members.length < 2) continue;
    if (_isChinese(key)) {
      final byGeneration = <String, List<Person>>{};
      for (final p in members) {
        final given = givenNameOf(p, key);
        if (given.length != 2) continue;
        (byGeneration[given[0]] ??= []).add(p);
      }
      needPhotos.addAll(byGeneration.values.where((m) => m.length > 1));
    } else if (_commonRomanized.contains(key)) {
      needPhotos.add(members);
    } else {
      clusters.add((shown[key]!, [for (final p in members) p.id]));
    }
  }

  if (needPhotos.isNotEmpty) {
    final shared = _sharedPhotos({
      for (final m in needPhotos)
        for (final p in m) p.id,
    }, photosOf);
    for (final members in needPhotos) {
      final surname = surnameOf(members.first);
      final min = _isChinese(surname) ? 1 : romanizedPhotos;
      final kept = [
        for (final p in members)
          if (members.any(
            (o) => o.id != p.id && (shared[_pair(p.id, o.id)] ?? 0) >= min,
          ))
            p.id,
      ];
      if (kept.length > 1) clusters.add((surname, kept));
    }
  }

  final family = _familyPairs(groups, relationships);
  final familyGroups = [
    for (final MapEntry(key: g, value: m) in groups.entries)
      if (g.kind == GroupKind.family) (g, m.toSet()),
  ];
  return [
    for (final (surname, ids) in clusters)
      if (!_allLinked(ids, family))
        FamilySuggestion(
          surname: surname,
          personIds: ids,
          into: _bestGroup(ids, familyGroups),
        ),
  ]..sort((a, b) => a.surname.compareTo(b.surname));
}

String surnameOf(Person p) {
  final last = p.lastName.trim();
  return last.isNotEmpty ? last : suggestNameParts(p.name).last;
}

/// The given name, for a Chinese name: what follows the surname.
String givenNameOf(Person p, String surname) {
  final first = p.firstName.trim();
  if (first.isNotEmpty) return first;
  final name = p.name.trim();
  return name.startsWith(surname) ? name.substring(surname.length) : '';
}

bool _isChinese(String s) => RegExp(r'[㐀-鿿]').hasMatch(s);

String _pair(String a, String b) =>
    a.compareTo(b) < 0 ? '$a\u0000$b' : '$b\u0000$a';

/// Photos each pair among [ids] is in together.
Map<String, int> _sharedPhotos(
  Set<String> ids,
  Map<String, List<String>> photosOf,
) {
  final inPhoto = <String, List<String>>{};
  for (final id in ids) {
    for (final photo in photosOf[id] ?? const <String>[]) {
      (inPhoto[photo] ??= []).add(id);
    }
  }
  final counts = <String, int>{};
  for (final together in inPhoto.values) {
    for (var i = 0; i < together.length; i++) {
      for (var j = i + 1; j < together.length; j++) {
        final key = _pair(together[i], together[j]);
        counts[key] = (counts[key] ?? 0) + 1;
      }
    }
  }
  return counts;
}

Set<String> _familyPairs(
  Map<PersonGroup, List<String>> groups,
  List<PersonRelationship> relationships,
) => {
  for (final r in relationships)
    if (isFamilyRelationship(r.type)) _pair(r.personId, r.relatedPersonId),
  for (final MapEntry(key: g, value: m) in groups.entries)
    if (g.kind == GroupKind.family)
      for (var i = 0; i < m.length; i++)
        for (var j = i + 1; j < m.length; j++) _pair(m[i], m[j]),
};

bool _allLinked(List<String> ids, Set<String> family) {
  for (var i = 0; i < ids.length; i++) {
    for (var j = i + 1; j < ids.length; j++) {
      if (!family.contains(_pair(ids[i], ids[j]))) return false;
    }
  }
  return true;
}

/// The family group holding most of [ids], if any holds one.
PersonGroup? _bestGroup(
  List<String> ids,
  List<(PersonGroup, Set<String>)> familyGroups,
) {
  PersonGroup? best;
  var most = 0;
  for (final (group, members) in familyGroups) {
    final n = ids.where(members.contains).length;
    if (n > most) {
      most = n;
      best = group;
    }
  }
  return best;
}

/// Romanized surnames each shared by tens of millions — Chinese (pinyin,
/// Cantonese, Hokkien), Korean, Vietnamese — lowercase.
final _commonRomanized =
    ('wang li lee zhang chang cheung liu lau chen chan tan yang yeung '
            'huang wong ng zhao chiu wu woo goh zhou chow chou xu hsu tsui sun '
            'ma zhu chu hu guo kuo kwok he ho lin lam lim gao kao luo law lo '
            'zheng cheng liang leung xie tse song tang tong han hon feng fung '
            'deng cao tsao peng pang zeng tseng tsang xiao siu tian dong tung '
            'pan poon yuan yuen cai tsai choi jiang chiang yu yue du ye yip ip '
            'wei su so lu lui ding ren shen sum yao xue jin kam fan zhong chung '
            'ong teo koh chua kim park jung jeong kang cho yoon jang shin seo '
            'kwon hwang ahn nguyen tran le pham hoang huynh phan vu vo dang bui '
            'do ngo duong ly')
        .split(' ')
        .toSet();
