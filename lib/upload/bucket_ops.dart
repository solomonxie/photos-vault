import 'package:aws_common/aws_common.dart';
import 'package:aws_signature_v4/aws_signature_v4.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../settings/bucket_endpoint.dart';
import '../settings/s3_backup_target.dart';
import '../settings/s3_listing.dart';
import '../storage/asset_record_store.dart';
import '../vault/carrier_probe.dart';
import 'bucket_http.dart';
import 's3_object_delete.dart';
import 'signing.dart';

/// The few things done to a bucket that are not an upload: list a folder
/// flat, read a byte range, copy within it, check an object is there, and
/// the one guarded delete. None moves a photo through the phone - a copy
/// is the bucket's own.
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

  /// A server-side copy of a large video takes a while on the bucket's end.
  static const _copyTimeout = Duration(minutes: 3);

  RangeReader rangeReader(S3BackupTarget target, String key) =>
      (start, end) async {
        if (end <= start) return Uint8List(0);
        try {
          final response = await bucketRequest(
            (_client?.get ?? http.get)(
              await presignGetUrl(target: target, key: key),
              headers: {'Range': 'bytes=$start-${end - 1}'},
            ),
          );
          if (response.statusCode != 206 && response.statusCode != 200) {
            return null;
          }
          return response.bodyBytes;
        } catch (_) {
          return null;
        }
      };

  /// One HEAD: there with its size and ETag, not there (404 only), or
  /// unknown (anything else: offline, 403, a timeout).
  Future<ObjectHead> head(S3BackupTarget target, String key) async {
    try {
      final response = await bucketRequest(
        (_client?.head ?? http.head)(
          await presignHeadUrl(target: target, key: key),
        ),
      );
      if (response.statusCode == 404) return ObjectHead.absent;
      if (response.statusCode != 200) return ObjectHead.unknown;
      return ObjectHead(
        Probe.present,
        size: int.tryParse(response.headers['content-length'] ?? ''),
        etag: response.headers['etag']?.replaceAll('"', ''),
      );
    } catch (_) {
      return ObjectHead.unknown;
    }
  }

  /// The object's ETag — its MD5 for a single-part upload — or null when it
  /// can't be had. Two objects with the same size and ETag are the same
  /// bytes.
  Future<String?> etagOf(S3BackupTarget target, String key) async =>
      (await head(target, key)).etag;

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
      final response = await bucketRequest(
        client.put(signed.uri, headers: signed.headers),
        timeout: _copyTimeout,
      );
      if (response.statusCode != 200 || response.body.contains('<Error>')) {
        final code = RegExp(r'<Code>([^<]+)</Code>').firstMatch(response.body);
        lastError = 'copy ${response.statusCode} ${code?[1] ?? ''}'.trim();
        return false;
      }
      final landed = (await head(target, to)).size;
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

  /// Whether [key] is a hidden photo's carrier, by its header. Unknown when
  /// any read failed: an unread header is never "not a carrier".
  Future<Probe> carrierAt(
    S3BackupTarget target,
    String key,
    int size, {
    CarrierProbe probe = const CarrierProbe(),
  }) async {
    final read = rangeReader(target, key);
    var failed = false;
    try {
      final found = await probe.probe(
        read: (start, end) async {
          final bytes = await read(start, end);
          if (bytes == null) failed = true;
          return bytes;
        },
        size: size,
        isVideo: isVideoKey(key),
      );
      if (failed) return Probe.unknown;
      return found == null ? Probe.absent : Probe.present;
    } catch (_) {
      return Probe.unknown;
    }
  }

  /// The one way an object leaves a bucket. Refused, never guessed:
  ///
  /// - any record (any kind, any bucket) still names [key];
  /// - the object is a carrier, unless [carrierProof] (the vault, which has
  ///   moved or retired it);
  /// - [keep] is not proven live as asked;
  /// - any check could not be answered.
  ///
  /// [dryRun] runs the checks and stops short of the DELETE
  /// ([DeleteOutcome.allowed]).
  Future<DeleteOutcome> deleteGuarded(
    S3BackupTarget target,
    String key, {
    required AssetRecordStore store,
    Keeper? keep,
    bool carrierProof = false,
    bool dryRun = false,
  }) async {
    if (keep != null && keep.key == key) return DeleteOutcome.keeperUnproven;
    try {
      if (await store.keyHeldByOthers(key, null)) return DeleteOutcome.held;
    } catch (_) {
      return DeleteOutcome.unknown;
    }
    final doomed = await head(target, key);
    switch (doomed.state) {
      case Probe.absent:
        await store.forgetBucketObject(target.id, key);
        return DeleteOutcome.gone;
      case Probe.unknown:
        return DeleteOutcome.unknown;
      case Probe.present:
    }
    final size = doomed.size;
    if (size == null) return DeleteOutcome.unknown;
    if (!carrierProof) {
      switch (await carrierAt(target, key, size)) {
        case Probe.present:
          return DeleteOutcome.carrier;
        case Probe.unknown:
          return DeleteOutcome.unknown;
        case Probe.absent:
      }
    }
    if (keep != null) {
      final kept = await head(target, keep.key);
      if (kept.state == Probe.unknown) return DeleteOutcome.unknown;
      if (!keep.provenBy(kept, doomed)) return DeleteOutcome.keeperUnproven;
    }
    if (dryRun) return DeleteOutcome.allowed;
    if (!await rawDelete(target, key)) return DeleteOutcome.failed;
    await store.forgetBucketObject(target.id, key);
    return DeleteOutcome.deleted;
  }

  /// The DELETE itself. Only [deleteGuarded] calls it.
  @protected
  @visibleForOverriding
  Future<bool> rawDelete(S3BackupTarget target, String key) =>
      deleteObject(target: target, key: key, client: _client);
}

bool isVideoKey(String key) {
  final name = key.split('/').last;
  final dot = name.lastIndexOf('.');
  if (dot == -1) return false;
  return const {
    'mp4',
    'mov',
    'm4v',
  }.contains(name.substring(dot + 1).toLowerCase());
}

/// What a bucket answered: yes, no, or nothing that can be relied on.
/// Unknown never deletes, overwrites, renames or imports.
enum Probe { present, absent, unknown }

class ObjectHead {
  const ObjectHead(this.state, {this.size, this.etag});

  static const absent = ObjectHead(Probe.absent);
  static const unknown = ObjectHead(Probe.unknown);

  final Probe state;
  final int? size;
  final String? etag;

  bool get isPresent => state == Probe.present;
}

/// The copy that stays when another goes, and what it must prove live.
class Keeper {
  const Keeper(
    this.key, {
    this.size,
    this.sameBytes = false,
    this.notSmaller = false,
  });

  final String key;

  /// The size it must have (a copy just made, a file just sent).
  final int? size;

  /// Same size and ETag as the one deleted.
  final bool sameBytes;

  /// At least as large as the one deleted, or the same bytes: a smaller
  /// keeper may be a lossy copy of it.
  final bool notSmaller;

  bool provenBy(ObjectHead kept, ObjectHead doomed) {
    if (!kept.isPresent || kept.size == null) return false;
    if (size != null && kept.size != size) return false;
    final same =
        kept.size == doomed.size &&
        kept.etag != null &&
        kept.etag == doomed.etag;
    if (sameBytes && !same) return false;
    if (notSmaller && !same && kept.size! < (doomed.size ?? 0)) return false;
    return true;
  }
}

enum DeleteOutcome {
  deleted,

  /// Not there to begin with (404).
  gone,

  /// A [BucketOps.deleteGuarded] dry run found nothing against it.
  allowed,

  /// A record still names the key.
  held,

  /// A hidden photo's carrier.
  carrier,

  /// The copy kept in its place is missing or not what it should be.
  keeperUnproven,

  /// A check went unanswered.
  unknown,

  /// The DELETE itself failed.
  failed;

  bool get isGone => this == deleted || this == gone;
}
