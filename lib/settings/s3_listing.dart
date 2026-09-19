import 'dart:convert';

import 'package:aws_common/aws_common.dart';
import 'package:aws_signature_v4/aws_signature_v4.dart';
import 'package:http/http.dart' as http;

import 'bucket_endpoint.dart';
import 's3_xml.dart' as sx;
import 's3_backup_target.dart';

/// One object under a listed prefix.
class S3Object {
  const S3Object({
    required this.key,
    required this.size,
    required this.lastModified,
  });

  final String key;
  final int size;
  final DateTime lastModified;
}

/// One "folder" level of a bucket listing — the sub-prefixes immediately
/// under it (S3's `delimiter=/` convention; S3 has no real directories,
/// this is just key-prefix grouping) plus the objects directly in it.
class S3ListingPage {
  const S3ListingPage({
    required this.folders,
    required this.objects,
    this.nextToken,
  });

  final List<String> folders;
  final List<S3Object> objects;

  /// Set when the bucket has more than 1000 keys under this prefix —
  /// pass back into [listBucket]'s `continuationToken` to fetch the rest.
  final String? nextToken;
}

enum S3ListingOutcome { ok, forbidden, notFound, networkError }

class S3ListingResult {
  const S3ListingResult(this.outcome, {this.page, this.detail});

  final S3ListingOutcome outcome;
  final S3ListingPage? page;

  /// The AWS error code (e.g. `AccessDenied`), when available.
  final String? detail;

  bool get isOk => outcome == S3ListingOutcome.ok;
}

/// Lists one folder level of [target]'s bucket under [prefix] — a signed
/// `ListObjectsV2` request with `delimiter=/` so nested keys group into
/// `CommonPrefixes` ("folders") instead of flattening the whole bucket.
Future<S3ListingResult> listBucket({
  required S3BackupTarget target,
  String prefix = '',
  String? continuationToken,
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
  final uri = targetUri(
    target,
    query: {
      'list-type': '2',
      'delimiter': '/',
      if (prefix.isNotEmpty) 'prefix': prefix,
      'continuation-token': ?continuationToken,
    },
  );
  final request = AWSHttpRequest.get(uri);

  try {
    final signed = await signer.sign(
      request,
      credentialScope: scope,
      serviceConfiguration: S3ServiceConfiguration(),
    );
    final response = await http.get(signed.uri, headers: signed.headers);
    // Not `response.body`: S3's XML is always UTF-8 (its `<?xml ... encoding="UTF-8"?>`
    // declaration says so) but the response's Content-Type header omits a
    // `charset` param, so `http`'s own charset-sniffing falls back to
    // latin1 and mangles anything non-ASCII (e.g. Chinese filenames) into
    // garbage. Decode the raw bytes as UTF-8 ourselves instead.
    final body = utf8.decode(response.bodyBytes);
    if (response.statusCode != 200) {
      final outcome = switch (response.statusCode) {
        403 => S3ListingOutcome.forbidden,
        404 => S3ListingOutcome.notFound,
        _ => S3ListingOutcome.networkError,
      };
      return S3ListingResult(
        outcome,
        detail: _errorCodeFrom(body) ?? response.statusCode.toString(),
      );
    }
    return S3ListingResult(S3ListingOutcome.ok, page: _parsePage(body));
  } catch (e) {
    return S3ListingResult(S3ListingOutcome.networkError, detail: e.toString());
  }
}

S3ListingPage _parsePage(String xmlBody) {
  final folders = <String>[];
  for (final block in sx.blocksOf(xmlBody, 'CommonPrefixes')) {
    final prefix = sx.textOf(block, 'Prefix');
    if (prefix != null) folders.add(prefix);
  }

  final objects = <S3Object>[];
  for (final block in sx.blocksOf(xmlBody, 'Contents')) {
    final key = sx.textOf(block, 'Key');
    final size = int.tryParse(sx.textOf(block, 'Size') ?? '');
    final modified = DateTime.tryParse(sx.textOf(block, 'LastModified') ?? '');
    // A row missing any of the three is skipped rather than thrown on: one
    // malformed entry shouldn't cost the user the whole page.
    if (key == null || size == null || modified == null) continue;
    objects.add(S3Object(key: key, size: size, lastModified: modified));
  }

  final isTruncated = sx.textOf(xmlBody, 'IsTruncated') == 'true';
  final nextToken = isTruncated
      ? sx.textOf(xmlBody, 'NextContinuationToken')
      : null;

  return S3ListingPage(
    folders: folders,
    objects: objects,
    nextToken: nextToken,
  );
}

String? _errorCodeFrom(String xmlBody) => sx.textOf(xmlBody, 'Code');
