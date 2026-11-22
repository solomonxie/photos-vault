import 'package:path/path.dart' as p;

import '../storage/asset_record.dart';

/// The name the photo came with: what a camera or app wrote, before this
/// app named the backup.
String? originalFileName(AssetRecord r) {
  final path = r.sourcePath;
  return path == null ? null : p.basename(path);
}

final _protocolName = RegExp(r'^\d{14}_[0-9a-f]{32}\.', caseSensitive: false);

final _stamp = RegExp(
  r'(?<!\d)((?:19[89]\d|20\d\d))[-_.]?(0[1-9]|1[0-2])[-_.]?(0[1-9]|[12]\d|3[01])'
  r'(?:[-_ T.]{0,3}([01]\d|2[0-3])[-_.:]?([0-5]\d)(?:[-_.:]?([0-5]\d)(?:\d{3})?)?)?(?!\d)',
);

/// The date a camera or app stamped into a file name — `IMG_20120304_101010`,
/// `IMG-20160612-WA0003`, `Screenshot_2015-03-04-10-10-10`, `PXL_2021…`.
/// Noon when the name has a day but no time. Null for names this app gave
/// its backups (their stamp is the date already stored), and for dates
/// before 1990 or still to come.
DateTime? dateInFileName(String name, {DateTime? now}) {
  if (_protocolName.hasMatch(name)) return null;
  final m = _stamp.firstMatch(name);
  if (m == null) return null;
  int at(int i, [int fallback = 0]) =>
      m.group(i) == null ? fallback : int.parse(m.group(i)!);
  final hasTime = m.group(4) != null;
  final date = DateTime(
    at(1),
    at(2),
    at(3),
    hasTime ? at(4) : 12,
    at(5),
    at(6),
  );
  // DateTime rolls 31 Feb over into March; that's not a date.
  if (date.month != at(2) || date.day != at(3)) return null;
  if (date.isAfter(now ?? DateTime.now())) return null;
  return date;
}

enum DateCheckReason {
  /// The file name carries a different day.
  nameDisagrees,

  /// No date in the file: it took the moment it was added.
  noOwnDate,
}

typedef DateCheck = ({
  AssetRecord record,
  DateCheckReason reason,
  DateTime? proposed,
});

/// How far apart the stored date and the add time may be for the date to be
/// taken as the add time itself.
const _addedWindow = Duration(minutes: 2);

/// Photos whose date looks wrong, for Suggestions. A date the user set is
/// never questioned. "No date of its own" is only judged for files added
/// here: a camera-roll photo taken a minute ago was added a minute ago too.
List<DateCheck> datesToCheck(Iterable<AssetRecord> records, {DateTime? now}) {
  final out = <DateCheck>[];
  for (final r in records) {
    if (!r.isVisibleInLibrary || r.dateSetAt != null) continue;
    final name = originalFileName(r);
    final named = name == null ? null : dateInFileName(name, now: now);
    final stored = r.createdAt.toLocal();
    if (named != null &&
        stored.difference(named).abs() > const Duration(days: 1)) {
      out.add((
        record: r,
        reason: DateCheckReason.nameDisagrees,
        proposed: named,
      ));
    } else if (named == null &&
        r.sourceType == AssetSourceType.manualFile &&
        r.createdAt.difference(r.addedAt).abs() < _addedWindow) {
      out.add((record: r, reason: DateCheckReason.noOwnDate, proposed: null));
    }
  }
  return out;
}
