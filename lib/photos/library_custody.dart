import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';

import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import 'photo_library_service.dart';
import 'smaller_export.dart';

/// Who is holding the photo: the OS photo library, or this app.
///
/// Hiding a photo here takes it *out* of Photos — otherwise "hidden" would
/// only mean hidden from this one app, and the photo would still be the
/// first thing anyone scrolling the camera roll sees. Taking it back out of
/// the hidden album puts it back. In between, this app's own copy in its
/// container is the only copy on the device.
///
/// Which is the risk, and it's worth being plain about: a hidden photo lives
/// as an encrypted carrier in this app's container (`../vault/store.dart` —
/// durable, and out of the device backup) and in whatever bucket it's been
/// backed up to. Delete the app and iOS deletes the container with it, so
/// with no bucket configured that carrier is the only copy in existence.
/// That's the price of it not being in Photos, and the hide flow says so
/// once, before the first one.
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
    Future<AssetEntity?> Function(
      File file, {
      required bool isVideo,
      required DateTime createdAt,
    })?
    saveToLibrary,
    Future<File?> Function(AssetRecord record)? liveVideo,
    Future<AssetEntity?> Function(
      File still,
      File video, {
      required DateTime createdAt,
    })?
    saveLiveToLibrary,
  }) : _library = library ?? PhotoLibraryService(store: store),
       _directory = directory ?? getApplicationSupportDirectory,
       _saveToLibrary = saveToLibrary ?? _defaultSaveToLibrary,
       _liveVideo = liveVideo ?? PhotoLibraryService.resolveLivePhotoVideo,
       _saveLiveToLibrary = saveLiveToLibrary ?? _defaultSaveLiveToLibrary;

  final AssetRecordStore store;
  final PhotoLibraryService _library;
  final Future<Directory> Function() _directory;
  final Future<AssetEntity?> Function(
    File file, {
    required bool isVideo,
    required DateTime createdAt,
  })
  _saveToLibrary;
  final Future<File?> Function(AssetRecord record) _liveVideo;
  final Future<AssetEntity?> Function(
    File still,
    File video, {
    required DateTime createdAt,
  })
  _saveLiveToLibrary;

  /// PhotoKit's Live Photo save takes no date, so it is set straight after;
  /// a failure there leaves the photo back, moving, wearing today's date.
  static Future<AssetEntity?> _defaultSaveLiveToLibrary(
    File still,
    File video, {
    required DateTime createdAt,
  }) async {
    final saved = await PhotoManager.editor.darwin.saveLivePhoto(
      imageFile: still,
      videoFile: video,
      title: p.basenameWithoutExtension(still.path),
    );
    try {
      return await PhotoManager.editor.darwin.updateCreationDate(
        entity: saved,
        creationDate: createdAt,
      );
    } catch (_) {
      return saved;
    }
  }

  /// Hands the file to Photos **with its original date**.
  ///
  /// PhotoKit stamps whatever it creates with the moment it was created, so
  /// a photo hidden in 2019 and recovered today comes back dated today, at
  /// the bottom of the camera roll rather than the day it was taken.
  ///
  /// The date goes in at creation — one `performChanges`, set on the same
  /// `PHAssetCreationRequest` that adds the file — rather than being
  /// patched on afterwards. A second call would be a second thing that can
  /// fail, and the failure would be invisible: the photo is back, just
  /// wearing the wrong day.
  static Future<AssetEntity?> _defaultSaveToLibrary(
    File file, {
    required bool isVideo,
    required DateTime createdAt,
  }) async {
    final name = p.basename(file.path);
    return isVideo
        ? PhotoManager.editor.saveVideo(
            file,
            title: name,
            creationDate: createdAt,
          )
        : PhotoManager.editor.saveImageWithPath(
            file.path,
            title: name,
            creationDate: createdAt,
          );
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
  ///
  /// [askHeif] is offered how many of the photos could be stored as HEIF —
  /// same pixels, about half the space — once their files are in hand, so
  /// the count leaves out what is HEIF already. Not asked when that's none.
  /// A photo whose encode fails, or comes out no smaller, is kept as it was.
  Future<Map<String, CustodyResult>> takeOutMany(
    List<AssetRecord> records, {
    Future<bool> Function(int count)? askHeif,
  }) async {
    final results = <String, CustodyResult>{};
    final held = <AssetRecord>[];
    final resolved = <AssetRecord, (File, File?)>{};

    for (final record in records) {
      if (record.sourceType != AssetSourceType.photoManager ||
          PhotoLibraryService.libraryIdOf(record) == null) {
        // Already ours: imported by hand, or taken out before.
        held.add(record);
        results[record.localId] = CustodyResult.taken;
        continue;
      }
      final files = await _resolve(record);
      if (files == null) {
        results[record.localId] = CustodyResult.failed;
      } else {
        resolved[record] = files;
      }
    }

    var toHeif = false;
    if (askHeif != null) {
      final count =
          held.where((r) => _heifCandidate(r, r.sourcePath)).length +
          resolved.entries
              .where((e) => _heifCandidate(e.key, e.value.$1.path))
              .length;
      if (count > 0) toHeif = await askHeif(count);
    }
    if (toHeif) {
      for (final record in held) {
        await _convertHeld(record);
      }
    }

    final copied = <AssetRecord>[];
    for (final MapEntry(key: record, value: (source, motion))
        in resolved.entries) {
      if (await _copyOut(record, source, motion, toHeif: toHeif)) {
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

  /// [record]'s original and, for a Live Photo, its `.mov` — or null when
  /// either can't be had. A Live Photo's motion is a second file, and
  /// deleting from Photos takes both: no `.mov`, no hiding, since a silent
  /// still is a lost photo.
  Future<(File, File?)?> _resolve(AssetRecord record) async {
    final File source;
    try {
      final file = await _library.fileFor(record);
      if (file == null || !await file.exists()) return null;
      source = file;
    } catch (_) {
      // An iCloud original that wouldn't come down, or no plugin at all.
      return null;
    }
    File? motion;
    if (record.isLivePhoto) {
      try {
        motion = await _liveVideo(record);
      } catch (_) {
        motion = null;
      }
      if (motion == null || !await motion.exists()) return null;
    }
    return (source, motion);
  }

  /// Copies [source] (and [motion]) into this app's own storage and points
  /// the record at it. A photo is only ever deleted from Photos once there
  /// is another copy of it on disk, so this always happens first.
  Future<bool> _copyOut(
    AssetRecord record,
    File source,
    File? motion, {
    bool toHeif = false,
  }) async {
    try {
      final dir = await _directory();
      var copy = File(
        p.join(dir.path, p.setExtension(_fileNameFor(record, source), '.heic')),
      );
      final converted =
          toHeif &&
          _heifCandidate(record, source.path) &&
          await encodeFileNatively(
            input: source.path,
            output: copy.path,
            format: 'heic',
          );
      if (!converted) {
        copy = File(p.join(dir.path, _fileNameFor(record, source)));
        await source.copy(copy.path);
      }
      if (!await copy.exists() || await copy.length() == 0) return false;
      if (motion != null) {
        final held = File(PhotoLibraryService.heldLiveVideoPath(copy.path));
        await motion.copy(held.path);
        if (!await held.exists() || await held.length() == 0) return false;
      }
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
    final motion = File(PhotoLibraryService.heldLiveVideoPath(path));
    try {
      final saved = record.isLivePhoto && await motion.exists()
          ? await _saveLiveToLibrary(file, motion, createdAt: record.createdAt)
          : await _saveToLibrary(
              file,
              isVideo: record.isVideo,
              // This app's own date, which survived the round trip: the
              // record kept it while the photo was out of Photos.
              createdAt: record.createdAt,
            );
      if (saved == null) return CustodyResult.failed;
      await store.setLibraryId(record.localId, saved.id);
      return CustodyResult.returned;
    } catch (_) {
      return CustodyResult.failed;
    }
  }

  /// Hands Photos a photo that exists only as files — a hidden photo opened
  /// out of its carrier. With its original date, and moving when [motion]
  /// is there. The Photos asset id, or null when it was refused.
  Future<String?> saveFiles({
    required File still,
    File? motion,
    required bool isVideo,
    required DateTime createdAt,
  }) async {
    try {
      final saved = motion != null
          ? await _saveLiveToLibrary(still, motion, createdAt: createdAt)
          : await _saveToLibrary(still, isVideo: isVideo, createdAt: createdAt);
      return saved?.id;
    } catch (_) {
      return null;
    }
  }

  /// Keeps the library's own filename where there is one, so a photo that
  /// goes back to Photos goes back as `IMG_4934.HEIC` rather than as this
  /// app's internal id. Prefixed with the record's id to stay unique in a
  /// flat directory.
  /// A still at [path] that isn't HEIF already. Not a video, and not a
  /// Live Photo: its still and `.mov` are a pair Photos matches up, and a
  /// re-encoded still loses the tag that pairs them.
  static bool _heifCandidate(AssetRecord record, String? path) {
    if (path == null || record.countsAsVideo || record.isLivePhoto) {
      return false;
    }
    final ext = p.extension(path).toLowerCase();
    return ext != '.heic' && ext != '.heif';
  }

  /// A photo this app already holds, re-encoded in place: the HEIF lands
  /// beside it and the record moves over before the old file goes.
  Future<void> _convertHeld(AssetRecord record) async {
    final path = record.sourcePath;
    if (!_heifCandidate(record, path)) return;
    final converted = p.setExtension(path!, '.heic');
    if (converted == path) return;
    if (!await encodeFileNatively(
      input: path,
      output: converted,
      format: 'heic',
    )) {
      return;
    }
    try {
      await store.setSourcePath(record.localId, converted);
      await File(path).delete();
    } catch (_) {
      // Left as it was.
    }
  }

  static String _fileNameFor(AssetRecord record, File source) {
    final safeId = record.localId.replaceAll(RegExp(r'[^A-Za-z0-9]'), '_');
    return '$safeId-${p.basename(source.path)}';
  }
}
