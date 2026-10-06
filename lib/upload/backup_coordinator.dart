import 'dart:io';

import 'package:path/path.dart' as p;

import '../photos/file_hash.dart' as file_hash;
import '../photos/smaller_export.dart';
import '../settings/backup_targets_store.dart';
import '../settings/s3_backup_target.dart';
import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import '../vault/object_key.dart';
import '../vault/carrier_upload.dart';
import '../vault/keys.dart';
import '../vault/store.dart';
import 'backup_cancel_token.dart';
import 'object_keys.dart';
import 's3_uploader.dart';
import 'signing.dart';

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
    this.carriers,
    this.vaultStore,
    this.vaultKeys,
    Future<List<DecoyCandidate>> Function()? decoyCandidates,
    S3Uploader? s3Uploader,
    Future<String> Function(String path)? hashFile,
  }) : _s3Uploader = s3Uploader ?? S3Uploader(),
       _hashFile = hashFile ?? file_hash.hashFile,
       _decoyCandidates = decoyCandidates ?? (() async => const []);

  final BackupTargetsStore targetsStore;
  final AssetRecordStore recordStore;
  final S3Uploader _s3Uploader;

  /// Present once the private album has been set up. Absent in tests and
  /// on an install that has never opened Hidden, where no hidden record can
  /// exist either.
  final CarrierBuilder? carriers;

  /// Where a hidden photo's carrier is kept on this phone. The bucket is a
  /// second copy, not the only one — see `../vault/store.dart`. Null skips
  /// the local copy, which is what the old behaviour was.
  final VaultStore? vaultStore;
  final VaultKeys? vaultKeys;

  /// The ordinary library, as things a carrier could pretend to be.
  late final Future<List<DecoyCandidate>> Function() _decoyCandidates;

  /// Overridable for tests so they never touch the real filesystem just to
  /// exercise the change-detection bookkeeping.
  final Future<String> Function(String path) _hashFile;

  /// Public because `../vault/object_key.dart` has to produce the same name
  /// without a file in hand, and a second sanitiser is a second answer.
  ///
  /// An already-uploaded derivative keeps its stem ([previousKey]), so an
  /// edit overwrites the object instead of orphaning it under a new name.
  /// A carrier arrives already named; anything else gets the protocol name
  /// (`object_key.dart`).
  static String safeFileName(
    AssetRecord record,
    String filePath, {
    String? previousKey,
  }) {
    final base = p.basename(filePath);
    if (fitsProtocol(base)) return base;
    final stem = previousKey == null
        ? ordinaryBaseName(record)
        : p.basenameWithoutExtension(previousKey);
    return '$stem${p.extension(filePath)}';
  }

  /// If [format] is [BackupFormat.optimized] and [record] is a still photo,
  /// re-encodes the file at [filePath] to WebP in a fresh temp file and
  /// returns its path — the returned path differs from [filePath] exactly
  /// when the caller now owns a temp file it must delete once uploads are
  /// done (see [_cleanupIfTemp]). Falls back to [filePath] unchanged for
  /// videos, [BackupFormat.original], or a re-encode that fails.
  ///
  /// Null for a hidden photo with no carrier: it never goes up in the clear.
  Future<String?> _resolveUploadPath({
    required AssetRecord record,
    required DerivativeKind kind,
    required String filePath,
    required BackupFormat format,
  }) async {
    final carrier = await _carrierPath(
      record: record,
      filePath: filePath,
      motion: kind == DerivativeKind.livePhoto,
    );
    if (carrier != null) return carrier;
    if (record.passcodeHash != null) return null;
    // A Live Photo's `.mov` is never re-encoded. It isn't a still, and the
    // QuickTime metadata that pairs it to the photo — the content
    // identifier, the still-image-time marker — doesn't survive a trip
    // through an image encoder. See `docs/design/uiux/detail.md`.
    if (kind == DerivativeKind.livePhoto) return filePath;
    if (format != BackupFormat.optimized ||
        record.isVideo ||
        record.isLivePhoto) {
      return filePath;
    }
    final ext = p.extension(filePath).toLowerCase();
    if (ext == '.heic' || ext == '.heif') return filePath;
    try {
      // `.heif`, not `.heic`: marks a converted upload, so a restore drill
      // knows these bytes were never the phone's — a HEIC sent as it was
      // keeps `.heic` and is checked byte for byte. Named, not created: the
      // encoder writes it, and nothing here touches the disk first.
      final converted = p.join(
        Directory.systemTemp.path,
        'byop_heif_${DateTime.now().microsecondsSinceEpoch}_'
        '${p.basenameWithoutExtension(filePath)}.heif',
      );
      final wrote = await encodeFileNatively(
        input: filePath,
        output: converted,
        format: 'heic',
      );
      return wrote ? converted : filePath;
    } catch (_) {
      return filePath;
    }
  }

  /// A hidden photo goes up as a carrier: an ordinary-looking picture with
  /// this one encrypted inside it. Null for everything else, and for a
  /// hidden photo whose album is not open — see [canUpload], which holds
  /// the job rather than letting it go up in the clear.
  Future<String?> _carrierPath({
    required AssetRecord record,
    required String filePath,
    bool motion = false,
  }) async {
    final hash = record.passcodeHash;
    final builder = carriers;
    if (hash == null || builder == null) return null;
    final keys = vaultKeys?.ringKeysFor(hash);
    if (keys == null) return null;
    final still = record.sourcePath;
    if (motion && still == null) return null;
    final built = await builder.build(
      record: record,
      filePath: filePath,
      keys: keys,
      candidates: await _decoyCandidates(),
      motionOf: motion ? still : null,
    );
    return built?.path;
  }

  /// Files a freshly built carrier in the vault store, keyed by the
  /// prefix-independent [objectKey] the album index uses.
  ///
  /// A no-op for anything that isn't a hidden photo, and for a carrier that
  /// is already there — the queue re-offers work, and rewriting a multi-
  /// megabyte file to reach the same bytes is wasted I/O.
  Future<void> _keepCarrierLocally({
    required AssetRecord record,
    required String carrierPath,
    required String objectKey,
  }) async {
    final hash = record.passcodeHash;
    final store = vaultStore;
    if (hash == null || store == null) return;
    final keys = vaultKeys?.ringKeysFor(hash);
    if (keys == null) return;
    // Only a real carrier: with no decoy to wear, `_carrierPath` hands back
    // the plaintext path and the upload is refused. Keeping *that* would put
    // an unencrypted hidden photo in the container.
    if (carrierPath == record.sourcePath) return;
    if (await store.hasCarrier(keys, objectKey)) return;
    await store.putCarrier(keys, objectKey, File(carrierPath));
  }

  /// Whether this record may leave the device at all right now. A hidden
  /// photo may not while its album is locked: the key exists only in
  /// memory, and sending the photo up unencrypted "for now" is the one
  /// outcome the private album must never produce.
  bool canUpload(AssetRecord record) {
    final hash = record.passcodeHash;
    if (hash == null) return true;
    if (carriers == null || vaultKeys == null) return false;
    return vaultKeys!.ringKeysFor(hash) != null;
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
    // Left `pending`, deliberately: the queue will offer it again once the
    // album is open, and a `failed` here would read as something the user
    // has to fix.
    if (!canUpload(record)) return 0;
    // The key stays: an earlier upload is still in the bucket, and a record
    // that forgot it would read as having nothing left there. Read fresh —
    // hiding clears it, and a stale [record] would put it back.
    final previousKey = (await recordStore.getByLocalId(record.localId))
        ?.stateOf(kind)
        .destinationKey;
    await recordStore.updateDerivative(
      record.localId,
      kind,
      DerivativeState(
        status: UploadStatus.uploading,
        destinationKey: previousKey,
      ),
    );

    final resolvedTargets = targets ?? await targetsStore.loadAll();
    final format = await targetsStore.getBackupFormat();
    final uploadPath = await _resolveUploadPath(
      record: record,
      kind: kind,
      filePath: filePath,
      format: format,
    );
    if (uploadPath == null) {
      await recordStore.updateDerivative(
        record.localId,
        kind,
        DerivativeState(
          status: UploadStatus.pending,
          destinationKey: previousKey,
        ),
      );
      return 0;
    }
    final fileName = safeFileName(record, uploadPath, previousKey: previousKey);
    final derivativeDir = derivativeDirs[kind]!;

    // The local copy first, before a single byte goes anywhere. A hidden
    // photo has been taken out of Photos, so between the copy-out and the
    // upload this app is the only thing holding it — and the carrier is the
    // form it is held in, which is why this is the same file the upload
    // reads rather than a second encryption of the same bytes.
    await _keepCarrierLocally(
      record: record,
      carrierPath: uploadPath,
      objectKey: vaultObjectKey(derivativeDir, fileName),
    );

    // What each target already has, of this exact file. A retry after one
    // target failed must not re-send to the one that worked — on a video
    // that is minutes and somebody's data plan, twice.
    final sourceHash = await _hashOrNull(filePath);
    final held = await recordStore.targetsHolding(
      record.localId,
      kind,
      sourceHash: sourceHash,
    );
    // A row from before per-target state existed says "some target has this"
    // and cannot say which. Treated as covering everything, which is what
    // the app believed anyway; a fresh upload records the truth.
    final legacy = held.containsKey('');

    var succeeded = 0;
    String? firstDestinationKey;
    try {
      for (final target in resolvedTargets) {
        final key = derivativeKey(
          prefix: target.prefix,
          derivativeDir: derivativeDir,
          fileName: fileName,
        );
        if (legacy || held.containsKey(target.id)) {
          succeeded++;
          firstDestinationKey ??= key;
          continue;
        }
        final ok = await _s3Uploader.put(
          filePath: uploadPath,
          key: key,
          target: target,
        );
        if (ok) {
          succeeded++;
          firstDestinationKey ??= key;
          await recordStore.recordUpload(
            localId: record.localId,
            kind: kind,
            targetId: target.id,
            destinationKey: key,
            sourceHash: sourceHash,
          );
        }
      }
    } finally {
      await _cleanupIfTemp(uploadPath, filePath);
    }

    // **Every** target, not any of them. One of two buckets failing used to
    // be recorded as a backup, and an `uploaded` derivative is never offered
    // again — so the bucket that missed it stayed empty for good while the
    // library reported itself safe. Short of all of them it is a failure,
    // which the queue retries and which is at least true.
    final finalStatus = resolvedTargets.isEmpty
        ? UploadStatus.pending
        : (succeeded == resolvedTargets.length
              ? UploadStatus.uploaded
              : UploadStatus.failed);
    await recordStore.updateDerivative(
      record.localId,
      kind,
      DerivativeState(
        status: finalStatus,
        destinationKey: firstDestinationKey ?? previousKey,
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
  Future<String?> _hashOrNull(String filePath) async {
    try {
      return await _hashFile(filePath);
    } catch (_) {
      return null;
    }
  }

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
  /// Returns the count of records that landed on every target.
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
          if (targets.isNotEmpty && count == targets.length) succeeded++;
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
          kind: kind,
          filePath: rawPath,
          format: format,
        );
        if (uploadPath == null) continue;
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
    // Same per-target bookkeeping as [uploadDerivative]: a target that
    // already has this version is skipped, and only all of them is a backup.
    final held = <String, Map<String, String>>{};
    final sourceHashes = <String, String?>{};
    final previousKeys = <String, String?>{};
    final derivativeDir = derivativeDirs[kind]!;
    outer:
    for (final target in targets) {
      for (final record in records) {
        if (cancelToken?.isCancelled == true) break outer;
        final path = paths[record.localId];
        if (path == null) continue;
        final id = record.localId;
        if (attempted.add(id)) {
          final sourceHash = await _hashOrNull(rawPaths[id]!);
          sourceHashes[id] = sourceHash;
          held[id] = await recordStore.targetsHolding(
            id,
            kind,
            sourceHash: sourceHash,
          );
          final previousKey = (await recordStore.getByLocalId(id))
              ?.stateOf(kind)
              .destinationKey;
          previousKeys[id] = previousKey;
          await recordStore.updateDerivative(
            id,
            kind,
            DerivativeState(
              status: UploadStatus.uploading,
              destinationKey: previousKey,
            ),
          );
        }
        try {
          final fileName = safeFileName(
            record,
            path,
            previousKey: previousKeys[id],
          );
          final key = derivativeKey(
            prefix: target.prefix,
            derivativeDir: derivativeDir,
            fileName: fileName,
          );
          final has = held[id]!;
          final ok =
              has.containsKey('') ||
              has.containsKey(target.id) ||
              await _s3Uploader.put(filePath: path, key: key, target: target);
          if (ok) {
            if (!has.containsKey('') && !has.containsKey(target.id)) {
              await recordStore.recordUpload(
                localId: id,
                kind: kind,
                targetId: target.id,
                destinationKey: key,
                sourceHash: sourceHashes[id],
              );
            }
            successCounts.update(id, (v) => v + 1, ifAbsent: () => 1);
            firstKeys.putIfAbsent(id, () => key);
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
      final landed = successCounts[record.localId] ?? 0;
      // Every target, as in [uploadDerivative]: short of that it is retried.
      final ok = landed == targets.length;
      await recordStore.updateDerivative(
        record.localId,
        kind,
        DerivativeState(
          status: ok ? UploadStatus.uploaded : UploadStatus.failed,
          destinationKey:
              firstKeys[record.localId] ?? previousKeys[record.localId],
          backedUpHash: await _hashOnSuccess(
            landed > 0,
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
