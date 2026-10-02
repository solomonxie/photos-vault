import 'dart:io';

import 'package:path/path.dart' as p;

import '../photos/photo_library_service.dart';
import 'album_index.dart';
import 'gallery.dart';

/// Un-hiding a photo that has been filed: out of its carrier and back into
/// Photos, with its date and — for a Live Photo — its motion.
///
/// Only opens and saves. Taking it out of the album is
/// `HiddenRemoval.release`, and only for what Photos has confirmed taking.
class HiddenRestore {
  HiddenRestore({
    required this.gallery,
    required this.saveFiles,
    Future<Directory> Function()? temporaryDirectory,
  }) : _temporaryDirectory =
           temporaryDirectory ??
           (() => Directory.systemTemp.createTemp('byop_unhide_'));

  final VaultGallery gallery;

  /// `LibraryCustody.saveFiles`: the Photos asset id, or null.
  final Future<String?> Function({
    required File still,
    File? motion,
    required bool isVideo,
    required DateTime createdAt,
  })
  saveFiles;

  final Future<Directory> Function() _temporaryDirectory;

  /// The `localId` the photo has in the library again, or null when it
  /// stays hidden: unopenable, unreachable, or refused by Photos.
  ///
  /// A still whose `.mov` twin can't be read *right now* is refused rather
  /// than restored silent — "no motion" is only believed when the index
  /// says so, or when no copy of it exists anywhere.
  Future<String?> restore(IndexEntry entry) async {
    final still = await gallery.openFull(entry.objectKey);
    final stillOpened = still.opened;
    if (stillOpened == null) return null;

    final motionKey = siblingCarrierKeys(entry.objectKey)
        .where((k) => k != entry.objectKey)
        .firstOrNull;
    final motion =
        entry.isVideo || motionKey == null || entry.hasMotion == false
        ? null
        : await gallery.openFull(motionKey);
    if (motion != null && motion.opened == null && !motion.absent) {
      return null;
    }

    Directory? dir;
    try {
      dir = await _temporaryDirectory();
      final stillFile = File(
        p.join(dir.path, 'photo.${_extension(stillOpened.extension)}'),
      );
      await stillFile.writeAsBytes(stillOpened.original, flush: true);
      File? motionFile;
      final motionOpened = motion?.opened;
      if (motionOpened != null) {
        motionFile = File(p.join(dir.path, 'photo.mov'));
        await motionFile.writeAsBytes(motionOpened.original, flush: true);
      }
      final id = await saveFiles(
        still: stillFile,
        motion: motionFile,
        isVideo: entry.isVideo,
        createdAt: entry.takenAt,
      );
      return id == null ? null : PhotoLibraryService.localIdForAssetId(id);
    } catch (_) {
      return null;
    } finally {
      try {
        await dir?.delete(recursive: true);
      } catch (_) {
        // A leftover temp is the OS's to clear.
      }
    }
  }

  static String _extension(String raw) {
    final clean = raw.replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
    return clean.isEmpty ? 'jpg' : clean;
  }
}
