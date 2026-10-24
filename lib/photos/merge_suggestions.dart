import 'person.dart';

/// Two people who are probably one: the same name, or one name inside the
/// other ("Mia" and "Mia Chen", "小明" and "王小明").
class MergeSuggestion {
  const MergeSuggestion(this.a, this.b, {required this.sameName});

  final Person a;
  final Person b;
  final bool sameName;

  /// Order-free, so a dismissal holds whichever way round it comes back.
  String get key {
    final ids = [a.id, b.id]..sort();
    return ids.join('|');
  }

  static const dismissedKey = 'merge_suggestions_dismissed_v1';

  /// Every likely pair among [people], same names first. A name of one
  /// letter matches nothing: "A" is inside half the list.
  static List<MergeSuggestion> of(
    List<Person> people, {
    Set<String> dismissed = const {},
  }) {
    String norm(String s) =>
        s.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
    final names = [for (final p in people) norm(p.name)];
    final words = [for (final n in names) n.split(' ').toSet()];
    final same = <MergeSuggestion>[];
    final inside = <MergeSuggestion>[];
    for (var i = 0; i < people.length; i++) {
      final x = names[i];
      if (x.length < 2) continue;
      for (var j = i + 1; j < people.length; j++) {
        final y = names[j];
        if (y.length < 2) continue;
        final MergeSuggestion found;
        if (x == y) {
          found = MergeSuggestion(people[i], people[j], sameName: true);
        } else if (_within(x, words[i], y, words[j])) {
          found = MergeSuggestion(people[i], people[j], sameName: false);
        } else {
          continue;
        }
        if (dismissed.contains(found.key)) continue;
        (found.sameName ? same : inside).add(found);
      }
    }
    return [...same, ...inside];
  }

  /// [a] and [b] are one name, or one holds the other — the same test
  /// [of] pairs people by.
  static bool alike(String a, String b) {
    String norm(String s) =>
        s.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
    final x = norm(a), y = norm(b);
    if (x.length < 2 || y.length < 2) return false;
    return x == y || _within(x, x.split(' ').toSet(), y, y.split(' ').toSet());
  }

  /// Whole words for spaced names. Unspaced, a Chinese name holds a
  /// shorter one anywhere ("王小明" holds "小明"); a Latin one only as its
  /// start, three letters or more ("Tommy" holds "Tom", "Lily" not "Li").
  static bool _within(String x, Set<String> xw, String y, Set<String> yw) {
    final (short, shortWords, long, longWords) = x.length <= y.length
        ? (x, xw, y, yw)
        : (y, yw, x, xw);
    if (short.contains(' ') || long.contains(' ')) {
      return shortWords.every(longWords.contains);
    }
    if (_latin.hasMatch(short)) {
      return short.length >= 3 && long.startsWith(short);
    }
    return long.contains(short);
  }

  static final _latin = RegExp(r'^[\x00-\x7F]+$');
}
