import '../storage/asset_record.dart';

/// A day, or a run of back-to-back days, busy enough to be an album:
/// [AlbumSuggestions.perDay] or more photos in no album each day.
class AlbumSuggestion {
  AlbumSuggestion({
    required this.first,
    required this.last,
    required this.records,
  });

  /// Local calendar days, midnight.
  final DateTime first;
  final DateTime last;

  /// Oldest first.
  final List<AssetRecord> records;

  /// Stable across rescans, so a dismissal sticks.
  String get key => '${_day(first)}-${_day(last)}';

  int get days => last.difference(first).inDays + 1;

  /// The place most of them were taken, if any has one.
  String? get place {
    final counts = <String, int>{};
    for (final r in records) {
      final at = r.location;
      if (at != null && at.isNotEmpty) counts[at] = (counts[at] ?? 0) + 1;
    }
    if (counts.isEmpty) return null;
    return counts.entries.reduce((a, b) => b.value > a.value ? b : a).key;
  }

  static String _day(DateTime d) =>
      '${d.year}${d.month.toString().padLeft(2, '0')}'
      '${d.day.toString().padLeft(2, '0')}';
}

abstract final class AlbumSuggestions {
  static const perDay = 10;

  /// App state: keys of suggestions the user waved off.
  static const dismissedKey = 'album_suggestions_dismissed_v1';

  /// Newest first. [home] is the library grid ([LibraryIndex.home]: visible,
  /// not archived), in grid order; [filed] the ids in any album.
  ///
  /// One pass over [home]. On the UI isolate, knowingly: run on opening
  /// Suggestions and after an action there, never per build, and copying
  /// the records to an isolate costs more than the pass.
  static List<AlbumSuggestion> of(
    List<AssetRecord> home,
    Set<String> filed, {
    Set<String> dismissed = const {},
  }) {
    final byDay = <DateTime, List<AssetRecord>>{};
    for (final r in home) {
      if (filed.contains(r.localId)) continue;
      final at = r.createdAt.toLocal();
      (byDay[DateTime(at.year, at.month, at.day)] ??= []).add(r);
    }
    final busy = byDay.keys.where((d) => byDay[d]!.length >= perDay).toList()
      ..sort();
    final out = <AlbumSuggestion>[];
    var i = 0;
    while (i < busy.length) {
      var j = i;
      while (j + 1 < busy.length && _nextDay(busy[j]) == busy[j + 1]) {
        j++;
      }
      final suggestion = AlbumSuggestion(
        first: busy[i],
        last: busy[j],
        records: [for (var k = i; k <= j; k++) ...byDay[busy[k]]!],
      );
      if (!dismissed.contains(suggestion.key)) out.add(suggestion);
      i = j + 1;
    }
    return out.reversed.toList();
  }

  /// Calendar arithmetic, not 24 hours: a daylight-saving day is 23 or 25.
  static DateTime _nextDay(DateTime d) => DateTime(d.year, d.month, d.day + 1);
}
