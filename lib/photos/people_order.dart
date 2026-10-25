import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import 'people_zip.dart' show undatedImport;
import 'person.dart';
import 'pinyin.dart';
import 'person_store.dart';

/// How people are ordered, on People and on the home page alike.
enum PeopleSort { photos, firstMet, lastSeen, name }

const peopleSortKey = 'people_sort_v1';

Future<PeopleSort> loadPeopleSort(AssetRecordStore store) async {
  try {
    final saved = await store.getAppState(peopleSortKey);
    return PeopleSort.values.where((s) => s.name == saved).firstOrNull ??
        PeopleSort.lastSeen;
  } catch (_) {
    return PeopleSort.lastSeen;
  }
}

/// First met and last seen per person: their events, widened by the dates
/// of their visible photos ([visible] by id). One pass over memberships.
({Map<String, DateTime> first, Map<String, DateTime> last}) knownDates(
  List<Person> people,
  Map<String, List<String>> members,
  Map<String, AssetRecord> visible,
  Map<String, PersonSpan> spans,
) {
  final firstKnown = <String, DateTime>{};
  final lastKnown = <String, DateTime>{};
  DateTime? min(DateTime? a, DateTime? b) =>
      a == null || (b != null && b.isBefore(a)) ? b : a;
  DateTime? max(DateTime? a, DateTime? b) =>
      a == null || (b != null && b.isAfter(a)) ? b : a;
  for (final person in people) {
    DateTime? earliest, latest;
    for (final id in members[person.id] ?? const <String>[]) {
      final record = visible[id];
      // Undated files would make everyone "last seen" on import day.
      if (record == null || undatedImport(record)) continue;
      final at = record.createdAt;
      earliest = min(earliest, at);
      latest = max(latest, at);
    }
    final span = spans[person.id];
    final first = span?.firstMet ?? min(span?.earliest, earliest);
    final last = max(max(span?.lastSeen, span?.latest), latest);
    if (first != null) firstKnown[person.id] = first;
    if (last != null) lastKnown[person.id] = last;
  }
  return (first: firstKnown, last: lastKnown);
}

/// Sorts [people] in place. Undated last either way: unknown is not "long
/// ago".
void sortPeople(
  List<Person> people,
  PeopleSort sort, {
  Map<String, int> counts = const {},
  Map<String, DateTime> firstKnown = const {},
  Map<String, DateTime> lastKnown = const {},
}) {
  final keys = sort == PeopleSort.name
      ? {for (final p in people) p.id: nameSortKey(p.name)}
      : const <String, String>{};
  int byDate(Map<String, DateTime> at, Person a, Person b, bool newest) {
    final x = at[a.id], y = at[b.id];
    if (x == null || y == null) return x == null ? (y == null ? 0 : 1) : -1;
    return newest ? y.compareTo(x) : x.compareTo(y);
  }

  people.sort(
    (a, b) => switch (sort) {
      PeopleSort.photos => (counts[b.id] ?? 0).compareTo(counts[a.id] ?? 0),
      PeopleSort.firstMet => byDate(firstKnown, a, b, false),
      PeopleSort.lastSeen => byDate(lastKnown, a, b, true),
      PeopleSort.name => keys[a.id]!.compareTo(keys[b.id]!),
    },
  );
}

/// Chinese names by their pinyin, so "王小明" files under W beside "Wendy".
String nameSortKey(String name) =>
    (hasHan(name) ? pinyinOf(name) : name).trim().toLowerCase();

/// A–Z, or # for a name that starts with anything else.
String nameInitial(String name) {
  final key = nameSortKey(name);
  final c = key.isEmpty ? '' : key[0].toUpperCase();
  return _latinInitial.hasMatch(c) ? c : '#';
}

final _latinInitial = RegExp('^[A-Z]\$');

/// 0 on the day; a 29 February birthday falls on 1 March off leap years.
int daysToBirthday(DateTime born, DateTime today) {
  // UTC: a local day across a clock change is 23 or 25 hours.
  final day = DateTime.utc(today.year, today.month, today.day);
  DateTime on(int year) => DateTime.utc(year, born.month, born.day);
  var next = on(day.year);
  if (next.isBefore(day)) next = on(day.year + 1);
  return next.difference(day).inDays;
}
