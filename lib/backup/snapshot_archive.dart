import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'app_snapshot.dart';

/// One payload, every destination. The file the share sheet hands out, the
/// one in iCloud Drive, the one in the bucket and the one in the Files app
/// are the same bytes — only where they land differs.
///
/// ```
/// 20260918.zip
/// ├── library.json      the snapshot: user-authored data, no secrets
/// └── change-log.json   every row write since the log began
/// ```
///
/// The snapshot entry keeps its old name so a backup taken by any build
/// this app has ever shipped still reads. Zipped because it is JSON, and
/// JSON of a whole library compresses to roughly a tenth of itself.
const snapshotEntryName = 'library.json';

/// The append-only log, carried so the record outlives the phone. Read by
/// a person, never by [unzipSnapshot] — the ids in it were remapped on the
/// way in and mean nothing on the other side.
const changeLogEntryName = 'change-log.json';

/// `20260918.zip` — sorts by date as a string, which is what lets "the
/// newest backup" be answered by sorting names rather than by asking every
/// file when it was written.
String dailyArchiveName(DateTime at) =>
    '${at.year.toString().padLeft(4, '0')}'
    '${at.month.toString().padLeft(2, '0')}'
    '${at.day.toString().padLeft(2, '0')}.zip';

/// The app these archives belong to — last in every name, after the
/// datetime and the purpose, so a folder shared with another app's
/// backups still sorts chronologically rather than by whose they are.
const archiveAppName = 'photos-vault';

/// `20260918-143210-pre-deletion-photos-vault.zip` — a final copy made
/// immediately before the user removes their app data.
///
/// To the second, because a second wipe from an already-empty library
/// must not overwrite the copy holding the real data.
String preDeletionArchiveName(DateTime at) =>
    '${archiveStamp(at)}-pre-deletion-$archiveAppName.zip';

/// `20260918-143210` — the datetime every non-rolling copy leads with.
String archiveStamp(DateTime at) =>
    '${at.year.toString().padLeft(4, '0')}'
    '${at.month.toString().padLeft(2, '0')}'
    '${at.day.toString().padLeft(2, '0')}-'
    '${at.hour.toString().padLeft(2, '0')}'
    '${at.minute.toString().padLeft(2, '0')}'
    '${at.second.toString().padLeft(2, '0')}';

/// `202609.zip` — what builds before daily copies wrote. Still read, still
/// counted when pruning, never written.
String monthlyArchiveName(DateTime at) =>
    '${at.year.toString().padLeft(4, '0')}'
    '${at.month.toString().padLeft(2, '0')}.zip';

bool isDailyArchiveName(String name) => RegExp(r'^\d{8}\.zip$').hasMatch(name);

bool isMonthlyArchiveName(String name) =>
    RegExp(r'^\d{6}\.zip$').hasMatch(name);

/// True for a name this app would have written, of any generation — what
/// tells its own backups apart from anything else sharing the folder.
bool isSnapshotArchiveName(String name) =>
    isDailyArchiveName(name) ||
    isMonthlyArchiveName(name) ||
    isPreDeletionArchiveName(name);

/// All three spellings. The two `99999999-` ones are what earlier builds
/// wrote, and an archive already sitting in iCloud or a bucket still has
/// to be found, counted and restored from.
bool isPreDeletionArchiveName(String name) =>
    _preDeletion.hasMatch(name) || _legacyPreDeletion.hasMatch(name);

final _preDeletion = RegExp(
  '^(\\d{8}-\\d{6})-pre-deletion-$archiveAppName\\.zip\$',
);

final _legacyPreDeletion = RegExp(
  r'^99999999-(?:pre-deletion|before-removal)-(\d{8}-\d{6})\.zip$',
);

/// The archive a fresh install should restore from, or `null` when [names]
/// holds none of this app's.
///
/// A pre-deletion copy beats every dated one, whatever the dates say. That
/// used to be a property of the name — a `99999999-` sentinel that sorted
/// it last — which bought the ordering at the cost of a name nobody could
/// read. The rule it was encoding is this: emptying the library makes the
/// next daily backup empty too, and an empty backup written afterwards
/// must never be the copy a fresh install comes back to.
String? latestArchiveName(Iterable<String> names) {
  final mine = names.where(isSnapshotArchiveName).toList();
  if (mine.isEmpty) return null;
  final finals = mine.where(isPreDeletionArchiveName).toList();
  if (finals.isEmpty) return (mine..sort()).last;
  finals.sort(comparePreDeletionArchives);
  return finals.last;
}

/// Oldest first, by the datetime inside the name — which is where the three
/// generations of pre-deletion name disagree, so they cannot be sorted
/// against each other as strings.
int comparePreDeletionArchives(String a, String b) =>
    _stampIn(a).compareTo(_stampIn(b));

/// The datetime inside a pre-deletion name, wherever that generation put
/// it — leading in this one, trailing in the two before it.
String _stampIn(String name) =>
    (_preDeletion.firstMatch(name) ?? _legacyPreDeletion.firstMatch(name))
        ?.group(1) ??
    '';

Uint8List zipSnapshot(AppSnapshot snapshot, {Map<String, Object?>? changeLog}) {
  final archive = Archive()
    ..addFile(ArchiveFile.string(snapshotEntryName, snapshot.encode()));
  if (changeLog != null) {
    archive.addFile(
      ArchiveFile.string(changeLogEntryName, jsonEncode(changeLog)),
    );
  }
  return ZipEncoder().encodeBytes(archive);
}

/// `null` for anything that isn't one of these — a truncated download, a
/// file someone else put in the folder, or a snapshot from a newer build.
AppSnapshot? unzipSnapshot(List<int> bytes) {
  try {
    final archive = ZipDecoder().decodeBytes(
      bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
    );
    // The named entry first. Falling back to "any .json" is what lets a
    // hand-made or renamed archive still import, but it has to come second
    // now that a second .json rides along — picking the change log as the
    // snapshot would import an empty library over a good one.
    for (final file in archive.files) {
      if (file.isFile && file.name == snapshotEntryName) {
        return AppSnapshot.decode(utf8.decode(file.content));
      }
    }
    for (final file in archive.files) {
      if (!file.isFile) continue;
      if (file.name == changeLogEntryName) continue;
      if (!file.name.endsWith('.json')) continue;
      return AppSnapshot.decode(utf8.decode(file.content));
    }
  } catch (_) {
    // Not a zip, or not one of ours.
  }
  return null;
}
