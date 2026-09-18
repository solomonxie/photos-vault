import 'package:aws_common/aws_common.dart';
import 'package:aws_signature_v4/aws_signature_v4.dart';

import '../settings/bucket_endpoint.dart';
import '../settings/s3_backup_target.dart';

/// Builds the key layout every derivative lands under (`thumbnails/`,
/// `medium/`, `originals/` under the target's configured prefix) so the
/// user's own S3 Lifecycle Rules can target each class independently.
String derivativeKey({
  required String prefix,
  required String derivativeDir,
  required String fileName,
}) {
  final normalizedPrefix = prefix.isEmpty || prefix.endsWith('/')
      ? prefix
      : '$prefix/';
  return '$normalizedPrefix$derivativeDir/$fileName';
}

/// A presigned single-part `PUT` URL for [key] in [target], valid for
/// [expiresIn] (default 15 minutes — long enough for a background upload
/// task to pick it up without needing to re-sign).
Future<Uri> presignPutUrl({
  required S3BackupTarget target,
  required String key,
  Duration expiresIn = const Duration(minutes: 15),
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
  final request = AWSHttpRequest.put(uri, body: const []);
  return signer.presign(
    request,
    credentialScope: scope,
    serviceConfiguration: S3ServiceConfiguration(),
    expiresIn: expiresIn,
  );
}

/// A presigned `GET` URL for [key] in [target] — the Bucket Browser's
/// object preview, so viewing a file doesn't need it made public.
Future<Uri> presignGetUrl({
  required S3BackupTarget target,
  required String key,
  Duration expiresIn = const Duration(minutes: 15),
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
  final request = AWSHttpRequest.get(uri);
  return signer.presign(
    request,
    credentialScope: scope,
    serviceConfiguration: S3ServiceConfiguration(),
    expiresIn: expiresIn,
  );
}
