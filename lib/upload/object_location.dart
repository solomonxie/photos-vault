import 'package:http/http.dart' as http;

import '../settings/backup_targets_store.dart';
import '../settings/s3_backup_target.dart';
import 'signing.dart';

/// Which configured target actually holds [objectKey].
///
/// A key on its own points nowhere: the same photo is uploaded to every
/// target, each under its own prefix, and a record only remembers one key.
/// So the object is asked for, target by target, before anything claims to
/// know where it is.
///
/// A one-byte ranged GET rather than a HEAD — it is the same presigned GET
/// the rest of the app uses, and S3-compatible endpoints differ on whether
/// a GET signature is accepted for a HEAD.
Future<S3BackupTarget?> targetHolding(
  String objectKey, {
  BackupTargetsStore? targetsStore,
  Future<http.Response> Function(Uri url, {Map<String, String>? headers})? get,
}) async {
  final fetch = get ?? http.get;
  for (final target in await (targetsStore ?? BackupTargetsStore()).loadAll()) {
    try {
      final response = await fetch(
        await presignGetUrl(target: target, key: objectKey),
        headers: {'Range': 'bytes=0-0'},
      );
      if (response.statusCode == 206 || response.statusCode == 200) {
        return target;
      }
    } catch (_) {
      // Unreachable bucket, expired credentials — the next one may hold it.
    }
  }
  return null;
}
