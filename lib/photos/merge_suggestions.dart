import 'dart:isolate';

import 'person.dart';
import 'pinyin.dart';

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
    final sounds = [for (final n in names) _Sound.of(n)];
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
        for (final p in people) _Sound.of(_norm(p.name)),
      ];
    }
    final mine = _Sound.of(_norm(name));
    return [
      for (final (i, p) in people.indexed)
        if (mine.alike(sounds[i])) p,
    ];
  }

  static final _soundsOf = Expando<List<_Sound>>();

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

/// A name as letters: pinyin for Chinese, and for a Latin name also a
/// rough sound ("Catherine" and "Katherine" are one).
class _Sound {
  const _Sound(this.letters, this.sound);

  final String letters;

  /// Null for Chinese: pinyin is already how it sounds, and the Latin
  /// rules would fold "zhang" into "sang".
  final String? sound;

  static _Sound of(String name) {
    if (hasHan(name)) {
      return _Sound(_lettersOnly(pinyinOf(name)), null);
    }
    final letters = _lettersOnly(name);
    return _Sound(letters, _soundOf(letters));
  }

  static String _lettersOnly(String s) => s.replaceAll(RegExp('[^a-z]'), '');

  static String _soundOf(String s) {
    final folded = s
        .replaceAll('ph', 'f')
        .replaceAll('ck', 'k')
        .replaceAll(RegExp('[cq]'), 'k')
        .replaceAll('z', 's')
        .replaceAll('y', 'i');
    final out = StringBuffer();
    for (final (i, c) in folded.split('').indexed) {
      if (i > 0 && (c == 'h' || c == folded[i - 1])) continue;
      out.write(c);
    }
    return out.toString().replaceFirst(RegExp(r'(?<=..)e$'), '');
  }

  /// Four letters or more to match by sound, five to allow a slip, nine
  /// to allow two: short names are a few edits from everyone.
  bool alike(_Sound other) {
    final a = letters, b = other.letters;
    if (a.length < 4 || b.length < 4) return false;
    if (a == b) return true;
    if (sound != null && sound == other.sound) return true;
    final x = sound ?? a, y = other.sound ?? b;
    final shorter = x.length < y.length ? x.length : y.length;
    final slips = shorter >= 9 ? 2 : (shorter >= 5 ? 1 : 0);
    return slips > 0 && _distance(x, y, slips) <= slips;
  }

  /// Edits, a swap of neighbours counting one; stops past [limit].
  static int _distance(String a, String b, int limit) {
    if ((a.length - b.length).abs() > limit) return limit + 1;
    var before = List<int>.filled(b.length + 1, 0);
    var row = List<int>.generate(b.length + 1, (j) => j);
    for (var i = 1; i <= a.length; i++) {
      final next = List<int>.filled(b.length + 1, 0)..[0] = i;
      var best = i;
      for (var j = 1; j <= b.length; j++) {
        final cost = a[i - 1] == b[j - 1] ? 0 : 1;
        var d = row[j - 1] + cost;
        if (row[j] + 1 < d) d = row[j] + 1;
        if (next[j - 1] + 1 < d) d = next[j - 1] + 1;
        if (i > 1 &&
            j > 1 &&
            a[i - 1] == b[j - 2] &&
            a[i - 2] == b[j - 1] &&
            before[j - 2] + 1 < d) {
          d = before[j - 2] + 1;
        }
        next[j] = d;
        if (d < best) best = d;
      }
      if (best > limit) return limit + 1;
      before = row;
      row = next;
    }
    return row[b.length];
  }
}
