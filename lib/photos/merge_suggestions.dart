import 'dart:isolate';

import 'person.dart';
import 'name_sound.dart';

/// Two people who are probably one: the same name, one name inside the
/// other ("Mia" and "Mia Chen", "小明" and "王小明"), or names that sound
/// or are spelt nearly alike ("Catherine" and "Katherine", "小明", "晓明"
/// and "Xiao Ming").
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

  /// [of] off the UI isolate: the sound and spelling tests are a pass
  /// per pair.
  static Future<List<MergeSuggestion>> find(
    List<Person> people, {
    Set<String> dismissed = const {},
  }) => Isolate.run(() => of(people, dismissed: dismissed));

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
    final sounds = [for (final n in names) NameSound.of(n)];
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
        } else if (_within(x, words[i], y, words[j]) ||
            sounds[i].alike(sounds[j])) {
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

  /// Of [people], those whose names sound or are spelt nearly like
  /// [name] — the test [of] adds to [alike]. Each list's sounds are worked
  /// out once, so an import asking per row is a pass per row, not a pinyin
  /// lookup per row per person.
  static List<Person> soundingLike(String name, List<Person> people) {
    var sounds = _soundsOf[people];
    if (sounds == null || sounds.length != people.length) {
      sounds = _soundsOf[people] = [
        for (final p in people) NameSound.of(_norm(p.name)),
      ];
    }
    final mine = NameSound.of(_norm(name));
    return [
      for (final (i, p) in people.indexed)
        if (mine.alike(sounds[i])) p,
    ];
  }

  static final _soundsOf = Expando<List<NameSound>>();

  static String _norm(String s) =>
      s.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

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
