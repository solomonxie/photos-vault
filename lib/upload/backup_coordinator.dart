import 'package:path/path.dart' as p;

import '../settings/backup_targets_store.dart';
import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
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
  BackupCoordinator({required this.targetsStore, required this.recordStore, S3Uploader? s3Uploader})
    : _s3Uploader = s3Uploader ?? S3Uploader();

  final BackupTargetsStore targetsStore;
  final AssetRecordStore recordStore;
  final S3Uploader _s3Uploader;

  static String _safeFileName(AssetRecord record, String filePath) {
    final base = record.localId.replaceAll(RegExp(r'[^a-zA-Z0-9_.-]'), '_');
    return '$base${p.extension(filePath)}';
  }

  /// Sends [filePath] (the asset's [kind] derivative) to every configured
  /// target and records the aggregate outcome. Returns the count of targets
  /// it landed on successfully (0 if none configured or all failed).
  Future<int> backUpDerivative({
    required AssetRecord record,
    required DerivativeKind kind,
    required String filePath,
  }) async {
    await recordStore.updateDerivative(record.localId, kind, const DerivativeState(status: UploadStatus.uploading));

    final targets = await targetsStore.loadAll();
    final fileName = _safeFileName(record, filePath);
    final derivativeDir = _derivativeDirs[kind]!;

    var succeeded = 0;
    String? firstDestinationKey;
    for (final target in targets) {
      final key = derivativeKey(prefix: target.prefix, derivativeDir: derivativeDir, fileName: fileName);
      final ok = await _s3Uploader.put(filePath: filePath, key: key, target: target);
      if (ok) {
        succeeded++;
        firstDestinationKey ??= key;
      }
    }

    final finalStatus = targets.isEmpty
        ? UploadStatus.pending
        : (succeeded > 0 ? UploadStatus.uploaded : UploadStatus.failed);
    await recordStore.updateDerivative(
      record.localId,
      kind,
      DerivativeState(status: finalStatus, destinationKey: firstDestinationKey),
    );
    return succeeded;
  }
}
