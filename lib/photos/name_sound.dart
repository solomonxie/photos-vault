import 'pinyin.dart';

/// A name as letters: pinyin for Chinese, and for a Latin name also a
/// rough sound ("Catherine" and "Katherine" are one).
class NameSound {
  const NameSound._(this.letters, this.sound, this._initials, this._tails);

  final String letters;

  /// Null for Chinese: pinyin is already how it sounds, and the Latin
  /// rules would fold "zhang" into "sang".
  final String? sound;

  /// First letter of each word or syllable: "王小明" is "wxm".
  final String _initials;

  /// The heard name from each word or syllable on, so a search may start
  /// anywhere: "xiaoming", "ming".
  final List<String> _tails;

  factory NameSound.of(String name) {
    final words = _words(name.toLowerCase());
    final letters = words.join();
    final han = hasHan(name);
    final heard = han ? words : [for (final w in words) _soundOf(w)];
    return NameSound._(
      letters,
      han ? null : _soundOf(letters),
      [for (final w in words) w[0]].join(),
      [for (var i = 0; i < heard.length; i++) heard.skip(i).join()],
    );
  }

  static List<String> _words(String s) {
    final out = <String>[];
    final run = StringBuffer();
    void flush() {
      if (run.isEmpty) return;
      out.add(run.toString());
      run.clear();
    }

    for (final r in s.runes) {
      final ch = String.fromCharCode(r);
      if (hasHan(ch)) {
        flush();
        final syllable = _lettersOnly(pinyinOf(ch, surnameFirst: out.isEmpty));
        if (syllable.isNotEmpty) out.add(syllable);
      } else if (_letter.hasMatch(ch)) {
        run.write(ch);
      } else {
        flush();
      }
    }
    flush();
    return out;
  }

  static final _letter = RegExp('[a-z]');

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
  bool alike(NameSound other) {
    final a = letters, b = other.letters;
    if (a.length < 4 || b.length < 4) return false;
    if (a == b) return true;
    if (sound != null && sound == other.sound) return true;
    final x = sound ?? a, y = other.sound ?? b;
    final shorter = x.length < y.length ? x.length : y.length;
    return _withinSlips(x, y, _slips(shorter));
  }

  /// A search for [query] finds this name: by its letters or pinyin, its
  /// initials, how it sounds, or with a slip, from any word or syllable.
  bool answers(NameSound query) {
    final typed = query.letters;
    if (typed.isEmpty) return false;
    if (letters.contains(typed) || _initials.startsWith(typed)) return true;
    final heard = sound != null && query.sound != null
        ? query._tails.first
        : typed;
    if (heard.length < 3) return false;
    final slips = _slips(heard.length);
    for (final tail in _tails) {
      if (tail.startsWith(heard)) return true;
      for (var n = heard.length - slips; n <= heard.length + slips; n++) {
        if (n > 0 &&
            n <= tail.length &&
            _withinSlips(heard, tail.substring(0, n), slips)) {
          return true;
        }
      }
    }
    return false;
  }

  static int _slips(int length) => length >= 9 ? 2 : (length >= 5 ? 1 : 0);

  static bool _withinSlips(String a, String b, int slips) =>
      slips > 0 && _distance(a, b, slips) <= slips;

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

/// How well [name] answers [typed] (trimmed, lower case): 0 the whole
/// name, 1 its start, 2 a word's start, 3 anywhere in it, 4 by pinyin,
/// initials, sound or a slip; null not at all. Lower is better.
int? nameRank(String name, String typed, NameSound heard) {
  final lower = name.trim().toLowerCase();
  if (lower == typed) return 0;
  if (lower.startsWith(typed)) return 1;
  final at = lower.indexOf(typed);
  if (at > 0) return _letterOrDigit.hasMatch(lower[at - 1]) ? 3 : 2;
  return _soundOf(name).answers(heard) ? 4 : null;
}

final _letterOrDigit = RegExp(r'[\p{L}\p{N}]', unicode: true);

/// The best [nameRank] over several names: someone's name and former ones.
int? bestNameRank(Iterable<String> names, String typed, NameSound heard) {
  int? best;
  for (final n in names) {
    final r = nameRank(n, typed, heard);
    if (r != null && (best == null || r < best)) best = r;
    if (best == 0) break;
  }
  return best;
}

/// [items] whose name answers [query], best match first; ties keep their
/// order.
List<T> searchByName<T>(
  Iterable<T> items,
  String query,
  String Function(T) nameOf,
) => searchByNames(items, query, (item) => [nameOf(item)]);

/// [searchByName] over several names per item.
List<T> searchByNames<T>(
  Iterable<T> items,
  String query,
  Iterable<String> Function(T) namesOf,
) {
  final typed = query.trim().toLowerCase();
  if (typed.isEmpty) return items.toList();
  final heard = NameSound.of(typed);
  final tiers = List.generate(5, (_) => <T>[]);
  for (final item in items) {
    final rank = bestNameRank(namesOf(item), typed, heard);
    if (rank != null) tiers[rank].add(item);
  }
  return [for (final t in tiers) ...t];
}

/// Names read once a session: a search runs per keystroke over every one.
final _sounds = <String, NameSound>{};

NameSound _soundOf(String name) {
  if (_sounds.length > 20000) _sounds.clear();
  return _sounds[name] ??= NameSound.of(name);
}
