import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'app_snapshot.dart';
import 'local_vault.dart';
import 'snapshot_archive.dart';

/// The manual door: one file out through the share sheet, one file back in
/// through the picker.
///
/// Same payload as every other destination — `zipSnapshot` — so a file
/// handed to AirDrop, a file pulled out of Files, and the copy sitting in a
/// bucket are interchangeable. Only the destination differs, which is the
/// whole reason there's one format and not three.
///
/// This exists because the automatic tiers all answer "I lost my phone",
/// and none of them answers "I want the file". A backup you can't hold is a
/// promise; a backup on a Mac is a backup.
class SnapshotFile {
  SnapshotFile({
    required this.snapshots,
    required this.vault,
    Future<Directory> Function()? outboxDirectory,
    Future<List<PlatformFile>> Function({FileType type, bool allowMultiple})?
    picker,
    DateTime Function()? now,
  }) : _outboxDirectory = outboxDirectory ?? getTemporaryDirectory,
       _picker = picker ?? FilePicker.pickFiles,
       _now = now ?? DateTime.now;

  final AppSnapshotIo snapshots;

  /// Where the before-restore copy is taken. An import is exactly the
  /// "large operation" `LocalVault.guard` exists for.
  final LocalVault vault;

  final Future<Directory> Function() _outboxDirectory;
  final Future<List<PlatformFile>> Function({FileType type, bool allowMultiple})
  _picker;
  final DateTime Function() _now;

  /// Named for a human reading a Downloads folder six months from now, not
  /// for this app sorting a directory: the app name and the date, no
  /// prefixes nobody outside here would recognise.
  static String exportName(DateTime at) =>
      'photos-vault-'
      '${at.year.toString().padLeft(4, '0')}-'
      '${at.month.toString().padLeft(2, '0')}-'
      '${at.day.toString().padLeft(2, '0')}.zip';

  /// Writes the payload somewhere the share sheet can reach and returns it.
  ///
  /// Temp, deliberately: this copy is in flight, not a backup. The one the
  /// app keeps is `LocalVault`'s, in the Files-visible folder, and having
  /// the share sheet write a second file beside it would put two files a
  /// day in front of the user that differ in nothing.
  Future<File?> export() async {
    try {
      final bytes = zipSnapshot(
        await snapshots.export(),
        changeLog: await snapshots.changeLog(),
      );
      final directory = await _outboxDirectory();
      await directory.create(recursive: true);
      final file = File(p.join(directory.path, exportName(_now())));
      await file.writeAsBytes(bytes, flush: true);
      return file;
    } catch (_) {
      return null;
    }
  }

  /// Opens the picker and reads whatever comes back. Returns `null` for a
  /// cancelled pick and for a file that isn't a snapshot this build can
  /// read — the caller can't tell those apart, and doesn't need to: one
  /// says nothing, the other says the file wasn't one of ours.
  Future<AppSnapshot?> pick() async {
    final files = await _picker(type: FileType.any, allowMultiple: false);
    final path = files.isEmpty ? null : files.first.path;
    if (path == null) return null;
    return read(File(path));
  }

  Future<AppSnapshot?> read(File file) async {
    try {
      return unzipSnapshot(await file.readAsBytes());
    } catch (_) {
      return null;
    }
  }

  /// Takes the safety copy, then merges. Returns how many photos' records
  /// came back.
  ///
  /// Merges rather than replaces: `AppSnapshotIo.import` only ever adds, so
  /// a photo already tracked keeps what it has and nothing on the device is
  /// overwritten by the file. What the copy guards against is the other
  /// half — an import that adds a thousand rows the user then wants gone.
  /// That file is named `…-before-restore-<ts>.zip` and kept a week.
  ///
  /// The confirmation is the caller's: it belongs at the point of action,
  /// in the user's own language, restating what this does. See
  /// `settings_screen.dart`.
  Future<int> restore(AppSnapshot snapshot) async {
    await vault.guard('restore');
    return snapshots.import(snapshot);
  }
}
