import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';

import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import 'image_pipeline.dart';

/// App-owned thumbnails, one per photo, kept in their own directory under
/// application support.
///
/// Every backed-up photo gets one — not just the big ones. A file small
/// enough to skip the separate `thumbnails/` upload still needs a local
/// copy here, because that's what grids draw once
/// [AssetRecord.localDeleted] takes the full-resolution original away.
class ThumbnailCache {
  ThumbnailCache({
    required this.store,
    Future<Directory> Function()? directory,
    Future<Uint8List?> Function(File file)? encode,
    Future<Uint8List?> Function(AssetRecord record)? libraryThumbnail,
  }) : _directory = directory ?? getApplicationSupportDirectory,
       _encode = encode ?? _defaultEncode,
       _libraryThumbnail = libraryThumbnail ?? _defaultLibraryThumbnail;

  final AssetRecordStore store;
  final Future<Directory> Function() _directory;

  /// Overridable for tests so they never decode a real image off disk.
  final Future<Uint8List?> Function(File file) _encode;

  /// The poster frame PhotoKit already holds. Overridable for tests so
  /// they never reach a real photo library.
  final Future<Uint8List?> Function(AssetRecord record) _libraryThumbnail;

  static const _dirName = 'thumbnails';

  /// Off the calling isolate — decode+resize of a full-size photo is heavy
  /// enough to jank a frame otherwise.
  static Future<Uint8List?> _defaultEncode(File file) async {
    final bytes = await file.readAsBytes();
    return Isolate.run(() => encodeThumbnail(bytes));
  }

  /// What the OS already has: a still for a photo, a poster frame for a
  /// video. The only way to get a picture of a movie without a frame
  /// extractor of our own — and the whole reason a video can now be
  /// removed from the device and still draw in the grid.
  static Future<Uint8List?> _defaultLibraryThumbnail(AssetRecord record) async {
    final id = record.libraryId;
    if (id == null) return null;
    try {
      final entity = await AssetEntity.fromId(id);
      return await entity?.thumbnailDataWithOption(
        const ThumbnailOption(
          size: ThumbnailSize.square(thumbnailMaxEdge),
          quality: 80,
        ),
      );
    } catch (_) {
      // No plugin, or gone from the library since.
      return null;
    }
  }

  Future<Directory> _thumbnailDirectory() async {
    final dir = Directory(p.join((await _directory()).path, _dirName));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  static String _fileNameFor(AssetRecord record) {
    final base = record.localId.replaceAll(RegExp(r'[^a-zA-Z0-9_.-]'), '_');
    return '$base.jpg';
  }

  /// Path to [record]'s cached thumbnail, generating it the first time:
  /// from the file at [originalPath] for a still, and from the photo
  /// library's own poster frame for a video or anything this app can't
  /// decode. [originalPath] may be omitted when there's no local file to
  /// decode — a video needs none, and exporting a whole movie to make a
  /// thumbnail of it would be absurd.
  ///
  /// Null means "no thumbnail available", which callers treat as a skip
  /// rather than a failure worth surfacing.
  ///
  /// Also persists the path onto the record, so a later local delete can
  /// find it without the original still being around.
  Future<String?> ensureFor(AssetRecord record, [String? originalPath]) async {
    try {
      final existing = record.thumbnailPath;
      if (existing != null && await File(existing).exists()) return existing;

      var encoded = originalPath == null || record.isVideo
          ? null
          : await _encode(File(originalPath));
      encoded ??= await _libraryThumbnail(record);
      if (encoded == null) return null;

      final file = File(
        p.join((await _thumbnailDirectory()).path, _fileNameFor(record)),
      );
      await file.writeAsBytes(encoded);
      await store.setThumbnailPath(record.localId, file.path);
      return file.path;
    } catch (_) {
      // Unreadable/undecodable source, or nowhere to write — the grid just
      // falls back to its placeholder rather than the whole backup failing.
      return null;
    }
  }

  /// Whether anything would be left to draw once the full-resolution copy
  /// is gone — the one precondition for going cloud-only, whether that's
  /// Remove from Device or the storage page's batch.
  ///
  /// A photo is always fine (this app decodes it). A video needs the photo
  /// library's poster frame, so one imported by hand, with no library
  /// entry and nothing cached yet, is the single case with no answer.
  static bool canThumbnail(AssetRecord record) =>
      record.thumbnailPath != null ||
      !record.isVideo ||
      record.libraryId != null;

  Future<void> remove(AssetRecord record) async {
    final path = record.thumbnailPath;
    if (path == null) return;
    try {
      await File(path).delete();
    } catch (_) {
      // Already gone — nothing to reclaim.
    }
  }
}
