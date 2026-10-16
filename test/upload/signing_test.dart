import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:photos_vault/settings/s3_backup_target.dart';
import 'package:photos_vault/upload/s3_object_delete.dart';
import 'package:photos_vault/upload/signing.dart';

const _secret = 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY';
const _target = S3BackupTarget(
  id: 't1',
  accessKeyId: 'AKIDEXAMPLE',
  secretAccessKey: _secret,
  region: 'eu-west-2',
  bucket: 'my-photos',
  prefix: 'vault',
);

String _encode(String s) => Uri.encodeComponent(s).replaceAllMapped(
  RegExp(r"[!'()*]"),
  (m) => '%${m[0]!.codeUnitAt(0).toRadixString(16).toUpperCase()}',
);

List<int> _hmac(List<int> key, String data) =>
    Hmac(sha256, key).convert(utf8.encode(data)).bytes;

/// SigV4 for a presigned S3 URL, written from the spec rather than taken
/// from the signing package: the bucket refuses anything else.
String _expectedSignature(String method, Uri url) {
  final q = Map.of(url.queryParameters)..remove('X-Amz-Signature');
  final query = (q.keys.toList()..sort())
      .map((k) => '${_encode(k)}=${_encode(q[k]!)}')
      .join('&');
  final canonical = [
    method,
    url.path,
    query,
    'host:${url.host}\n',
    'host',
    'UNSIGNED-PAYLOAD',
  ].join('\n');
  final amzDate = q['X-Amz-Date']!;
  final day = amzDate.substring(0, 8);
  final scope = '$day/eu-west-2/s3/aws4_request';
  final toSign = [
    'AWS4-HMAC-SHA256',
    amzDate,
    scope,
    sha256.convert(utf8.encode(canonical)).toString(),
  ].join('\n');
  var key = _hmac(utf8.encode('AWS4$_secret'), day);
  for (final part in ['eu-west-2', 's3', 'aws4_request']) {
    key = _hmac(key, part);
  }
  return Hmac(sha256, key).convert(utf8.encode(toSign)).toString();
}

void main() {
  group('presigned URLs', () {
    for (final (method, presign) in [
      ('GET', presignGetUrl),
      ('HEAD', presignHeadUrl),
      ('PUT', presignPutUrl),
    ]) {
      test('$method is signed for its own method, host and key', () async {
        final url = await presign(
          target: _target,
          key: 'vault/originals/IMG 1.HEIC',
        );
        expect(url.scheme, 'https');
        expect(url.host, 'my-photos.s3.eu-west-2.amazonaws.com');
        expect(url.path, '/vault/originals/IMG%201.HEIC');
        final q = url.queryParameters;
        expect(q['X-Amz-Algorithm'], 'AWS4-HMAC-SHA256');
        expect(
          q['X-Amz-Credential'],
          matches(RegExp(r'^AKIDEXAMPLE/\d{8}/eu-west-2/s3/aws4_request$')),
        );
        expect(q['X-Amz-Expires'], '900');
        expect(q['X-Amz-SignedHeaders'], 'host');
        expect(q.values.any((v) => v.contains(_secret)), isFalse);
        expect(q['X-Amz-Signature'], _expectedSignature(method, url));
      });
    }

    test('a GET signature does not pass for HEAD', () async {
      final url = await presignGetUrl(target: _target, key: 'k.jpg');
      expect(
        _expectedSignature('HEAD', url),
        isNot(url.queryParameters['X-Amz-Signature']),
      );
    });
  });

  group('deleteObject', () {
    Future<(bool, http.Request?)> delete(
      Future<http.Response> Function(http.Request) answer,
    ) async {
      http.Request? seen;
      final gone = await deleteObject(
        target: _target,
        key: 'vault/originals/IMG_1.HEIC',
        client: MockClient((request) {
          seen = request;
          return answer(request);
        }),
      );
      return (gone, seen);
    }

    test('sends one signed DELETE for exactly that key', () async {
      final (gone, request) = await delete((_) async => http.Response('', 204));
      expect(gone, isTrue);
      expect(request!.method, 'DELETE');
      expect(
        request.url.toString(),
        'https://my-photos.s3.eu-west-2.amazonaws.com/vault/originals/IMG_1.HEIC',
      );
      expect(
        request.headers['authorization'] ?? request.headers['Authorization'],
        startsWith('AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/'),
      );
    });

    test('200 and 404 also mean gone', () async {
      for (final status in [200, 404]) {
        expect((await delete((_) async => http.Response('', status))).$1, true);
      }
    });

    test('a refusal or an error is never read as gone', () async {
      for (final status in [301, 403, 409, 500, 503]) {
        expect(
          (await delete((_) async => http.Response('', status))).$1,
          false,
          reason: '$status',
        );
      }
      expect(
        (await delete((_) async => throw http.ClientException('offline'))).$1,
        false,
      );
    });
  });
}
