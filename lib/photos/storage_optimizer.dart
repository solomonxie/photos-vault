import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import 'file_hash.dart';
import 'image_pipeline.dart';
import 'photo_library_service.dart';
import 'storage_advice.dart';
import 'thumbnail_cache.dart';

/// What one round of fixes actually did. Separate counts rather than a
/// single "done": queuing a backup frees nothing today, and an asset that
/// couldn't be touched has to say so rather than quietly not appear.
class StorageFixResult {
  const StorageFixResult({
    this.freedBytes = 0,
    this.queuedForBackup = 0,
    this.skipped = 0,
  });

  final int freedBytes;
  final int queuedForBackup;
  final int skipped;
}

/// Carries out what `storage_advice.dart` suggested.
///
/// The two re-encodes replace the local copy in place. That is only safe
/// because they're offered for backed-up assets alone — the bucket keeps
/// the full-quality original, and "Download Original" pulls it back. It's
/// the same trade as Remove from Device, just keeping something viewable
/// on the phone.
class StorageOptimizer {
  StorageOptimizer({
    required this.store,
    required this.thumbnails,
    required this.library,
    required this.backUp,
    Future<(Uint8List, int, int)?> Function(Uint8List bytes, int? maxEdge)?
    encode,
  }) : _encode = encode ?? _defaultEncode;

  final AssetRecordStore store;
  final ThumbnailCache thumbnails;
  final PhotoLibraryService library;

  /// Queues uploads through the library screen's own sync queue, so a
  /// backup started here is the same backup as any other.
  final Future<void> Function(List<AssetRecord> records) backUp;

  /// Overridable for tests so they never decode a real image.
  final Future<(Uint8List, int, int)?> Function(Uint8List bytes, int? maxEdge)
  _encode;

  static Future<(Uint8List, int, int)?> _defaultEncode(
    Uint8List bytes,
    int? maxEdge,
  ) => Isolate.run(() => optimizeStill(bytes, maxEdge: maxEdge));

  Future<StorageFixResult> apply(List<StorageItem> items) async {
    var freed = 0;
    var skipped = 0;

    final toBackUp = [
      for (final item in items)
        if (item.fix == StorageFix.backUpFirst) item.record,
    ];
    if (toBackUp.isNotEmpty) await backUp(toBackUp);

    for (final item in items) {
      if (item.fix != StorageFix.reduceResolution &&
          item.fix != StorageFix.convertFormat) {
        continue;
      }
      final saved = await _rewrite(item);
      if (saved == null) {
        skipped++;
      } else {
        freed += saved;
      }
    }

    final removal = await _removeFromDevice([
      for (final item in items)
        if (item.fix == StorageFix.removeFromDevice) item,
    ]);
    freed += removal.freedBytes;
    skipped += removal.skipped;

    return StorageFixResult(
      freedBytes: freed,
      queuedForBackup: toBackUp.length,
      skipped: skipped,
    );
  }

  /// Returns the bytes saved, or null if nothing was written.
  Future<int?> _rewrite(StorageItem item) async {
    final path = item.record.sourcePath;
    if (path == null) return null;
    try {
      final file = File(path);
      final before = await file.length();
      final encoded = await _encode(
        await file.readAsBytes(),
        item.fix == StorageFix.reduceResolution ? optimizedMaxEdge : null,
      );
      if (encoded == null) return null;
      final (bytes, width, height) = encoded;
      // A re-encode that grew the file isn't an optimization.
      if (bytes.length >= before) return null;

      final hash = hashBytes(bytes);
      final target = File(p.join(p.dirname(path), '$hash.webp'));
      await target.writeAsBytes(bytes);
      if (target.path != path) {
        try {
          await file.delete();
        } catch (_) {
          // Already gone; the record points at the new file either way.
        }
      }

      await store.setSourcePath(item.record.localId, target.path);
      await store.setLibraryMetadata(
        item.record.localId,
        width: width,
        height: height,
      );
      // The bucket holds the original and has to go on holding it: without
      // this, the next change check would see a local file that no longer
      // matches and upload the shrunken copy over the full-quality one.
      final state = item.record.stateOf(DerivativeKind.original);
      await store.updateDerivative(
        item.record.localId,
        DerivativeKind.original,
        DerivativeState(
          status: state.status,
          destinationKey: state.destinationKey,
          backedUpHash: hash,
        ),
      );
      return before - bytes.length;
    } catch (_) {
      // Undecodable, unwritable, or the file moved mid-pass — the asset
      // keeps the copy it had.
      return null;
    }
  }

  Future<StorageFixResult> _removeFromDevice(List<StorageItem> items) async {
    var freed = 0;
    var skipped = 0;
    final fromLibrary = <StorageItem>[];

    for (final item in items) {
      // The grid draws this once the original is gone; without one the
      // photo would vanish rather than go cloud-only.
      if (!await _hasThumbnail(item.record)) {
        skipped++;
        continue;
      }
      final path = item.record.sourcePath;
      if (path == null) {
        fromLibrary.add(item);
        continue;
      }
      try {
        await File(path).delete();
      } catch (_) {
        skipped++;
        continue;
      }
      await store.setLocalDeleted(item.record.localId, true);
      freed += item.bytes;
    }

    if (fromLibrary.isNotEmpty) {
      // One iOS confirmation for the whole batch, not one per photo.
      final gone = await library.deleteManyFromLibrary([
        for (final item in fromLibrary) item.record,
      ]);
      for (final item in fromLibrary) {
        if (!gone.contains(item.record.localId)) {
          skipped++;
          continue;
        }
        await store.setLocalDeleted(item.record.localId, true);
        freed += item.bytes;
      }
    }

    return StorageFixResult(freedBytes: freed, skipped: skipped);
  }

  Future<bool> _hasThumbnail(AssetRecord record) async {
    final existing = record.thumbnailPath;
    if (existing != null && File(existing).existsSync()) return true;
    // A video's poster frame comes from the photo library; exporting the
    // whole movie to make a picture of it would be absurd.
    final path = record.isVideo ? null : await _localPathOf(record);
    if (path == null && !record.isVideo) return false;
    return await thumbnails.ensureFor(record, path) != null;
  }

  Future<String?> _localPathOf(AssetRecord record) async {
    final path = record.sourcePath;
    if (path != null && File(path).existsSync()) return path;
    if (record.sourceType != AssetSourceType.photoManager) return null;
    try {
      return (await library.fileFor(record))?.path;
    } catch (_) {
      return null;
    }
  }
}
