import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

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
  }) : _directory = directory ?? getApplicationSupportDirectory,
       _encode = encode ?? _defaultEncode;

  final AssetRecordStore store;
  final Future<Directory> Function() _directory;

  /// Overridable for tests so they never decode a real image off disk.
  final Future<Uint8List?> Function(File file) _encode;

  static const _dirName = 'thumbnails';

  /// Off the calling isolate — decode+resize of a full-size photo is heavy
  /// enough to jank a frame otherwise.
  static Future<Uint8List?> _defaultEncode(File file) async {
    final bytes = await file.readAsBytes();
    return Isolate.run(() => encodeThumbnail(bytes));
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

  /// Path to [record]'s cached thumbnail, generating it from the file at
  /// [originalPath] the first time. Returns null when the original isn't a
  /// decodable still image (videos) or can't be read — callers treat that
  /// as "no thumbnail available", never as a failure worth surfacing.
  ///
  /// Also persists the path onto the record, so a later local delete can
  /// find it without the original still being around.
  Future<String?> ensureFor(AssetRecord record, String originalPath) async {
    try {
      final existing = record.thumbnailPath;
      if (existing != null && await File(existing).exists()) return existing;

      final encoded = await _encode(File(originalPath));
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
