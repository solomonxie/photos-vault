import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'app_snapshot.dart';
import 'data_files.dart';
import 'snapshot_index.dart';

/// One payload, every destination. The file the share sheet hands out, the
/// one in iCloud Drive, the one in the bucket and the one in the Files app
/// are the same bytes — only where they land differs.
///
/// ```
/// 20260918.zip
/// ├── library.json      the snapshot: user-authored data, no secrets
/// ├── index.csv         the same library, readable without this app
/// ├── change-log.json   every row write since the log began
/// └── data-files.json   which blobs hold the chats, writings and faces
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

/// The day's blob list. See `data_files.dart`.
const dataFilesEntryName = 'data-files.json';

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

Uint8List zipSnapshot(
  AppSnapshot snapshot, {
  Map<String, Object?>? changeLog,
  List<Map<String, Object?>>? dataFiles,
}) {
  final archive = Archive()
    ..addFile(ArchiveFile.string(snapshotEntryName, snapshot.encode()))
    // Never read back by this app — `library.json` beside it is what
    // restores. It rides along so that every copy of the backup, wherever
    // it ended up, can be opened by whoever has it without this app, this
    // phone or this account. See `snapshot_index.dart`.
    ..addFile(ArchiveFile.string(indexEntryName, indexCsv(snapshot)));
  if (changeLog != null) {
    archive.addFile(
      ArchiveFile.string(changeLogEntryName, jsonEncode(changeLog)),
    );
  }
  if (dataFiles != null) {
    archive.addFile(
      ArchiveFile.string(dataFilesEntryName, encodeDataFiles(dataFiles)),
    );
  }
  return ZipEncoder().encodeBytes(archive);
}

/// Just the blob list of an archive: empty when it has none (an older
/// build's), null when the bytes aren't a readable zip — which a caller
/// deciding what to delete must treat as "don't know".
List<DataFileEntry>? dataFilesIn(List<int> bytes) {
  try {
    final archive = ZipDecoder().decodeBytes(
      bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
    );
    for (final file in archive.files) {
      if (file.isFile && file.name == dataFilesEntryName) {
        return decodeDataFiles(utf8.decode(file.content));
      }
    }
    return const [];
  } catch (_) {
    return null;
  }
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
    final files = [
      for (final file in archive.files)
        if (file.isFile && file.name == dataFilesEntryName)
          ...decodeDataFiles(utf8.decode(file.content)),
    ];
    AppSnapshot? withFiles(AppSnapshot? s) =>
        s == null || files.isEmpty ? s : s.withDataFiles(files);
    for (final file in archive.files) {
      if (file.isFile && file.name == snapshotEntryName) {
        return withFiles(AppSnapshot.decode(utf8.decode(file.content)));
      }
    }
    for (final file in archive.files) {
      if (!file.isFile) continue;
      if (file.name == changeLogEntryName) continue;
      if (file.name == dataFilesEntryName) continue;
      if (!file.name.endsWith('.json')) continue;
      return withFiles(AppSnapshot.decode(utf8.decode(file.content)));
    }
  } catch (_) {
    // Not a zip, or not one of ours.
  }
  return null;
}

/// The day's copy, built once and shared by every destination a pause
/// writes to.
class SnapshotPayload {
  const SnapshotPayload({
    required this.zip,
    required this.csv,
    this.files,
    this.complete = true,
  });

  final Uint8List zip;

  /// [indexCsv] of the same snapshot, for the loose `index.csv`.
  final String csv;

  /// The blobs [zip]'s `data-files.json` names, staged on this phone. A
  /// destination must have every one of them before it writes [zip] —
  /// otherwise the zip points at data that isn't there. Null: nothing to
  /// send (no stores wired, as in most tests).
  final DataFileSet? files;

  /// False when the stores outside `library.json` couldn't be gathered.
  /// An off-device destination then writes nothing: a zip without them
  /// would restore as if the chats and writings had never existed, and
  /// it would be the newest one. Tomorrow's gate tries again.
  final bool complete;

  /// Removes the staged database copies. Whoever built the payload calls it
  /// once every destination is done.
  Future<void> dispose() async => files?.dispose();

  /// The rows are read here; the log's decode, the JSON, the CSV and the
  /// deflate run on another isolate — a whole library of each. The blobs
  /// are copied and hashed first, so the list in the zip is of exactly the
  /// files staged.
  ///
  /// [dataFiles] false: rows only — the phone's own copy, whose databases
  /// are copied beside it as files and never leave it.
  static Future<SnapshotPayload> build(
    AppSnapshotIo snapshots, {
    bool dataFiles = true,
  }) async {
    DataFileSet? files;
    var complete = true;
    if (dataFiles) {
      try {
        files = await snapshots.collectDataFiles();
      } catch (_) {
        complete = false;
      }
    }
    final manifest = files?.manifest;
    final snapshot = await snapshots.export();
    final changeLog = await snapshots.rawChangeLog();
    final SnapshotPayload encoded;
    try {
      encoded = await Isolate.run(() => _encode(snapshot, changeLog, manifest));
    } on ArgumentError {
      // A row that can't cross isolates: encoded here, late but whole.
      final here = _encode(snapshot, changeLog, manifest, files);
      return SnapshotPayload(
        zip: here.zip,
        csv: here.csv,
        files: files,
        complete: complete,
      );
    }
    return SnapshotPayload(
      zip: encoded.zip,
      csv: encoded.csv,
      files: files,
      complete: complete,
    );
  }
}

SnapshotPayload _encode(
  AppSnapshot snapshot,
  RawChangeLog changeLog,
  List<Map<String, Object?>>? manifest, [
  DataFileSet? files,
]) => SnapshotPayload(
  zip: zipSnapshot(snapshot, changeLog: changeLog.open(), dataFiles: manifest),
  csv: indexCsv(snapshot),
  files: files,
);

/// Which daily archives in [names] (file names, any others ignored) to
/// delete on [today], each with the archive of its month that stays.
///
/// The last [keepDays] days stay whole. Before that, each calendar month
/// keeps its newest daily. Nothing but exact `YYYYMMDD.zip` names is ever
/// planned, and never today's.
List<(String doomed, String keeper)> thinningPlan(
  Iterable<String> names,
  DateTime today, {
  int keepDays = 30,
}) {
  final cutoff = DateTime(
    today.year,
    today.month,
    today.day,
  ).subtract(Duration(days: keepDays));
  final byMonth = <String, List<String>>{};
  for (final name in names.where(isDailyArchiveName)) {
    final y = int.parse(name.substring(0, 4));
    final m = int.parse(name.substring(4, 6));
    final d = int.parse(name.substring(6, 8));
    final day = DateTime(y, m, d);
    if (day.month != m || day.day != d) continue; // not a real date
    if (!day.isBefore(cutoff)) continue;
    byMonth.putIfAbsent(name.substring(0, 6), () => []).add(name);
  }
  return [
    for (final month in byMonth.values)
      for (final doomed in (month..sort()).take(month.length - 1))
        (doomed, month.last),
  ];
}

/// One destination's best copy for a fresh install.
class RestoreCandidate {
  const RestoreCandidate(this.snapshot, {this.preDeletion = false});

  final AppSnapshot snapshot;

  /// Taken just before Remove All App Data: outranks any daily copy, which
  /// after a wipe is of an empty library (see [latestArchiveName]).
  final bool preDeletion;

  /// Whether this is the one to restore rather than [other]: a pre-deletion
  /// copy first, then the newest `exportedAt`.
  bool beats(RestoreCandidate? other) {
    if (other == null) return true;
    if (preDeletion != other.preDeletion) return preDeletion;
    return snapshot.exportedAt.isAfter(other.snapshot.exportedAt);
  }

  static RestoreCandidate? best(Iterable<RestoreCandidate?> all) {
    RestoreCandidate? best;
    for (final c in all) {
      if (c != null && c.beats(best)) best = c;
    }
    return best;
  }
}

/// [unzipSnapshot] on another isolate: a whole library's inflate and JSON.
Future<AppSnapshot?> unzipSnapshotAside(List<int> bytes) async {
  try {
    return await Isolate.run(() => unzipSnapshot(bytes));
  } on ArgumentError {
    return unzipSnapshot(bytes);
  }
}
