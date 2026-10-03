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
/// Why the last [targetHolding] found nothing: what each bucket answered.
/// Shown under the "couldn't reach" message so it says which step failed.
String? lastLookupDetail;

Future<S3BackupTarget?> targetHolding(
  String objectKey, {
  BackupTargetsStore? targetsStore,
  Future<http.Response> Function(Uri url, {Map<String, String>? headers})? get,
}) async {
  final fetch = get ?? http.get;
  final answers = <String>[];
  lastLookupDetail = null;
  final targets = await (targetsStore ?? BackupTargetsStore()).loadAll();
  if (targets.isEmpty) lastLookupDetail = 'no bucket saved';
  for (final target in targets) {
    try {
      final response = await fetch(
        await presignGetUrl(target: target, key: objectKey),
        headers: {'Range': 'bytes=0-0'},
      );
      if (response.statusCode == 206 || response.statusCode == 200) {
        return target;
      }
      answers.add('${response.statusCode}');
    } catch (e) {
      // Unreachable bucket, expired credentials — the next one may hold it.
      answers.add(e.runtimeType.toString());
    }
  }
  if (answers.isNotEmpty) lastLookupDetail = answers.join(', ');
  return null;
}
