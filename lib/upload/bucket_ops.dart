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

  /// Why the last [copy] failed, for the line shown under a failed fix.
  String? lastError;

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

  /// [listFolder] one page at a time: [onPage] gets each page and the token
  /// that continues after it (null on the last), so a caller can persist its
  /// place and pass it back as [startToken] after a restart. False when a
  /// page could not be listed.
  Future<bool> listFolderPages(
    S3BackupTarget target,
    String dir, {
    String? startToken,
    required Future<void> Function(List<S3Object> page, String? nextToken)
    onPage,
  }) async {
    var token = startToken;
    do {
      final result = await listBucket(
        target: target,
        prefix: '${target.prefix}$dir',
        continuationToken: token,
      );
      final page = result.page;
      if (!result.isOk || page == null) return false;
      token = page.nextToken;
      await onPage(page.objects, token);
    } while (token != null);
    return true;
  }

  /// A stalled connection otherwise waits forever, and everything queued
  /// behind it with it.
  static const _timeout = Duration(seconds: 20);

  /// A server-side copy of a large video takes a while on the bucket's end.
  static const _copyTimeout = Duration(minutes: 3);

  RangeReader rangeReader(S3BackupTarget target, String key) =>
      (start, end) async {
        if (end <= start) return Uint8List(0);
        try {
          final response = await (_client?.get ?? http.get)(
            await presignGetUrl(target: target, key: key),
            headers: {'Range': 'bytes=$start-${end - 1}'},
          ).timeout(_timeout);
          if (response.statusCode != 206 && response.statusCode != 200) {
            return null;
          }
          return response.bodyBytes;
        } catch (_) {
          return null;
        }
      };

  /// The object's ETag — its MD5 for a single-part upload — or null when it
  /// can't be had. Two objects with the same size and ETag are the same
  /// bytes.
  Future<String?> etagOf(S3BackupTarget target, String key) async {
    try {
      final response = await (_client?.head ?? http.head)(
        await presignHeadUrl(target: target, key: key),
      ).timeout(_timeout);
      if (response.statusCode != 200) return null;
      return response.headers['etag']?.replaceAll('"', '');
    } catch (_) {
      return null;
    }
  }

  /// The object's size, or null when it is not there.
  Future<int?> sizeOf(S3BackupTarget target, String key) async {
    try {
      final response = await (_client?.head ?? http.head)(
        await presignHeadUrl(target: target, key: key),
      ).timeout(_timeout);
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
      final response = await client
          .put(signed.uri, headers: signed.headers)
          .timeout(_copyTimeout);
      if (response.statusCode != 200 || response.body.contains('<Error>')) {
        final code = RegExp(r'<Code>([^<]+)</Code>').firstMatch(response.body);
        lastError = 'copy ${response.statusCode} ${code?[1] ?? ''}'.trim();
        return false;
      }
      final landed = await sizeOf(target, to);
      if (landed != expectedSize) {
        lastError = 'copy landed $landed of $expectedSize bytes';
        return false;
      }
      return true;
    } catch (e) {
      lastError = 'copy ${e.runtimeType}';
      return false;
    } finally {
      if (_client == null) client.close();
    }
  }

  Future<bool> delete(S3BackupTarget target, String key) =>
      deleteObject(target: target, key: key, client: _client);
}
