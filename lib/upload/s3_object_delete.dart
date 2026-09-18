import 'package:aws_common/aws_common.dart';
import 'package:aws_signature_v4/aws_signature_v4.dart';
import 'package:http/http.dart' as http;

import '../settings/bucket_endpoint.dart';
import '../settings/s3_backup_target.dart';

/// Deletes one object from the bucket — signed `DELETE`, same credentials
/// and signing as every other call this app makes.
///
/// Only ever reached from a *permanent* delete. Everything short of that
/// leaves the bucket alone: the backed-up copy is the one that survives a
/// lost phone, so it outlives the local record on purpose, and emptying
/// this app's Recently Deleted is the one action that says otherwise.
///
/// Returns whether the object is gone, which includes it never having been
/// there: S3 answers a delete for a missing key with `204` anyway, and a
/// `404` from a since-changed prefix means the same thing for our purposes.
/// Failing loudly on "already absent" would strand records that can never
/// be finally deleted.
Future<bool> deleteObject({
  required S3BackupTarget target,
  required String key,
  http.Client? client,
}) async {
  final signer = AWSSigV4Signer(
    credentialsProvider: AWSCredentialsProvider(
      AWSCredentials(target.accessKeyId, target.secretAccessKey),
    ),
  );
  final scope = AWSCredentialScope.raw(
    region: signingRegion(target),
    service: 's3',
  );
  final uri = targetUri(target, path: '/$key');

  final http.Client httpClient = client ?? http.Client();
  try {
    final signed = await signer.sign(
      AWSHttpRequest(method: AWSHttpMethod.delete, uri: uri),
      credentialScope: scope,
      serviceConfiguration: S3ServiceConfiguration(),
    );
    final response = await httpClient.delete(
      signed.uri,
      headers: signed.headers,
    );
    return response.statusCode == 204 ||
        response.statusCode == 200 ||
        response.statusCode == 404;
  } catch (_) {
    return false;
  } finally {
    if (client == null) httpClient.close();
  }
}
