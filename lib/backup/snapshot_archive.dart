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

/// A final copy made immediately before the user removes their app data.
///
/// The leading sentinel makes it sort after daily archives, so a later
/// empty daily backup cannot become the copy restored on a fresh install.
String removalArchiveName(DateTime at) =>
    '99999999-before-removal-'
    '${at.year.toString().padLeft(4, '0')}'
    '${at.month.toString().padLeft(2, '0')}'
    '${at.day.toString().padLeft(2, '0')}-'
    '${at.hour.toString().padLeft(2, '0')}'
    '${at.minute.toString().padLeft(2, '0')}'
    '${at.second.toString().padLeft(2, '0')}.zip';

/// `202609.zip` — what builds before daily copies wrote. Still read, still
/// counted when pruning, never written.
String monthlyArchiveName(DateTime at) =>
    '${at.year.toString().padLeft(4, '0')}'
    '${at.month.toString().padLeft(2, '0')}.zip';

bool isDailyArchiveName(String name) => RegExp(r'^\d{8}\.zip$').hasMatch(name);

bool isMonthlyArchiveName(String name) =>
    RegExp(r'^\d{6}\.zip$').hasMatch(name);

/// True for a name this app would have written, of either generation —
/// what tells its own backups apart from anything else sharing the folder.
///
/// Both sort correctly against each other: `202609` orders before every
/// `202609xx`, so a mixed folder still answers "the newest" by name.
bool isSnapshotArchiveName(String name) =>
    isDailyArchiveName(name) ||
    isMonthlyArchiveName(name) ||
    RegExp(r'^99999999-before-removal-\d{8}-\d{6}\.zip$').hasMatch(name);

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
