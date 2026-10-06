import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../photos/image_pipeline.dart';
import '../photos/smaller_export.dart';
import '../settings/backup_targets_store.dart';
import '../settings/s3_backup_target.dart';
import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import '../storage/bucket_object.dart';
import '../vault/carrier.dart' show thumbnailPrefixBytes;
import '../vault/carrier_probe.dart';
import '../vault/keys.dart';
import '../vault/object_key.dart';
import 'bucket_leftovers.dart';
import 'bucket_ops.dart';
import 'capture_date.dart';
import 's3_uploader.dart';
import 'signing.dart';

enum FlagKind {
  /// Not one of ours: the name does not fit the protocol.
  offProtocol,

  /// A thumbnail whose original is gone.
  orphanThumbnail,

  /// Named like ours but no record claims it, and not a hidden carrier:
  /// a photo that came from another device, a reinstall, or a deleted
  /// record. Only found when the caller can tell carriers apart.
  unclaimed,

  /// Not in the library, no capture date of its own, and dated only by a
  /// stamp written when it was uploaded or renamed: most likely an old copy
  /// of a photo already here. Listed, never offered as new.
  likelyLeftover,
}

/// What a header read says about an object: whether it is a hidden photo's
/// carrier, and the camera's own date if the file carries one.
typedef ObjectInspection = ({bool carrier, DateTime? takenAt});

class FlaggedObject {
  const FlaggedObject({
    required this.object,
    required this.kind,
    this.likelyDuplicateOf,
    this.takenAt,
  });

  final BucketObject object;
  final FlagKind kind;

  /// The capture date read from the file's own metadata, when the scan read
  /// its header and found one.
  final DateTime? takenAt;

  /// Key of an already-known original of the same size in the same bucket.
  /// A guess — sizes can collide — so it only keeps the object out of
  /// batch imports and says why; nothing is ever deleted on its strength.
  final String? likelyDuplicateOf;

  bool get isVideo => BucketFlags.videoExtensions.contains(_ext(object.key));

  String get name => object.fileName;
}

String _ext(String key) {
  final name = key.split('/').last;
  return name.contains('.') ? name.split('.').last.toLowerCase() : '';
}

/// What in the bucket this app does not understand. Nothing is skipped
/// quietly: an object is either pointed at by a record, named like ours
/// (so an album may own it), or flagged here.
class BucketFlags {
  BucketFlags({required this.store});

  final AssetRecordStore store;

  static const videoExtensions = {'mp4', 'mov', 'm4v'};
  static const stillExtensions = {
    'jpg',
    'jpeg',
    'png',
    'heic',
    'heif',
    'webp',
    'gif',
  };

  /// [isCarrier] tells a hidden photo's carrier from an ordinary file when
  /// both are named like ours; without it protocol-named objects are left
  /// alone, since an album may own them.
  static const probeConcurrency = 8;

  /// [inspect] reads an object's header once for both questions; without
  /// it, [isCarrier] alone answers the first and no dates are read.
  Future<List<FlaggedObject>> detect({
    Future<bool> Function(BucketObject object)? isCarrier,
    Future<ObjectInspection> Function(BucketObject object)? inspect,
    int probeLimit = 200,
  }) async {
    final look =
        inspect ??
        (isCarrier == null
            ? null
            : (BucketObject o) async =>
                  (carrier: await isCarrier(o), takenAt: null));
    final objects = await store.listBucketObjects();
    final referenced = await store.referencedKeys();
    final ignored = await IgnoredBucketKeys(store).read();
    final originalStems = <String>{
      for (final o in objects)
        if (o.directory == 'originals') '${o.targetId}|${_stem(o.key)}',
    };
    final knownBySize = <String, String>{
      for (final o in objects)
        if (o.directory == 'originals' && referenced.contains(o.key))
          '${o.targetId}|${o.size}': o.key,
    };
    FlaggedObject media(BucketObject o, FlagKind kind, [DateTime? takenAt]) =>
        FlaggedObject(
          object: o,
          kind: kind,
          likelyDuplicateOf: knownBySize['${o.targetId}|${o.size}'],
          takenAt: takenAt,
        );
    final out = <FlaggedObject>[];
    final toProbe = <BucketObject>[];
    for (final o in objects) {
      if (referenced.contains(o.key) || ignored.contains(o.key)) continue;
      final ext = _ext(o.key);
      if (o.directory == 'originals') {
        final isMedia =
            videoExtensions.contains(ext) || stillExtensions.contains(ext);
        if (!isMedia) continue;
        final protocol = fitsProtocol(o.fileName);
        // An off-protocol name needs its header read only when its stamp
        // could be an upload stamp; otherwise the name is evidence enough.
        final suspect = _stampNearArrival(o);
        if (look != null &&
            (protocol || suspect) &&
            toProbe.length < probeLimit) {
          toProbe.add(o);
        } else if (!protocol) {
          out.add(media(o, FlagKind.offProtocol));
        }
      } else if (o.directory == 'thumbnails' &&
          !originalStems.contains('${o.targetId}|${_stem(o.key)}')) {
        out.add(FlaggedObject(object: o, kind: FlagKind.orphanThumbnail));
      }
    }
    // The only per-object requests in a scan, so they go a batch at a time
    // rather than one after another.
    for (var i = 0; i < toProbe.length; i += probeConcurrency) {
      final batch = toProbe.skip(i).take(probeConcurrency).toList();
      final looks = await Future.wait(batch.map(look!));
      for (var j = 0; j < batch.length; j++) {
        final o = batch[j];
        final protocol = fitsProtocol(o.fileName);
        // A carrier is an album's business; an off-protocol one is still
        // offered for the rename that files it.
        if (looks[j].carrier && protocol) continue;
        final takenAt = looks[j].takenAt;
        final leftover =
            !looks[j].carrier &&
            isLikelyLeftover(
              nameStamp: takenAtFromName(o.fileName),
              reference: o.lastModified,
              captureDate: takenAt,
            );
        out.add(
          media(
            o,
            leftover
                ? FlagKind.likelyLeftover
                : protocol
                ? FlagKind.unclaimed
                : FlagKind.offProtocol,
            takenAt,
          ),
        );
      }
    }
    return out;
  }

  static bool _stampNearArrival(BucketObject o) => isLikelyLeftover(
    nameStamp: takenAtFromName(o.fileName),
    reference: o.lastModified,
    captureDate: null,
  );
}

String _stem(String key) => p.basenameWithoutExtension(key);

enum FixOutcome {
  /// Now a record in the library.
  imported,

  /// A carrier of one of this install's passphrases, renamed so its album
  /// finds it. Nothing is shown in the library.
  keptHidden,

  /// Needs an album that is not available (a v1 carrier).
  needsAlbum,
  removed,
  failed,
}

class FixResult {
  const FixResult(this.outcome, {this.localId, this.detail});

  final FixOutcome outcome;
  final String? localId;

  /// Why it failed, in a few words.
  final String? detail;

  bool get ok =>
      outcome != FixOutcome.failed && outcome != FixOutcome.needsAlbum;
}

/// The fixes for a [FlaggedObject]. Each does one job: [rename] changes a
/// name inside the bucket, [reformat] changes the bytes, [removeOrphan]
/// deletes.
class BucketFixer {
  BucketFixer({
    required this.store,
    required this.targetsStore,
    required this.passphrases,
    BucketOps? ops,
    CarrierProbe? probe,
    this._uploader,
    Future<Directory> Function()? temporaryDirectory,
  }) : _ops = ops ?? BucketOps(),
       _probe = probe ?? const CarrierProbe(),
       _temporaryDirectory =
           temporaryDirectory ?? Directory.systemTemp.createTemp;

  final AssetRecordStore store;
  final BackupTargetsStore targetsStore;
  final Future<List<PassphraseEntry>> Function() passphrases;
  final BucketOps _ops;
  final CarrierProbe _probe;
  final S3Uploader? _uploader;
  final Future<Directory> Function() _temporaryDirectory;

  Future<S3BackupTarget?> _target(String id) async {
    for (final t in await targetsStore.loadAll()) {
      if (t.id == id) return t;
    }
    return null;
  }

  Future<ProbedCarrier?> _carrierIn(S3BackupTarget target, FlaggedObject f) =>
      _probe.probe(
        read: _ops.rangeReader(target, f.object.key),
        size: f.object.size,
        isVideo: f.isVideo,
      );

  /// One look at [object]'s header: carrier or not, and its capture date.
  /// The first 64 KB are fetched once and shared by both questions.
  Future<ObjectInspection> inspect(BucketObject object) async {
    final target = await _target(object.targetId);
    if (target == null) return (carrier: true, takenAt: null);
    final read = _headCached(_ops.rangeReader(target, object.key), object.size);
    final isVideo = BucketFlags.videoExtensions.contains(_ext(object.key));
    final carrier =
        await _probe.probe(read: read, size: object.size, isVideo: isVideo) !=
        null;
    return (
      carrier: carrier,
      takenAt: carrier ? null : await _captureDateFrom(read, object, isVideo),
    );
  }

  static Future<DateTime?> _captureDateFrom(
    RangeReader read,
    BucketObject object,
    bool isVideo,
  ) async {
    if (isVideo) return videoCaptureDate(read, object.size);
    final head = await read(0, _headLength(object.size));
    return head == null ? null : stillCaptureDate(head);
  }

  static int _headLength(int size) =>
      size < thumbnailPrefixBytes ? size : thumbnailPrefixBytes;

  /// Serves any read inside the first [thumbnailPrefixBytes] from one fetch.
  static RangeReader _headCached(RangeReader read, int size) {
    final length = _headLength(size);
    Future<Uint8List?>? head;
    return (start, end) async {
      if (end > length) return read(start, end);
      final bytes = await (head ??= read(0, length));
      if (bytes == null) return null;
      final stop = end < bytes.length ? end : bytes.length;
      return start >= stop
          ? Uint8List(0)
          : Uint8List.sublistView(bytes, start, stop);
    };
  }

  /// Whether [object] is a hidden photo's carrier, by its header.
  Future<bool> isCarrier(BucketObject object) async {
    final target = await _target(object.targetId);
    if (target == null) return true;
    return await _probe.probe(
          read: _ops.rangeReader(target, object.key),
          size: object.size,
          isVideo: BucketFlags.videoExtensions.contains(_ext(object.key)),
        ) !=
        null;
  }

  /// An unclaimed object that already has a protocol name: it becomes a
  /// cloud-only record as it is, with nothing moved or renamed.
  Future<FixResult> adopt(FlaggedObject f) async {
    final leftover =
        f.kind == FlagKind.likelyLeftover && fitsProtocol(f.object.fileName);
    if (f.kind != FlagKind.unclaimed && !leftover) {
      return const FixResult(FixOutcome.failed);
    }
    final target = await _target(f.object.targetId);
    if (target == null) {
      return const FixResult(FixOutcome.failed, detail: 'no such bucket');
    }
    final base = _stem(f.object.key);
    final thumb = await _thumbnailOf(f);
    final localId = await _importRecord(
      target: target,
      base: base,
      key: f.object.key,
      thumbnailKey: thumb?.key,
      isVideo: f.isVideo,
      created: await _dateOf(target, f),
    );
    return FixResult(FixOutcome.imported, localId: localId);
  }

  /// Whether the file is known not to be a carrier, which is the only case
  /// where changing its bytes is safe.
  Future<bool> canReformat(FlaggedObject f) async {
    if (f.kind != FlagKind.offProtocol || f.isVideo) return false;
    final ext = _ext(f.object.key);
    if (ext == 'heic' || ext == 'heif' || ext == 'gif') return false;
    final target = await _target(f.object.targetId);
    if (target == null) return false;
    return await _carrierIn(target, f) == null;
  }

  /// Server-side: a copy to a protocol name, a size check, then the old
  /// name goes. No photo data crosses the phone.
  Future<FixResult> rename(FlaggedObject f) async {
    final leftover =
        f.kind == FlagKind.likelyLeftover && !fitsProtocol(f.object.fileName);
    if (f.kind != FlagKind.offProtocol && !leftover) {
      return const FixResult(FixOutcome.failed);
    }
    final target = await _target(f.object.targetId);
    if (target == null) {
      return const FixResult(FixOutcome.failed, detail: 'no such bucket');
    }

    final carrier = await _carrierIn(target, f);
    // Anything that looks like a hidden photo is only ever renamed into the
    // hidden format, and only when the header says it is ours and carries a
    // name. Otherwise it is left alone: an album's index may point at it,
    // and a rename would leave that entry with nothing behind it.
    final hidden =
        carrier != null &&
        carrier.header.isV2 &&
        isKnownSalt(carrier.header, await passphrases());
    if (carrier != null && !hidden) {
      return const FixResult(FixOutcome.needsAlbum);
    }

    final date = await _dateOf(target, f);
    final ext = _ext(f.object.key);
    final base = hidden
        ? hiddenBaseNameFromHeader(date, carrier.header)
        : _ordinaryBase(date, f.object.key);
    final newKey = '${target.prefix}originals/$base.$ext';

    if (!await _copy(target, f.object.key, newKey, f.object.size)) {
      return FixResult(FixOutcome.failed, detail: _ops.lastError);
    }
    if (hidden) {
      await _ops.delete(target, f.object.key);
      return const FixResult(FixOutcome.keptHidden);
    }

    final thumb = await _thumbnailOf(f);
    String? newThumbKey;
    if (thumb != null) {
      final candidate = '${target.prefix}thumbnails/$base.${_ext(thumb.key)}';
      if (await _copy(target, thumb.key, candidate, thumb.size)) {
        newThumbKey = candidate;
      }
    }
    final localId = await _importRecord(
      target: target,
      base: base,
      key: newKey,
      thumbnailKey: newThumbKey,
      isVideo: f.isVideo,
      created: date,
    );
    await _ops.delete(target, f.object.key);
    if (thumb != null && newThumbKey != null) {
      await _ops.delete(target, thumb.key);
    }
    return FixResult(FixOutcome.imported, localId: localId);
  }

  /// Download, convert to HEIF like a backup would, upload under a protocol
  /// name, check it, then drop the old object. Only for files confirmed not
  /// to be carriers - re-encoding one destroys what it holds.
  Future<FixResult> reformat(FlaggedObject f) async {
    final uploader = _uploader;
    if (uploader == null || !await canReformat(f)) {
      return const FixResult(FixOutcome.failed);
    }
    final target = await _target(f.object.targetId);
    if (target == null) return const FixResult(FixOutcome.failed);

    final dir = await _temporaryDirectory();
    try {
      final date = await _dateOf(target, f);
      final base = _ordinaryBase(date, f.object.key);
      final input = File(p.join(dir.path, 'in.${_ext(f.object.key)}'));
      final response = await http.get(
        await presignGetUrl(target: target, key: f.object.key),
      );
      if (response.statusCode != 200) return const FixResult(FixOutcome.failed);
      await input.writeAsBytes(response.bodyBytes, flush: true);

      final output = p.join(dir.path, '$base.heif');
      final wrote = await encodeFileNatively(
        input: input.path,
        output: output,
        format: 'heic',
      );
      // Not smaller means nothing to gain; the file is left as it is.
      if (!wrote) return const FixResult(FixOutcome.failed);
      final newKey = '${target.prefix}originals/$base.heif';
      if (!await uploader.put(filePath: output, key: newKey, target: target)) {
        return const FixResult(FixOutcome.failed);
      }
      if (await _ops.sizeOf(target, newKey) != await File(output).length()) {
        return const FixResult(FixOutcome.failed);
      }

      final thumb = await _thumbnailOf(f);
      String? newThumbKey;
      if (thumb != null) {
        final candidate = '${target.prefix}thumbnails/$base.${_ext(thumb.key)}';
        if (await _copy(target, thumb.key, candidate, thumb.size)) {
          newThumbKey = candidate;
        }
      } else {
        final bytes = await Isolate.run(
          () => encodeThumbnail(response.bodyBytes),
        );
        if (bytes != null) {
          final file = File(p.join(dir.path, '$base.jpg'));
          await file.writeAsBytes(bytes, flush: true);
          final candidate = '${target.prefix}thumbnails/$base.jpg';
          if (await uploader.put(
            filePath: file.path,
            key: candidate,
            target: target,
          )) {
            newThumbKey = candidate;
          }
        }
      }
      final localId = await _importRecord(
        target: target,
        base: base,
        key: newKey,
        thumbnailKey: newThumbKey,
        isVideo: false,
        created: date,
      );
      await _ops.delete(target, f.object.key);
      if (thumb != null) await _ops.delete(target, thumb.key);
      return FixResult(FixOutcome.imported, localId: localId);
    } catch (_) {
      return const FixResult(FixOutcome.failed);
    } finally {
      try {
        await dir.delete(recursive: true);
      } catch (_) {
        // The OS clears temp.
      }
    }
  }

  Future<FixResult> removeOrphan(FlaggedObject f) async {
    final target = await _target(f.object.targetId);
    if (target == null) return const FixResult(FixOutcome.failed);
    return await _ops.delete(target, f.object.key)
        ? const FixResult(FixOutcome.removed)
        : const FixResult(FixOutcome.failed);
  }

  Future<bool> _copy(
    S3BackupTarget target,
    String from,
    String to,
    int size,
  ) async {
    if (await _ops.sizeOf(target, to) == size) return true;
    return _ops.copy(target: target, from: from, to: to, expectedSize: size);
  }

  Future<BucketObject?> _thumbnailOf(FlaggedObject f) async {
    final stem = _stem(f.object.key);
    for (final o in await store.listBucketObjects()) {
      if (o.targetId == f.object.targetId &&
          o.directory == 'thumbnails' &&
          _stem(o.key) == stem) {
        return o;
      }
    }
    return null;
  }

  /// The camera's date from the file itself, then a date in its name, then
  /// when it reached the bucket.
  Future<DateTime> _dateOf(S3BackupTarget target, FlaggedObject f) async =>
      f.takenAt ??
      await _captureDateFrom(
        _headCached(_ops.rangeReader(target, f.object.key), f.object.size),
        f.object,
        f.isVideo,
      ).catchError((_) => null) ??
      takenAtFromName(f.name) ??
      f.object.lastModified.toLocal();

  String _ordinaryBase(DateTime date, String oldKey) {
    final hash = sha256.convert(utf8.encode(oldKey)).bytes;
    final hex = hash
        .take(16)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${objectStamp(date)}_$hex';
  }

  Future<String> _importRecord({
    required S3BackupTarget target,
    required String base,
    required String key,
    required String? thumbnailKey,
    required bool isVideo,
    required DateTime created,
  }) async {
    final localId = 'bucket:$base';
    await store.upsert(
      localId: localId,
      contentHash: localId,
      platform: 'ios',
      sourceType: AssetSourceType.manualFile,
      isVideo: isVideo,
      createdAt: created,
    );
    await store.updateDerivative(
      localId,
      DerivativeKind.original,
      DerivativeState(status: UploadStatus.uploaded, destinationKey: key),
    );
    await store.recordUpload(
      localId: localId,
      kind: DerivativeKind.original,
      targetId: target.id,
      destinationKey: key,
    );
    if (thumbnailKey != null) {
      await store.updateDerivative(
        localId,
        DerivativeKind.thumbnail,
        DerivativeState(
          status: UploadStatus.uploaded,
          destinationKey: thumbnailKey,
        ),
      );
      await store.recordUpload(
        localId: localId,
        kind: DerivativeKind.thumbnail,
        targetId: target.id,
        destinationKey: thumbnailKey,
      );
    }
    await store.setLocalDeleted(localId, true);
    return localId;
  }
}

/// `import_20251228120340_x.mp4` -> 2025-12-28 12:03:40: the first 14-digit
/// run in a name, which is what camera and dashcam exports put there.
DateTime? takenAtFromName(String name) {
  final m = RegExp(r'(\d{14})').firstMatch(name);
  return m == null ? null : parseObjectStamp(m[1]!);
}
