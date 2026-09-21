import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';

import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import 'photo_library_service.dart';

/// Who is holding the photo: the OS photo library, or this app.
///
/// Hiding a photo here takes it *out* of Photos — otherwise "hidden" would
/// only mean hidden from this one app, and the photo would still be the
/// first thing anyone scrolling the camera roll sees. Taking it back out of
/// the hidden album puts it back. In between, this app's own copy in its
/// container is the only copy on the device.
///
/// Which is the risk, and it's worth being plain about: a hidden photo
/// lives in the app container and in whatever bucket it's been backed up
/// to. Delete the app and iOS deletes the container with it. That's the
/// price of it not being in Photos.
enum CustodyResult {
  /// Copied out, and the library let go of it.
  taken,

  /// Copied out, but the library still has it — the delete was declined at
  /// the OS prompt. The photo is hidden here and still in Photos.
  takenButStillInLibrary,

  /// Handed back: the library has it again.
  returned,

  /// Nothing moved. No original to copy (an iCloud photo that wouldn't
  /// download, a file that's gone), or the library refused to take it back.
  failed,
}

class LibraryCustody {
  LibraryCustody({
    required this.store,
    PhotoLibraryService? library,
    Future<Directory> Function()? directory,
    Future<AssetEntity?> Function(File file, {required bool isVideo})?
    saveToLibrary,
  }) : _library = library ?? PhotoLibraryService(store: store),
       _directory = directory ?? getApplicationSupportDirectory,
       _saveToLibrary = saveToLibrary ?? _defaultSaveToLibrary;

  final AssetRecordStore store;
  final PhotoLibraryService _library;
  final Future<Directory> Function() _directory;
  final Future<AssetEntity?> Function(File file, {required bool isVideo})
  _saveToLibrary;

  static Future<AssetEntity?> _defaultSaveToLibrary(
    File file, {
    required bool isVideo,
  }) {
    final name = p.basename(file.path);
    return isVideo
        ? PhotoManager.editor.saveVideo(file, title: name)
        : PhotoManager.editor.saveImageWithPath(file.path, title: name);
  }

  /// Takes [record] out of the photo library and into this app's own
  /// storage. The copy is made and verified *first*: a photo is only ever
  /// deleted from Photos once there's another copy of it on disk.
  ///
  /// A photo this app already holds (imported by hand, or already taken
  /// out) is [CustodyResult.taken] with nothing to do.
  Future<CustodyResult> takeOut(AssetRecord record) async =>
      (await takeOutMany([record]))[record.localId] ?? CustodyResult.failed;

  /// The same, for a group, in **one** OS prompt.
  ///
  /// Every copy is made and verified first, then a single
  /// [PhotoLibraryService.deleteManyFromLibrary] takes the lot. Hiding
  /// twenty photos one at a time is twenty system confirmations, which
  /// nobody reads by the third — and a confirmation nobody reads is not a
  /// confirmation. It is also the only prompt in this flow: the photos are
  /// already selected, so asking again first would be asking a question
  /// already answered.
  Future<Map<String, CustodyResult>> takeOutMany(
    List<AssetRecord> records,
  ) async {
    final results = <String, CustodyResult>{};
    final copied = <AssetRecord>[];

    for (final record in records) {
      if (record.sourceType != AssetSourceType.photoManager ||
          PhotoLibraryService.libraryIdOf(record) == null) {
        // Already ours: imported by hand, or taken out before.
        results[record.localId] = CustodyResult.taken;
        continue;
      }
      if (await _copyOut(record)) {
        copied.add(record);
      } else {
        results[record.localId] = CustodyResult.failed;
      }
    }
    if (copied.isEmpty) return results;

    final gone = await _library.deleteManyFromLibrary(copied);
    for (final record in copied) {
      if (gone.contains(record.localId)) {
        await store.setLibraryId(record.localId, null);
        results[record.localId] = CustodyResult.taken;
      } else {
        // Declined at the prompt, or past the batch cap. The copy stays —
        // it is what the hidden album draws from, and it makes a second
        // attempt cost nothing.
        results[record.localId] = CustodyResult.takenButStillInLibrary;
      }
    }
    return results;
  }

  /// Copies [record]'s original into this app's own storage and points the
  /// record at it. A photo is only ever deleted from Photos once there is
  /// another copy of it on disk, so this always happens first.
  Future<bool> _copyOut(AssetRecord record) async {
    final File source;
    try {
      final resolved = await _library.fileFor(record);
      if (resolved == null || !await resolved.exists()) return false;
      source = resolved;
    } catch (_) {
      // An iCloud original that wouldn't come down, or no plugin at all.
      return false;
    }

    try {
      final dir = await _directory();
      final copy = File(p.join(dir.path, _fileNameFor(record, source)));
      await source.copy(copy.path);
      if (!await copy.exists() || await copy.length() == 0) return false;
      await store.setSourcePath(record.localId, copy.path);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Hands [record] back to the photo library, and re-points the record at
  /// the asset the library creates. That asset is a *new* one with a new
  /// id — PhotoKit has no notion of undeleting — which is why this app
  /// keeps its own [AssetRecord.localId]: tags, people and albums stay
  /// attached across the round trip.
  ///
  /// This app's copy is kept rather than deleted. It's the only copy that
  /// survives the user emptying Photos' own Recently Deleted, and "Remove
  /// from Device" is already the deliberate way to give up a local file.
  Future<CustodyResult> putBack(AssetRecord record) async {
    // Only photos this app took *out* go back. One imported by hand was
    // never in Photos, and un-hiding it shouldn't be the thing that puts
    // it in the camera roll for the first time.
    if (record.sourceType != AssetSourceType.photoManager) {
      return CustodyResult.returned;
    }
    if (PhotoLibraryService.libraryIdOf(record) != null) {
      return CustodyResult.returned;
    }
    final path = record.sourcePath;
    // Nothing held, nothing to hand over — the asset is simply gone, and
    // saying so again here would be noise.
    if (path == null) return CustodyResult.returned;
    final file = File(path);
    if (!await file.exists()) return CustodyResult.failed;
    try {
      final saved = await _saveToLibrary(file, isVideo: record.isVideo);
      if (saved == null) return CustodyResult.failed;
      await store.setLibraryId(record.localId, saved.id);
      return CustodyResult.returned;
    } catch (_) {
      return CustodyResult.failed;
    }
  }

  /// Keeps the library's own filename where there is one, so a photo that
  /// goes back to Photos goes back as `IMG_4934.HEIC` rather than as this
  /// app's internal id. Prefixed with the record's id to stay unique in a
  /// flat directory.
  static String _fileNameFor(AssetRecord record, File source) {
    final safeId = record.localId.replaceAll(RegExp(r'[^A-Za-z0-9]'), '_');
    return '$safeId-${p.basename(source.path)}';
  }
}
