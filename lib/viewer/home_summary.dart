import 'dart:convert';

/// What the People and Albums rows showed last time: order, counts, first
/// photos and covers. Drawn at launch before the full library read (most of
/// a second on a big library), then replaced by the real thing. Derived
/// data only — nothing here that isn't rebuilt from the stores.
class HomeSummary {
  const HomeSummary({
    required this.people,
    required this.personCounts,
    required this.personFirsts,
    required this.albumCounts,
    required this.albumCovers,
  });

  static const appStateKey = 'home_summary';

  final List<String> people;
  final Map<String, int> personCounts;
  final Map<String, String> personFirsts;
  final Map<String, int> albumCounts;
  final Map<String, String> albumCovers;

  String encode() => jsonEncode({
    'people': people,
    'personCounts': personCounts,
    'personFirsts': personFirsts,
    'albumCounts': albumCounts,
    'albumCovers': albumCovers,
  });

  /// Null for anything unreadable: the launch just waits for the real read.
  static HomeSummary? decode(String? text) {
    if (text == null) return null;
    try {
      final json = jsonDecode(text) as Map<String, dynamic>;
      return HomeSummary(
        people: (json['people'] as List).cast<String>(),
        personCounts: (json['personCounts'] as Map).cast<String, int>(),
        personFirsts: (json['personFirsts'] as Map).cast<String, String>(),
        albumCounts: (json['albumCounts'] as Map).cast<String, int>(),
        albumCovers: (json['albumCovers'] as Map).cast<String, String>(),
      );
    } catch (_) {
      return null;
    }
  }
}
