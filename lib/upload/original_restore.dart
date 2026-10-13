import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../photos/thumbnail_cache.dart';
import '../settings/backup_targets_store.dart';
import '../settings/s3_backup_target.dart';
import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import 'object_keys.dart';
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
    Future<bool> Function(Map<String, Object> args)? frame,
  }) : _directory = directory ?? getApplicationSupportDirectory,
       _get = get ?? http.get,
       _getHead =
           get ?? ((url) => http.get(url, headers: {'Range': _headRange})),
       _frame = frame ?? _nativeFrame;

  final BackupTargetsStore targetsStore;
  final AssetRecordStore recordStore;
  final Future<Directory> Function() _directory;

  /// Overridable for tests so they never make a real network call.
  final Future<http.Response> Function(Uri url) _get;

  /// The first [headBytes] of an object.
  final Future<http.Response> Function(Uri url) _getHead;
  static const _headRange = 'bytes=0-${headBytes - 1}';

  /// `remoteThumbnail` in `ImageEncodeChannel.swift`; a test double in tests.
  final Future<bool> Function(Map<String, Object> args) _frame;

  static Future<bool> _nativeFrame(Map<String, Object> args) async {
    try {
      return await const MethodChannel('byo.photos/image_encode')
              .invokeMethod<bool>('remoteThumbnail', args) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// How much of a photo is read for its thumbnail: enough for the preview
  /// cameras embed near the start, a sliver of the whole.
  static const headBytes = 512 * 1024;

  /// Downloads [record]'s `originals/` object from whichever configured
  /// target still has it, writes it into app-owned storage, and clears the
  /// cloud-only flag. Returns the restored local path, or null if there's
  /// nothing to restore from or every target failed.
  ///
  /// Every key the photo was ever recorded under is tried in every bucket
  /// set up now: a bucket since removed may have been a folder of the same
  /// one. When none answers, [lastProblem] says what each one said.
  Future<String?> restore(AssetRecord record) async {
    lastProblem = null;
    final held = await recordStore.targetsHolding(
      record.localId,
      DerivativeKind.original,
    );
    final keys = <String>{
      ?record.stateOf(DerivativeKind.original).destinationKey,
      ...held.values,
    };
    if (keys.isEmpty) {
      lastProblem = 'never backed up';
      return null;
    }
    final targets = await targetsStore.loadAll();
    if (targets.isEmpty) {
      lastProblem = 'no bucket set up';
      return null;
    }
    final heard = <String>{};
    for (final target in targets) {
      // The bucket's own key first, then each recorded key under this
      // bucket's prefix: a key carries the prefix of the bucket it was
      // uploaded to, and as-is elsewhere it is a 404 for a photo that's there.
      final candidates = <String>{
        ?held[target.id],
        for (final key in keys)
          derivativeKey(
            prefix: target.prefix,
            derivativeDir: derivativeDirs[DerivativeKind.original]!,
            fileName: p.posix.basename(key),
          ),
        ...keys,
      };
      for (final key in candidates) {
        final path = await _fetch(record, target, key, heard);
        if (path != null) return path;
      }
    }
    lastProblem = heard.join(', ');
    return null;
  }

  /// Why the last [restore] got nothing, in a few words.
  String? lastProblem;

  Future<String?> _fetch(
    AssetRecord record,
    S3BackupTarget target,
    String key,
    Set<String> heard,
  ) async {
    {
      try {
        final url = await presignGetUrl(target: target, key: key);
        final response = await _get(url);
        if (response.statusCode != 200) {
          heard.add(
            response.statusCode == 404
                ? 'not in ${target.bucket}'
                : '${target.bucket} said ${response.statusCode}',
          );
          return null;
        }

        final dir = await _directory();
        final file = File(p.join(dir.path, p.basename(key)));
        await file.writeAsBytes(response.bodyBytes);
        await recordStore.setSourcePath(record.localId, file.path);
        await recordStore.setLocalDeleted(record.localId, false);
        // Whatever the device had before — nothing, or a shrunken copy —
        // what it has now came out of the bucket, which only ever held the
        // original.
        await recordStore.setLocalOptimized(record.localId, false);
        // The moving half comes with it, or the photo comes back as a
        // still — which is the thing backing it up was supposed to
        // prevent. Best-effort: a failure here still leaves a usable
        // photo, so it must not lose the restore that already worked.
        await _restoreLiveHalf(record, target, dir);
        return file.path;
      } catch (e) {
        // Wrong target, expired credentials, network — try the next one.
        heard.add('${target.bucket}: ${e.runtimeType}');
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
  ///
  /// With no thumbnail object, one is made from the original where it
  /// lies, without downloading it: a video's frame streamed by iOS, or a
  /// photo's first [headBytes].
  Future<String?> restoreThumbnail(AssetRecord record) async =>
      await _fetchThumbnail(record) ?? await _makeThumbnail(record);

  Future<String?> _makeThumbnail(AssetRecord record) async {
    final held = await recordStore.targetsHolding(
      record.localId,
      DerivativeKind.original,
    );
    final dir = Directory(
      p.join((await _directory()).path, ThumbnailCache.dirName),
    );
    for (final target in await targetsStore.loadAll()) {
      final key = remoteKeyFor(
        record: record,
        kind: DerivativeKind.original,
        target: target,
        held: held,
      );
      if (key == null) continue;
      try {
        if (!await dir.exists()) await dir.create(recursive: true);
        final out = p.join(
          dir.path,
          '${p.basenameWithoutExtension(key)}_made.jpg',
        );
        final url = await presignGetUrl(target: target, key: key);
        final Map<String, Object> args;
        if (record.isVideo) {
          args = {'url': '$url', 'output': out};
        } else {
          final head = await _getHead(url);
          if (head.statusCode != 200 && head.statusCode != 206) continue;
          args = {'bytes': head.bodyBytes, 'output': out};
        }
        if (!await _frame(args)) continue;
        await recordStore.setThumbnailPath(record.localId, out);
        return out;
      } catch (_) {
        // This bucket couldn't; the next may.
      }
    }
    return null;
  }

  Future<String?> _fetchThumbnail(AssetRecord record) async {
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
    final key = remoteKeyFor(
      record: record,
      kind: DerivativeKind.livePhoto,
      target: target,
      held: await recordStore.targetsHolding(
        record.localId,
        DerivativeKind.livePhoto,
      ),
    );
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
