import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'app_snapshot.dart';

/// The snapshot, zipped, one file per month.
///
/// A month per file rather than one file overwritten forever: the copy is
/// there for the day something goes wrong, and "something went wrong" is
/// usually noticed weeks later — by which time a single rolling file has
/// already been overwritten with the damage. Twelve small files a year is
/// a year of undo for a few hundred kilobytes.
///
/// Zipped because it is JSON, and JSON of a whole library compresses to
/// roughly a tenth of itself. The archive holds exactly one entry, named
/// [snapshotEntryName], so anyone who opens the file in Finder sees what it
/// is without this app's help.
const snapshotEntryName = 'library.json';

/// `202609.zip` — sorts by date as a string, which is what lets "the newest
/// backup" be answered by sorting names rather than by asking every file
/// when it was written.
String monthlyArchiveName(DateTime at) =>
    '${at.year.toString().padLeft(4, '0')}'
    '${at.month.toString().padLeft(2, '0')}.zip';

/// True for a name this app would have written — what tells its own
/// backups apart from anything else sharing the folder.
bool isMonthlyArchiveName(String name) =>
    RegExp(r'^\d{6}\.zip$').hasMatch(name);

Uint8List zipSnapshot(AppSnapshot snapshot) {
  final archive = Archive()
    ..addFile(ArchiveFile.string(snapshotEntryName, snapshot.encode()));
  return ZipEncoder().encodeBytes(archive);
}

/// `null` for anything that isn't one of these — a truncated download, a
/// file someone else put in the folder, or a snapshot from a newer build.
AppSnapshot? unzipSnapshot(List<int> bytes) {
  try {
    final archive = ZipDecoder().decodeBytes(
      bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
    );
    for (final file in archive.files) {
      if (!file.isFile) continue;
      if (file.name != snapshotEntryName && !file.name.endsWith('.json')) {
        continue;
      }
      return AppSnapshot.decode(utf8.decode(file.content));
    }
  } catch (_) {
    // Not a zip, or not one of ours.
  }
  return null;
}
