import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

import '../photos/file_hash.dart' as file_hash;
import '../photos/image_pipeline.dart';
import '../settings/backup_targets_store.dart';
import '../settings/s3_backup_target.dart';
import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import 'backup_cancel_token.dart';
import 's3_object_delete.dart' as s3_object_delete;
import 's3_uploader.dart';
import 'signing.dart';

const _derivativeDirs = {
  DerivativeKind.thumbnail: 'thumbnails',
  DerivativeKind.medium: 'medium',
  DerivativeKind.original: 'originals',
};

/// Fans one derivative file out to every configured S3 target.
///
/// Known limitation: `asset_record` (T1.5) tracks one status/key per
/// derivative, not one per target, so with multiple targets configured the
/// stored status/key reflect "backed up somewhere" rather than per-target
/// state. Fine for today's common single-target case; a schema change would
/// be needed to track per-target state precisely.
class BackupCoordinator {
  BackupCoordinator({
    required this.targetsStore,
    required this.recordStore,
    S3Uploader? s3Uploader,
    Future<String> Function(String path)? hashFile,
    Future<bool> Function({
      required S3BackupTarget target,
      required String key,
    })?
    deleteObject,
  }) : _s3Uploader = s3Uploader ?? S3Uploader(),
       _hashFile = hashFile ?? file_hash.hashFile,
       _deleteObject = deleteObject ?? _defaultDeleteObject;

  static Future<bool> _defaultDeleteObject({
    required S3BackupTarget target,
    required String key,
  }) => s3_object_delete.deleteObject(target: target, key: key);

  final BackupTargetsStore targetsStore;
  final AssetRecordStore recordStore;
  final S3Uploader _s3Uploader;

  /// Overridable for tests so they never touch the real filesystem just to
  /// exercise the change-detection bookkeeping.
  final Future<String> Function(String path) _hashFile;

  /// Overridable for tests so they never make a real network call.
  final Future<bool> Function({
    required S3BackupTarget target,
    required String key,
  })
  _deleteObject;

  /// Removes every derivative this record has in the bucket — the last step
  /// of a permanent delete, and the only thing in the app that reaches for
  /// [s3_object_delete.deleteObject].
  ///
  /// Returns whether everything it tried came away clean. A partial failure
  /// (offline, credentials rotated) is reported rather than swallowed, so
  /// the caller can leave the record in place and let the user try again —
  /// dropping it locally would orphan the objects with nothing left
  /// pointing at them.
  Future<bool> deleteBackup(AssetRecord record) async {
    final targets = await targetsStore.loadAll();
    if (targets.isEmpty) return true;
    var allGone = true;
    for (final target in targets) {
      for (final kind in DerivativeKind.values) {
        final key = record.stateOf(kind).destinationKey;
        if (key == null) continue;
        if (!await _deleteObject(target: target, key: key)) allGone = false;
      }
    }
    return allGone;
  }

  static String _safeFileName(AssetRecord record, String filePath) {
    final base = record.localId.replaceAll(RegExp(r'[^a-zA-Z0-9_.-]'), '_');
    return '$base${p.extension(filePath)}';
  }

  /// If [format] is [BackupFormat.optimized] and [record] is a still photo,
  /// re-encodes the file at [filePath] to WebP in a fresh temp file and
  /// returns its path — the returned path differs from [filePath] exactly
  /// when the caller now owns a temp file it must delete once uploads are
  /// done (see [_cleanupIfTemp]). Falls back to [filePath] unchanged for
  /// videos, [BackupFormat.original], or a re-encode that fails.
  Future<String> _resolveUploadPath({
    required AssetRecord record,
    required String filePath,
    required BackupFormat format,
  }) async {
    if (format != BackupFormat.optimized || record.isVideo) return filePath;
    try {
      final bytes = await File(filePath).readAsBytes();
      final webp = await Isolate.run(() => reencodeAsWebP(bytes));
      if (webp == null) return filePath;
      final tempDir = await Directory.systemTemp.createTemp('byop_webp_');
      final tempFile = File(
        p.join(tempDir.path, '${p.basenameWithoutExtension(filePath)}.webp'),
      );
      await tempFile.writeAsBytes(webp);
      return tempFile.path;
    } catch (_) {
      return filePath;
    }
  }

  Future<void> _cleanupIfTemp(String uploadPath, String originalPath) async {
    if (uploadPath == originalPath) return;
    await _deleteTempDir(uploadPath);
  }

  /// Best-effort — a leftover temp file costs some device storage, not
  /// correctness.
  Future<void> _deleteTempDir(String tempFilePath) async {
    try {
      await File(tempFilePath).parent.delete(recursive: true);
    } catch (_) {
      // See above.
    }
  }

  /// Sends [filePath] (the asset's [kind] derivative) to every target in
  /// [targets] (every configured target, if omitted) and records the
  /// aggregate outcome. Returns the count of targets it landed on
  /// successfully (0 if none configured or all failed).
  Future<int> backUpDerivative({
    required AssetRecord record,
    required DerivativeKind kind,
    required String filePath,
    List<S3BackupTarget>? targets,
  }) async {
    await recordStore.updateDerivative(
      record.localId,
      kind,
      const DerivativeState(status: UploadStatus.uploading),
    );

    final resolvedTargets = targets ?? await targetsStore.loadAll();
    final format = await targetsStore.getBackupFormat();
    final uploadPath = await _resolveUploadPath(
      record: record,
      filePath: filePath,
      format: format,
    );
    final fileName = _safeFileName(record, uploadPath);
    final derivativeDir = _derivativeDirs[kind]!;

    var succeeded = 0;
    String? firstDestinationKey;
    try {
      for (final target in resolvedTargets) {
        final key = derivativeKey(
          prefix: target.prefix,
          derivativeDir: derivativeDir,
          fileName: fileName,
        );
        final ok = await _s3Uploader.put(
          filePath: uploadPath,
          key: key,
          target: target,
        );
        if (ok) {
          succeeded++;
          firstDestinationKey ??= key;
        }
      }
    } finally {
      await _cleanupIfTemp(uploadPath, filePath);
    }

    final finalStatus = resolvedTargets.isEmpty
        ? UploadStatus.pending
        : (succeeded > 0 ? UploadStatus.uploaded : UploadStatus.failed);
    await recordStore.updateDerivative(
      record.localId,
      kind,
      DerivativeState(
        status: finalStatus,
        destinationKey: firstDestinationKey,
        backedUpHash: await _hashOnSuccess(
          succeeded > 0,
          filePath,
          record.stateOf(kind).backedUpHash,
        ),
      ),
    );
    return succeeded;
  }

  /// Hashes the local original file once an upload actually succeeds — the
  /// baseline `LibraryScreen`'s re-sync check compares against to detect a
  /// local edit since backup. Keeps [previousHash] on failure/no targets
  /// rather than losing drift-detection for this asset entirely.
  Future<String?> _hashOnSuccess(
    bool succeeded,
    String filePath,
    String? previousHash,
  ) async {
    if (!succeeded) return previousHash;
    try {
      return await _hashFile(filePath);
    } catch (_) {
      return previousHash;
    }
  }

  /// Backs up [records] across however many targets are configured,
  /// ordered by [BackupTargetsStore.getOrderStrategy]. [resolvePath]
  /// resolves each record's local file on demand (may be slow — e.g. an
  /// iCloud download); a record whose path can't be resolved, or whose
  /// upload throws, is skipped rather than aborting the rest of the batch.
  /// [cancelToken], if cancelled mid-run, stops the loop early — records
  /// not yet attempted just stay whatever they were (pending, typically).
  /// Returns the count of records that landed on at least one target.
  Future<int> backUpBatch({
    required List<AssetRecord> records,
    required DerivativeKind kind,
    required Future<String?> Function(AssetRecord record) resolvePath,
    BackupCancelToken? cancelToken,
  }) async {
    final targets = await targetsStore.loadAll();
    final strategy = await targetsStore.getOrderStrategy();

    if (targets.isEmpty || strategy == BackupOrderStrategy.fileByFile) {
      var succeeded = 0;
      for (final record in records) {
        if (cancelToken?.isCancelled == true) break;
        try {
          final path = await resolvePath(record);
          if (path == null) continue;
          final count = await backUpDerivative(
            record: record,
            kind: kind,
            filePath: path,
            targets: targets,
          );
          if (count > 0) succeeded++;
        } catch (_) {
          // One asset's file/upload failed outright — skip it, keep going.
        }
      }
      return succeeded;
    }

    // bucketByBucket: finish every record against one target before moving
    // to the next target. Status can't be written per (record, target)
    // attempt — a later target's failure would regress an earlier target's
    // success back to "failed" — so it's reconciled once, after every
    // target's been tried. A record that never got a single attempt (path
    // resolution failed, or [cancelToken] fired before its turn) is left
    // alone entirely — still whatever it was, pending in the common case —
    // rather than reconciled as though it had failed.
    final format = await targetsStore.getBackupFormat();
    final paths = <String, String>{};
    final rawPaths = <String, String>{};
    final tempPaths = <String>[];
    for (final record in records) {
      if (cancelToken?.isCancelled == true) break;
      try {
        final rawPath = await resolvePath(record);
        if (rawPath == null) continue;
        final uploadPath = await _resolveUploadPath(
          record: record,
          filePath: rawPath,
          format: format,
        );
        if (uploadPath != rawPath) tempPaths.add(uploadPath);
        paths[record.localId] = uploadPath;
        rawPaths[record.localId] = rawPath;
      } catch (_) {
        // Skip — see above.
      }
    }

    final attempted = <String>{};
    final successCounts = <String, int>{};
    final firstKeys = <String, String>{};
    final derivativeDir = _derivativeDirs[kind]!;
    outer:
    for (final target in targets) {
      for (final record in records) {
        if (cancelToken?.isCancelled == true) break outer;
        final path = paths[record.localId];
        if (path == null) continue;
        if (attempted.add(record.localId)) {
          await recordStore.updateDerivative(
            record.localId,
            kind,
            const DerivativeState(status: UploadStatus.uploading),
          );
        }
        try {
          final fileName = _safeFileName(record, path);
          final key = derivativeKey(
            prefix: target.prefix,
            derivativeDir: derivativeDir,
            fileName: fileName,
          );
          final ok = await _s3Uploader.put(
            filePath: path,
            key: key,
            target: target,
          );
          if (ok) {
            successCounts.update(
              record.localId,
              (v) => v + 1,
              ifAbsent: () => 1,
            );
            firstKeys.putIfAbsent(record.localId, () => key);
          }
        } catch (_) {
          // This (record, target) pair failed outright — other targets for
          // the same record still get their own attempt.
        }
      }
    }

    var succeeded = 0;
    for (final record in records) {
      if (!attempted.contains(record.localId)) continue;
      final ok = (successCounts[record.localId] ?? 0) > 0;
      await recordStore.updateDerivative(
        record.localId,
        kind,
        DerivativeState(
          status: ok ? UploadStatus.uploaded : UploadStatus.failed,
          destinationKey: firstKeys[record.localId],
          backedUpHash: await _hashOnSuccess(
            ok,
            rawPaths[record.localId]!,
            record.stateOf(kind).backedUpHash,
          ),
        ),
      );
      if (ok) succeeded++;
    }
    for (final tempPath in tempPaths) {
      await _deleteTempDir(tempPath);
    }
    return succeeded;
  }
}
