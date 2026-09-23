import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../photos/thumbnail_cache.dart';
import '../settings/backup_targets_store.dart';
import '../settings/s3_backup_target.dart';
import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import 'signing.dart';

/// Pulls a backed-up original back down to the device — the other half of
/// [AssetRecord.localDeleted], for when the user wants full resolution
/// again after reclaiming the space.
///
/// Known limitation: with `BackupFormat.optimized` the object in the bucket
/// is the re-encoded WebP, not the bytes that originally left the device,
/// so what comes back is the optimized copy. It restores to a working
/// full-resolution file either way, just not a byte-identical one.
class OriginalRestore {
  OriginalRestore({
    required this.targetsStore,
    required this.recordStore,
    Future<Directory> Function()? directory,
    Future<http.Response> Function(Uri url)? get,
  }) : _directory = directory ?? getApplicationSupportDirectory,
       _get = get ?? http.get;

  final BackupTargetsStore targetsStore;
  final AssetRecordStore recordStore;
  final Future<Directory> Function() _directory;

  /// Overridable for tests so they never make a real network call.
  final Future<http.Response> Function(Uri url) _get;

  /// Downloads [record]'s `originals/` object from whichever configured
  /// target still has it, writes it into app-owned storage, and clears the
  /// cloud-only flag. Returns the restored local path, or null if there's
  /// nothing to restore from or every target failed.
  Future<String?> restore(AssetRecord record) async {
    final key = record.stateOf(DerivativeKind.original).destinationKey;
    if (key == null) return null;

    for (final target in await targetsStore.loadAll()) {
      try {
        final url = await presignGetUrl(target: target, key: key);
        final response = await _get(url);
        if (response.statusCode != 200) continue;

        final dir = await _directory();
        final file = File(p.join(dir.path, p.basename(key)));
        await file.writeAsBytes(response.bodyBytes);
        await recordStore.setSourcePath(record.localId, file.path);
        await recordStore.setLocalDeleted(record.localId, false);
        // The moving half comes with it, or the photo comes back as a
        // still — which is the thing backing it up was supposed to
        // prevent. Best-effort: a failure here still leaves a usable
        // photo, so it must not lose the restore that already worked.
        await _restoreLiveHalf(record, target, dir);
        return file.path;
      } catch (_) {
        // Wrong target, expired credentials, network — try the next one.
      }
    }
    return null;
  }

  /// Pulls just the small `thumbnails/` object down, for a photo that went
  /// cloud-only with no cached picture of itself left on the device.
  ///
  /// The last resort, and a real one: a thumbnail is made from a local
  /// original, and by the time this is wanted there isn't one. Returns the
  /// cached path, or null if the bucket hasn't got a thumbnail either —
  /// which is the case for a photo small enough that the upload was
  /// skipped as not worth a second near-identical object.
  Future<String?> restoreThumbnail(AssetRecord record) async {
    final key = record.stateOf(DerivativeKind.thumbnail).destinationKey;
    if (key == null) return null;

    for (final target in await targetsStore.loadAll()) {
      try {
        final url = await presignGetUrl(target: target, key: key);
        final response = await _get(url);
        if (response.statusCode != 200) continue;

        final dir = Directory(
          p.join((await _directory()).path, ThumbnailCache.dirName),
        );
        if (!await dir.exists()) await dir.create(recursive: true);
        final file = File(p.join(dir.path, p.basename(key)));
        await file.writeAsBytes(response.bodyBytes);
        await recordStore.setThumbnailPath(record.localId, file.path);
        return file.path;
      } catch (_) {
        // Wrong target, expired credentials, network — try the next one.
      }
    }
    return null;
  }

  Future<void> _restoreLiveHalf(
    AssetRecord record,
    S3BackupTarget target,
    Directory dir,
  ) async {
    final key = record.stateOf(DerivativeKind.livePhoto).destinationKey;
    if (key == null) return;
    try {
      final file = File(p.join(dir.path, p.basename(key)));
      if (await file.exists()) return;
      final response = await _get(
        await presignGetUrl(target: target, key: key),
      );
      if (response.statusCode != 200) return;
      await file.writeAsBytes(response.bodyBytes);
    } catch (_) {
      // See above — the still is back either way.
    }
  }
}
