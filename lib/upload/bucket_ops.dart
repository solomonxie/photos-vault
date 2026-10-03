import 'dart:typed_data';

import 'package:aws_common/aws_common.dart';
import 'package:aws_signature_v4/aws_signature_v4.dart';
import 'package:http/http.dart' as http;

import '../settings/bucket_endpoint.dart';
import '../settings/s3_backup_target.dart';
import '../settings/s3_listing.dart';
import '../vault/carrier_probe.dart';
import 's3_object_delete.dart';
import 'signing.dart';

/// The few things done to a bucket that are not an upload: list a folder
/// flat, read a byte range, copy within it, and check an object is there.
/// None moves a photo through the phone - a copy is the bucket's own.
class BucketOps {
  BucketOps({this._client});

  final http.Client? _client;

  /// Every object directly under [dir] (e.g. `originals/`) in [target]'s own
  /// prefix, all pages. Null when the bucket cannot be listed.
  Future<List<S3Object>?> listFolder(S3BackupTarget target, String dir) async {
    final out = <S3Object>[];
    String? token;
    do {
      final result = await listBucket(
        target: target,
        prefix: '${target.prefix}$dir',
        continuationToken: token,
      );
      final page = result.page;
      if (!result.isOk || page == null) return null;
      out.addAll(page.objects);
      token = page.nextToken;
    } while (token != null);
    return out;
  }

  RangeReader rangeReader(S3BackupTarget target, String key) =>
      (start, end) async {
        if (end <= start) return Uint8List(0);
        try {
          final response = await (_client?.get ?? http.get)(
            await presignGetUrl(target: target, key: key),
            headers: {'Range': 'bytes=$start-${end - 1}'},
          );
          if (response.statusCode != 206 && response.statusCode != 200) {
            return null;
          }
          return response.bodyBytes;
        } catch (_) {
          return null;
        }
      };

  /// The object's size, or null when it is not there.
  Future<int?> sizeOf(S3BackupTarget target, String key) async {
    try {
      final response = await (_client?.head ?? http.head)(
        await presignHeadUrl(target: target, key: key),
      );
      if (response.statusCode != 200) return null;
      return int.tryParse(response.headers['content-length'] ?? '');
    } catch (_) {
      return null;
    }
  }

  /// Server-side copy, then a size check on the new object. A single copy
  /// request handles up to 5 GB; larger objects fail and are left alone.
  Future<bool> copy({
    required S3BackupTarget target,
    required String from,
    required String to,
    required int expectedSize,
  }) async {
    final signer = AWSSigV4Signer(
      credentialsProvider: AWSCredentialsProvider(
        AWSCredentials(target.accessKeyId, target.secretAccessKey),
      ),
    );
    final source =
        '/${target.bucket}/${from.split('/').map(Uri.encodeComponent).join('/')}';
    final client = _client ?? http.Client();
    try {
      final signed = await signer.sign(
        AWSHttpRequest(
          method: AWSHttpMethod.put,
          uri: targetUri(target, path: '/$to'),
          headers: {'x-amz-copy-source': source},
        ),
        credentialScope: AWSCredentialScope.raw(
          region: signingRegion(target),
          service: 's3',
        ),
        serviceConfiguration: S3ServiceConfiguration(),
      );
      final response = await client.put(signed.uri, headers: signed.headers);
      if (response.statusCode != 200 || response.body.contains('<Error>')) {
        return false;
      }
      return await sizeOf(target, to) == expectedSize;
    } catch (_) {
      return false;
    } finally {
      if (_client == null) client.close();
    }
  }

  Future<bool> delete(S3BackupTarget target, String key) =>
      deleteObject(target: target, key: key, client: _client);
}
