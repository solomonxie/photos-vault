import 'dart:typed_data';

import 'package:photos_vault/settings/s3_backup_target.dart';
import 'package:photos_vault/settings/s3_listing.dart';
import 'package:photos_vault/upload/bucket_ops.dart';
import 'package:photos_vault/vault/carrier_probe.dart';

/// A bucket held in a map: copy, delete, size and range reads all work on it.
class MemoryBucket extends BucketOps {
  final objects = <String, Uint8List>{};
  final lastModified = DateTime(2026, 10, 3, 9);

  @override
  Future<List<S3Object>?> listFolder(
    S3BackupTarget target,
    String dir,
  ) async => [
    for (final e in objects.entries)
      if (e.key.startsWith('${target.prefix}$dir') &&
          !e.key.substring('${target.prefix}$dir'.length).contains('/'))
        S3Object(key: e.key, size: e.value.length, lastModified: lastModified),
  ];

  @override
  RangeReader rangeReader(S3BackupTarget target, String key) =>
      (start, end) async {
        final bytes = objects[key];
        if (bytes == null) return null;
        return Uint8List.sublistView(
          bytes,
          start,
          end > bytes.length ? bytes.length : end,
        );
      };

  @override
  Future<int?> sizeOf(S3BackupTarget target, String key) async =>
      objects[key]?.length;

  @override
  Future<bool> copy({
    required S3BackupTarget target,
    required String from,
    required String to,
    required int expectedSize,
  }) async {
    final bytes = objects[from];
    if (bytes == null) return false;
    objects[to] = bytes;
    return true;
  }

  @override
  Future<bool> delete(S3BackupTarget target, String key) async {
    objects.remove(key);
    return true;
  }
}
