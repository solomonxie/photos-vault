import 'dart:convert';

import 'package:aws_common/aws_common.dart';
import 'package:aws_signature_v4/aws_signature_v4.dart';
import 'package:http/http.dart' as http;

import 'backup_storage_type.dart';
import 'bucket_endpoint.dart';
import 's3_xml.dart' as sx;

enum S3AccessCheckOutcome { ok, forbidden, notFound, networkError }

class S3AccessCheckResult {
  const S3AccessCheckResult(this.outcome, [this.detail]);

  final S3AccessCheckOutcome outcome;

  /// The AWS error code (e.g. `InvalidAccessKeyId`, `SignatureDoesNotMatch`,
  /// `AccessDenied`) when available — each means something different to fix.
  final String? detail;

  bool get isOk => outcome == S3AccessCheckOutcome.ok;
}

/// Verifies the given credentials can reach [bucket] in [region] on
/// [provider] — a signed `ListObjectsV2` request (needs `s3:ListBucket`,
/// the same permission actual backups will need). Uses `GET`, not `HEAD`:
/// the S3 API only includes the diagnostic `<Code>`/`<Message>` XML body on
/// non-HEAD requests, and that detail is the difference between "wrong
/// key", "wrong secret", and "right credentials, no permission".
///
/// This is also where a wrong region shows up for COS and OSS, which can't
/// be asked for one ahead of time the way S3's bucket name can: the
/// endpoint for the wrong region answers 404 rather than redirecting.
Future<S3AccessCheckResult> checkBucketAccess({
  required String accessKeyId,
  required String secretAccessKey,
  required String region,
  required String bucket,
  BackupStorageType provider = BackupStorageType.s3,
}) async {
  final signer = AWSSigV4Signer(
    credentialsProvider: AWSCredentialsProvider(
      AWSCredentials(accessKeyId, secretAccessKey),
    ),
  );
  final scope = AWSCredentialScope.raw(region: region, service: 's3');
  final uri = bucketUri(
    provider: provider,
    region: region,
    bucket: bucket,
    query: {'list-type': '2', 'max-keys': '1'},
  );
  final request = AWSHttpRequest.get(uri);

  try {
    final signed = await signer.sign(
      request,
      credentialScope: scope,
      serviceConfiguration: S3ServiceConfiguration(),
    );
    final response = await http.get(signed.uri, headers: signed.headers);
    // Not `response.body` — see s3_listing.dart's `listBucket` for why.
    final errorCode = _errorCodeFrom(utf8.decode(response.bodyBytes));
    switch (response.statusCode) {
      case 200:
        return const S3AccessCheckResult(S3AccessCheckOutcome.ok);
      case 403:
        return S3AccessCheckResult(
          S3AccessCheckOutcome.forbidden,
          errorCode ?? response.statusCode.toString(),
        );
      case 404:
        return S3AccessCheckResult(
          S3AccessCheckOutcome.notFound,
          errorCode ?? response.statusCode.toString(),
        );
      default:
        return S3AccessCheckResult(
          S3AccessCheckOutcome.networkError,
          errorCode ?? response.statusCode.toString(),
        );
    }
  } catch (e) {
    return S3AccessCheckResult(S3AccessCheckOutcome.networkError, e.toString());
  }
}

String? _errorCodeFrom(String xmlBody) => sx.textOf(xmlBody, 'Code');
