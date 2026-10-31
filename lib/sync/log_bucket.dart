import 'dart:convert';
import 'dart:io' show HttpDate;

import 'package:aws_common/aws_common.dart';
import 'package:aws_signature_v4/aws_signature_v4.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../settings/backup_storage_type.dart';
import '../settings/bucket_endpoint.dart';
import '../settings/s3_backup_target.dart';
import '../settings/s3_xml.dart' as sx;
import '../upload/bucket_http.dart';

class LogObject {
  const LogObject(this.key, this.lastModified);

  /// Relative to the target's prefix.
  final String key;
  final int lastModified;
}

enum PutOnce { written, existsSame, collision }

/// What sync needs from the home bucket. [S3LogBucket] in the app, a fake
/// in tests. Keys are relative to the target's prefix.
abstract class LogBucket {
  /// Bucket time in ms: local clock corrected by the last `Date` header.
  int now();
  Future<List<String>> folders(String prefix);
  Future<List<LogObject>> list(String prefix, {String? startAfter});
  Future<List<int>> get(String key);
  Future<void> put(String key, List<int> body, {String contentType});

  /// Never overwrites; a second try of the same bytes is [PutOnce.existsSame].
  Future<PutOnce> putOnce(String key, List<int> body);
}

class LogBucketError implements Exception {
  LogBucketError(this.status, this.detail);
  final int status;
  final String detail;
  @override
  String toString() => 'bucket $status: $detail';
}

/// [LogBucket] over the S3 API of S3, COS and OSS — small objects only, so
/// plain signed requests rather than the background transfer photos use.
class S3LogBucket implements LogBucket {
  S3LogBucket(this.target, {http.Client? client})
    : _client = client ?? http.Client();

  final S3BackupTarget target;
  final http.Client _client;
  int _offset = 0;

  String get _prefix => target.prefix.isEmpty || target.prefix.endsWith('/')
      ? target.prefix
      : '${target.prefix}/';

  @override
  int now() => DateTime.now().millisecondsSinceEpoch + _offset;

  Future<http.Response> _send(
    String method,
    String key, {
    Map<String, String> query = const {},
    Map<String, String> headers = const {},
    List<int> body = const [],
  }) async {
    final signer = AWSSigV4Signer(
      credentialsProvider: AWSCredentialsProvider(
        AWSCredentials(target.accessKeyId, target.secretAccessKey),
      ),
    );
    final request = AWSHttpRequest(
      method: AWSHttpMethod.fromString(method),
      uri: targetUri(target, path: '/$key', query: query),
      headers: headers,
      body: body,
    );
    final signed = await signer.sign(
      request,
      credentialScope: AWSCredentialScope.raw(
        region: signingRegion(target),
        service: 's3',
      ),
      serviceConfiguration: S3ServiceConfiguration(),
    );
    final out = http.Request(method, signed.uri)
      ..headers.addAll(signed.headers)
      ..bodyBytes = body;
    final response = await http.Response.fromStream(
      await bucketRequest(_client.send(out)),
    );
    final date = response.headers['date'];
    if (date != null) {
      try {
        _offset =
            HttpDate.parse(date).millisecondsSinceEpoch -
            DateTime.now().millisecondsSinceEpoch;
      } catch (_) {}
    }
    return response;
  }

  Never _fail(http.Response r) => throw LogBucketError(
    r.statusCode,
    sx.textOf(utf8.decode(r.bodyBytes, allowMalformed: true), 'Code') ??
        r.reasonPhrase ??
        '',
  );

  Future<(List<LogObject>, List<String>)> _list(
    String prefix, {
    String? startAfter,
    String? delimiter,
  }) async {
    final objects = <LogObject>[];
    final folders = <String>[];
    String? token;
    do {
      final r = await _send(
        'GET',
        '',
        query: {
          'list-type': '2',
          'prefix': '$_prefix$prefix',
          'start-after': ?(startAfter == null ? null : '$_prefix$startAfter'),
          'delimiter': ?delimiter,
          'continuation-token': ?token,
        },
      );
      if (r.statusCode != 200) _fail(r);
      final xml = utf8.decode(r.bodyBytes);
      for (final block in sx.blocksOf(xml, 'Contents')) {
        final key = sx.textOf(block, 'Key') ?? '';
        final at = DateTime.tryParse(sx.textOf(block, 'LastModified') ?? '');
        objects.add(
          LogObject(
            key.substring(_prefix.length),
            at?.millisecondsSinceEpoch ?? 0,
          ),
        );
      }
      for (final block in sx.blocksOf(xml, 'CommonPrefixes')) {
        final p = sx.textOf(block, 'Prefix');
        if (p != null) folders.add(p.substring(_prefix.length));
      }
      token = sx.textOf(xml, 'IsTruncated') == 'true'
          ? sx.textOf(xml, 'NextContinuationToken')
          : null;
    } while (token != null);
    return (objects, folders);
  }

  @override
  Future<List<String>> folders(String prefix) async =>
      (await _list(prefix, delimiter: '/')).$2;

  @override
  Future<List<LogObject>> list(String prefix, {String? startAfter}) async =>
      (await _list(prefix, startAfter: startAfter)).$1;

  @override
  Future<List<int>> get(String key) async {
    final r = await _send('GET', '$_prefix$key');
    if (r.statusCode != 200) _fail(r);
    return r.bodyBytes;
  }

  @override
  Future<void> put(
    String key,
    List<int> body, {
    String contentType = 'application/octet-stream',
  }) async {
    final r = await _send(
      'PUT',
      '$_prefix$key',
      body: body,
      headers: {'content-type': contentType},
    );
    if (r.statusCode != 200) _fail(r);
  }

  @override
  Future<PutOnce> putOnce(String key, List<int> body) async {
    final (name, value) = switch (target.provider) {
      BackupStorageType.tencentCos => ('x-cos-forbid-overwrite', 'true'),
      BackupStorageType.aliyunOss => ('x-oss-forbid-overwrite', 'true'),
      _ => ('if-none-match', '*'),
    };
    final r = await _send(
      'PUT',
      '$_prefix$key',
      body: body,
      headers: {name: value, 'content-type': 'application/gzip'},
    );
    if (r.statusCode == 200) return PutOnce.written;
    if (r.statusCode != 412 && r.statusCode != 409) _fail(r);
    final there = await get(key);
    return sha256.convert(there) == sha256.convert(body)
        ? PutOnce.existsSame
        : PutOnce.collision;
  }
}
