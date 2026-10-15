import 'dart:typed_data';

import 'package:photos_vault/settings/s3_backup_target.dart';
import 'package:photos_vault/upload/bucket_ops.dart';
import 'package:photos_vault/vault/carrier_probe.dart';

/// A bucket where every key is an ordinary file that is there, and the
/// DELETE answers whatever [onDelete] says. For tests about what is asked to
/// go, not about the guard's checks.
class ScriptedDeletes extends BucketOps {
  ScriptedDeletes(this.onDelete);

  final Future<bool> Function(S3BackupTarget target, String key) onDelete;

  @override
  Future<ObjectHead> head(S3BackupTarget target, String key) async =>
      const ObjectHead(Probe.present, size: 16, etag: 'e');

  @override
  RangeReader rangeReader(S3BackupTarget target, String key) =>
      (start, end) async => Uint8List(end - start);

  @override
  Future<bool> rawDelete(S3BackupTarget target, String key) =>
      onDelete(target, key);
}
