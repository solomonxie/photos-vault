import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../settings/backup_targets_store.dart';
import '../settings/s3_backup_target.dart';
import '../settings/s3_listing.dart';
import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import 'lost_originals.dart';
import 'signing.dart';

/// What a bucket said when asked whether it really has a copy.
enum CopyProof {
  /// A bucket answered 200 for the object.
  present,

  /// A bucket answered, and the object is not there. The only outcome that
  /// means the backup is wrong, and the only one worth blocking on.
  missing,

  /// Nobody answered — offline, expired credentials, no target configured.
  /// Says nothing about the backup either way.
  unreachable,

  /// The record has no key for that derivative, so there is nothing to
  /// ask about. Not a failure: an un-uploaded photo is honestly un-uploaded.
  notRecorded,
}

/// One sampled photo pulled back out of the bucket.
class DrilledPhoto {
  const DrilledPhoto({
    required this.localId,
    required this.downloadedBytes,
    required this.byteIdentical,
  });

  final String localId;

  /// 0 when the download failed.
  final int downloadedBytes;

  /// `true` when the bytes that came back hash to what left the phone,
  /// `false` when they don't, `null` when there is nothing comparable —
  /// an optimized upload was re-encoded on the way up, so the object is
  /// legitimately not the bytes the local hash describes.
  final bool? byteIdentical;

  bool get ok => downloadedBytes > 0 && byteIdentical != false;
}

/// The restore drill: photos chosen at random, fetched in full from the
/// bucket, and checked. What makes "your photos are backed up" a fact
/// rather than a row in this app's own database.
class DrillReport {
  const DrillReport({required this.photos, required this.at});

  final List<DrilledPhoto> photos;
  final DateTime at;

  int get attempted => photos.length;
  int get verified => photos.where((p) => p.ok).length;
  bool get allVerified => attempted > 0 && verified == attempted;
}

/// Bucket contents against this app's beliefs about them.
class ReconcileReport {
  const ReconcileReport({
    required this.at,
    required this.expected,
    required this.present,
    required this.missingLocalIds,
    required this.unreferencedKeys,
    required this.reachedBucket,
    this.missingThumbnailIds = const [],
    this.losses = const {},
  });

  final DateTime at;

  /// Records this app believes have an original in the bucket.
  final int expected;

  /// How many of those the bucket actually listed.
  final int present;

  /// The ones it didn't — believed backed up, not there. The number that
  /// matters, and the one no amount of copy can substitute for.
  final List<String> missingLocalIds;

  /// Objects under the prefix that no record claims. Orphans from a
  /// reinstall, another device, or a deleted record; never deleted by this
  /// app, only reported, because they may be somebody's only copy.
  final List<String> unreferencedKeys;

  /// False when no bucket answered, in which case every other number here
  /// is meaningless and must not be shown as a result.
  final bool reachedBucket;

  /// Photos whose `thumbnails/` object is missing from a bucket that
  /// should hold it. Not a lost photo, but a cloud-only tile with no
  /// cached picture is blank without it.
  final List<String> missingThumbnailIds;

  /// What is missing where, per photo — what [BackupVerifier.repair] acts on.
  final Map<String, RecordLoss> losses;

  bool get isClean =>
      reachedBucket && missingLocalIds.isEmpty && missingThumbnailIds.isEmpty;
}

/// Which buckets lack one photo's derivatives. Judged per bucket: a photo
/// present in A and gone from B is still a loss, and still repairable.
class RecordLoss {
  RecordLoss();

  /// Kind → targets that should hold it and don't.
  final Map<DerivativeKind, Set<String>> missingAt = {};

  /// Kinds no bucket holds any more.
  final Set<DerivativeKind> goneEverywhere = {};
}

/// What [BackupVerifier.repair] did with a [ReconcileReport].
class RepairResult {
  const RepairResult({
    this.requeued = 0,
    this.lost = 0,
    this.thumbnailsRequeued = 0,
  });

  /// Missing, with a local copy to upload again.
  final int requeued;

  /// Gone from every bucket with nothing on this phone to upload again.
  final int lost;
  final int thumbnailsRequeued;
}

/// One round of [BackupVerifier.spotCheck].
class SpotCheckResult {
  const SpotCheckResult({this.checked = 0, this.lost = 0});

  final int checked;
  final int lost;
}

/// Asks the bucket, instead of asking the database.
///
/// Everything else in this app treats [AssetRecord.isFullyBackedUp] — a
/// local row, written by the upload that reported success — as proof a
/// copy exists elsewhere, and then deletes local originals on the strength
/// of it. A wrong prefix, a lifecycle rule, a bucket emptied in a console,
/// or one upload that reported success it didn't have, and that row is a
/// lie which costs the user the photo.
///
/// So: one round trip before anything irreversible ([proveOriginal]), a
/// sampled end-to-end rehearsal for the reassurance ([testRestore]), and a
/// full pass for the answer to "is all of it there" ([reconcile]).
///
/// [CopyProof.unreachable] is deliberately not [CopyProof.missing].
/// Refusing to free space because the phone is on a train is correct;
/// telling the user their backup is gone because of it is not.
class BackupVerifier {
  BackupVerifier({
    required this.targetsStore,
    required this.recordStore,
    Future<http.Response> Function(Uri url)? head,
    Future<http.Response> Function(Uri url)? get,
    Future<S3ListingResult> Function({
      required S3BackupTarget target,
      String prefix,
      String? continuationToken,
    })?
    list,
  }) : _head = head ?? http.head,
       _get = get ?? http.get,
       _list =
           list ??
           (({required target, prefix = '', continuationToken}) => listBucket(
             target: target,
             prefix: prefix,
             continuationToken: continuationToken,
           ));

  final BackupTargetsStore targetsStore;
  final AssetRecordStore recordStore;

  final Future<http.Response> Function(Uri url) _head;
  final Future<http.Response> Function(Uri url) _get;
  final Future<S3ListingResult> Function({
    required S3BackupTarget target,
    String prefix,
    String? continuationToken,
  })
  _list;

  /// When a real bucket last confirmed something, and what it said. Kept
  /// in the database beside the records it describes, not the keychain —
  /// a verification that outlived its library would be worse than none.
  static const verifiedAtKey = 'backup_verified_at';
  static const verifiedSummaryKey = 'backup_verified_summary';

  /// How many photos a drill pulls back. Three is enough to catch a whole
  /// destination being wrong, which is the failure this is for, and small
  /// enough to run on cellular without asking.
  static const drillSample = 3;

  Future<DateTime?> lastVerifiedAt() async {
    final raw = await recordStore.getAppState(verifiedAtKey);
    return raw == null ? null : DateTime.tryParse(raw);
  }

  /// The one line the Safety screen shows: what the last check found,
  /// in the words the check itself chose.
  Future<String?> lastVerifiedSummary() =>
      recordStore.getAppState(verifiedSummaryKey);

  // ------------------------------------------------------------ one object

  /// Whether some bucket really holds [record]'s full-resolution copy —
  /// both halves of a Live Photo, since a Live Photo backed up as a still
  /// alone is a silent still.
  ///
  /// Asked of every target in turn and satisfied by the first `200`: the
  /// copy only has to exist once to be a copy.
  Future<CopyProof> proveOriginal(AssetRecord record) async {
    final proof = await _prove(record, DerivativeKind.original);
    if (proof != CopyProof.present || !record.isLivePhoto) return proof;
    final motion = await _prove(record, DerivativeKind.livePhoto);
    // A missing motion half is a missing copy of *this* photo; an
    // unrecorded one is an ordinary still that was never a Live Photo in
    // the bucket to begin with.
    return motion == CopyProof.notRecorded ? proof : motion;
  }

  /// Whether some bucket holds [record]'s `thumbnails/` object — what a
  /// cloud-only photo is drawn from once its original has left the phone.
  Future<CopyProof> proveThumbnail(AssetRecord record) =>
      _prove(record, DerivativeKind.thumbnail);

  Future<CopyProof> _prove(AssetRecord record, DerivativeKind kind) async {
    final key = record.stateOf(kind).destinationKey;
    if (key == null) return CopyProof.notRecorded;
    final targets = await _targets();
    if (targets.isEmpty) return CopyProof.unreachable;
    var answered = false;
    for (final target in targets) {
      switch (await _proveAt(target, key)) {
        case CopyProof.present:
          return CopyProof.present;
        case CopyProof.missing:
          answered = true;
        case _:
      }
    }
    return answered ? CopyProof.missing : CopyProof.unreachable;
  }

  Future<CopyProof> _proveAt(S3BackupTarget target, String key) async {
    try {
      final response = await _head(
        await presignHeadUrl(target: target, key: key),
      );
      if (response.statusCode == 200) return CopyProof.present;
      // 403 on a bucket without HeadObject permission is not "absent" —
      // only a 404 is the bucket saying it hasn't got it.
      if (response.statusCode == 404) return CopyProof.missing;
    } catch (_) {
      // Network, DNS, a target that no longer exists.
    }
    return CopyProof.unreachable;
  }

  /// [kind] of [record] against each bucket that holds it, on its own: the
  /// answer per bucket rather than "somewhere". A row with no per-bucket
  /// record (written before the table existed) is asked of every bucket.
  Future<Map<String, CopyProof>> _proveEach(
    AssetRecord record,
    DerivativeKind kind,
  ) async {
    final fallback = record.stateOf(kind).destinationKey;
    if (fallback == null) return const {};
    final targets = await _targets();
    final held = await recordStore.targetsHolding(record.localId, kind);
    if (held.isEmpty || held.keys.every((id) => id.isEmpty)) {
      return {
        for (final target in targets)
          target.id: await _proveAt(target, fallback),
      };
    }
    return {
      for (final target in targets)
        if (held[target.id] != null)
          target.id: await _proveAt(target, held[target.id]!),
    };
  }

  // ---------------------------------------------------------------- drill

  /// Downloads [sample] backed-up photos chosen at random and checks what
  /// comes back. Spread across the library rather than taken from one end:
  /// the failure worth catching is a whole stretch of it going missing.
  Future<DrillReport> testRestore({int sample = drillSample}) async {
    final candidates = [
      for (final record in await recordStore.listAll())
        if (record.stateOf(DerivativeKind.original).destinationKey != null &&
            !record.isDeleted &&
            record.passcodeHash == null)
          record,
    ];
    final picked = _spread(candidates, sample);
    final drilled = <DrilledPhoto>[];
    for (final record in picked) {
      drilled.add(await _drill(record));
    }
    final report = DrillReport(photos: drilled, at: DateTime.now());
    if (report.attempted > 0) await _record(report);
    return report;
  }

  Future<DrilledPhoto> _drill(AssetRecord record) async {
    final state = record.stateOf(DerivativeKind.original);
    final key = state.destinationKey!;
    for (final target in await _targets()) {
      try {
        final response = await _get(
          await presignGetUrl(target: target, key: key),
        );
        if (response.statusCode != 200) continue;
        final bytes = response.bodyBytes;
        return DrilledPhoto(
          localId: record.localId,
          downloadedBytes: bytes.length,
          byteIdentical: _identical(bytes, state.backedUpHash, key),
        );
      } catch (_) {
        // Next target.
      }
    }
    return DrilledPhoto(
      localId: record.localId,
      downloadedBytes: 0,
      byteIdentical: null,
    );
  }

  /// `null` rather than `false` for a re-encoded upload: `backedUpHash` is
  /// the hash of the file *on the phone*, and the HEIF format (or WebP, from
  /// older builds) re-encodes a JPEG or PNG on the way, so the object is
  /// supposed to differ. Reporting that as a mismatch would fail every
  /// drill on the default format. Converted uploads are `.heif`; a HEIC
  /// sent as it was keeps `.heic` and must match.
  static bool? _identical(Uint8List bytes, String? backedUpHash, String key) {
    if (backedUpHash == null) return null;
    final lower = key.toLowerCase();
    if (lower.endsWith('.webp') || lower.endsWith('.heif')) return null;
    return sha256.convert(bytes).toString() == backedUpHash;
  }

  /// [count] records taken at even intervals across [all], so a sample of
  /// three covers the oldest, the middle and the newest rather than three
  /// photos taken the same afternoon.
  static List<AssetRecord> _spread(List<AssetRecord> all, int count) {
    if (all.isEmpty || count <= 0) return const [];
    if (all.length <= count) return all;
    final step = all.length / count;
    return [for (var i = 0; i < count; i++) all[(i * step).floor()]];
  }

  // ------------------------------------------------------------ reconcile

  /// Lists every object under each target's `originals/` and `thumbnails/`
  /// and compares it, bucket by bucket, against what this app believes is
  /// up there.
  ///
  /// One listing per thousand keys rather than one HEAD per photo: a
  /// library of thirty thousand is thirty requests this way and thirty
  /// thousand the other. Per bucket, not the union: a photo in A and gone
  /// from B is not backed up twice.
  Future<ReconcileReport> reconcile() async {
    final records = [
      for (final record in await recordStore.listAll())
        if (!record.isDeleted) record,
    ];
    final holdings = await recordStore.allHoldings();

    final originals = <String, Set<String>>{};
    final thumbnails = <String, Set<String>>{};
    for (final target in await _targets()) {
      final o = await _listKeys(target, _originalsPrefix(target));
      final t = await _listKeys(
        target,
        _derivativePrefix(target, 'thumbnails'),
      );
      if (o != null) originals[target.id] = o;
      if (t != null) thumbnails[target.id] = t;
    }
    final reached = originals.isNotEmpty;

    final known = <String>{};
    final losses = <String, RecordLoss>{};
    var expected = 0;
    var present = 0;
    for (final record in records) {
      var expectsOriginal = false;
      var originalMissing = false;
      for (final kind in [
        DerivativeKind.original,
        if (record.isLivePhoto) DerivativeKind.livePhoto,
        DerivativeKind.thumbnail,
      ]) {
        final state = record.stateOf(kind);
        final key = state.destinationKey;
        if (key == null) continue;
        final isThumb = kind == DerivativeKind.thumbnail;
        if (isThumb && state.status != UploadStatus.uploaded) continue;
        final seen = isThumb ? thumbnails : originals;
        final held = holdings[record.localId]?[kind] ?? const {};
        known.addAll(held.values);
        known.add(key);
        if (kind == DerivativeKind.original) expectsOriginal = true;

        final checked = <String>[];
        final missing = <String>{};
        if (held.isEmpty || held.keys.every((id) => id.isEmpty)) {
          if (seen.isEmpty) continue;
          if (!seen.values.any((keys) => keys.contains(key))) {
            missing.addAll(seen.keys);
          }
          checked.addAll(seen.keys);
        } else {
          for (final entry in held.entries) {
            final keys = seen[entry.key];
            if (keys == null) continue;
            checked.add(entry.key);
            if (!keys.contains(entry.value)) missing.add(entry.key);
          }
        }
        if (missing.isEmpty) continue;
        final loss = losses.putIfAbsent(record.localId, RecordLoss.new);
        loss.missingAt[kind] = missing;
        // Gone everywhere only when every holder answered and none has it.
        final holders = held.isEmpty || held.keys.every((id) => id.isEmpty)
            ? seen.length
            : held.keys.where(seen.containsKey).length;
        if (missing.length == checked.length && checked.length == holders) {
          loss.goneEverywhere.add(kind);
        }
        if (kind == DerivativeKind.original) originalMissing = true;
      }
      if (expectsOriginal) {
        expected++;
        if (!originalMissing) present++;
      }
    }

    final seenOriginals = {for (final keys in originals.values) ...keys};
    bool lost(RecordLoss l, Set<DerivativeKind> kinds) =>
        kinds.any((k) => (l.missingAt[k] ?? const {}).isNotEmpty);
    final report = ReconcileReport(
      at: DateTime.now(),
      expected: expected,
      present: present,
      missingLocalIds: [
        for (final e in losses.entries)
          if (lost(e.value, {
            DerivativeKind.original,
            DerivativeKind.livePhoto,
          }))
            e.key,
      ],
      missingThumbnailIds: [
        for (final e in losses.entries)
          if (lost(e.value, {DerivativeKind.thumbnail})) e.key,
      ],
      losses: losses,
      unreferencedKeys: [
        for (final key in seenOriginals)
          if (!known.contains(key)) key,
      ],
      reachedBucket: reached,
    );
    if (reached) await _record(report);
    return report;
  }

  /// Every non-empty key under [prefix] in [target], or null when the
  /// bucket didn't answer — a bucket that wasn't reached has no opinion.
  Future<Set<String>?> _listKeys(S3BackupTarget target, String prefix) async {
    final keys = <String>{};
    String? token;
    var reached = false;
    do {
      final result = await _list(
        target: target,
        prefix: prefix,
        continuationToken: token,
      );
      if (!result.isOk || result.page == null) break;
      reached = true;
      for (final object in result.page!.objects) {
        if (object.size > 0) keys.add(object.key);
      }
      token = result.page!.nextToken;
    } while (token != null);
    return reached && token == null ? keys : null;
  }

  /// Empty rather than throwing when the keychain can't be read — no
  /// target is [CopyProof.unreachable], which is the honest answer and the
  /// safe one. A verifier that throws would take the delete path down with
  /// it, and a caller catching that would be catching it as permission.
  Future<List<S3BackupTarget>> _targets() async {
    try {
      return await targetsStore.loadAll();
    } catch (_) {
      return const [];
    }
  }

  static String _originalsPrefix(S3BackupTarget target) =>
      _derivativePrefix(target, 'originals');

  static String _derivativePrefix(S3BackupTarget target, String folder) {
    final prefix = target.prefix;
    final normalized = prefix.isEmpty || prefix.endsWith('/')
        ? prefix
        : '$prefix/';
    return '$normalized$folder/';
  }

  /// Acts on what [report] found, and says honestly what it could not fix.
  ///
  /// With a local copy, a missing derivative goes back in the upload queue
  /// (for the buckets that lack it only). With none and no bucket holding
  /// it, nothing can ever re-upload it: the photo is **lost**, its original
  /// is marked failed so the grid draws it that way, and it is counted as
  /// lost, never as requeued.
  Future<RepairResult> repair(ReconcileReport report) async {
    final lostIds = LostOriginals(recordStore);
    var requeued = 0;
    var lost = 0;
    var thumbnails = 0;
    for (final entry in report.losses.entries) {
      final record = await recordStore.getByLocalId(entry.key);
      if (record == null) continue;
      final hasLocal = !record.localDeleted;
      var requeuedThis = false;
      var lostThis = false;
      for (final kind in [
        DerivativeKind.original,
        if (record.isLivePhoto) DerivativeKind.livePhoto,
      ]) {
        final missing = entry.value.missingAt[kind];
        if (missing == null || missing.isEmpty) continue;
        final state = record.stateOf(kind);
        if (hasLocal) {
          await _forget(record.localId, kind, missing);
          if (state.status != UploadStatus.pending) {
            await recordStore.updateDerivative(
              record.localId,
              kind,
              state.copyWith(status: UploadStatus.pending),
            );
          }
          requeuedThis = true;
        } else if (entry.value.goneEverywhere.contains(kind)) {
          await recordStore.updateDerivative(
            record.localId,
            kind,
            state.copyWith(status: UploadStatus.failed),
          );
          lostThis = true;
        }
      }
      final thumbMissing = entry.value.missingAt[DerivativeKind.thumbnail];
      if (thumbMissing != null &&
          thumbMissing.isNotEmpty &&
          (hasLocal || record.thumbnailPath != null)) {
        await _forget(record.localId, DerivativeKind.thumbnail, thumbMissing);
        await recordStore.updateDerivative(
          record.localId,
          DerivativeKind.thumbnail,
          record
              .stateOf(DerivativeKind.thumbnail)
              .copyWith(status: UploadStatus.pending),
        );
        thumbnails++;
      }
      if (lostThis) {
        await lostIds.add(record.localId);
        lost++;
      } else if (requeuedThis) {
        requeued++;
      }
    }
    return RepairResult(
      requeued: requeued,
      lost: lost,
      thumbnailsRequeued: thumbnails,
    );
  }

  Future<int> requeueMissing(ReconcileReport report) async =>
      (await repair(report)).requeued;

  Future<void> _forget(String localId, DerivativeKind kind, Set<String> ids) =>
      Future.wait([
        for (final id in ids) recordStore.forgetTargetUpload(localId, kind, id),
      ]);

  // ------------------------------------------------------------ spot check

  static const spotCheckRanAtKey = 'spot_check_ran_at';
  static const _spotCheckedKey = 'spot_checked_at';

  /// A few cloud-only photos asked of the bucket, oldest-checked first —
  /// the bucket can lose an object any day, and a cloud-only photo is the
  /// one place nothing else would notice. Run on every sync; throttled to
  /// once per [every], and bounded to [limit] photos whatever the library.
  ///
  /// Photos queued by [ProofQueue] (an OS-side delete called them cloud-only
  /// on the row's word) go first.
  Future<SpotCheckResult> spotCheck({
    int limit = 4,
    Duration every = const Duration(minutes: 10),
  }) async {
    final now = DateTime.now();
    final ranAt = DateTime.tryParse(
      await recordStore.getAppState(spotCheckRanAtKey) ?? '',
    );
    if (ranAt != null && now.difference(ranAt) < every) {
      return const SpotCheckResult();
    }
    await recordStore.setAppState(spotCheckRanAtKey, now.toIso8601String());

    final checkedAt = await _spotCheckedAt();
    final records = await recordStore.listAll();
    final byId = {for (final r in records) r.localId: r};
    final queue = ProofQueue(recordStore);
    final picked = <AssetRecord>[
      for (final id in await queue.take(limit))
        if (byId[id] != null) byId[id]!,
    ];
    final candidates =
        [
          for (final r in records)
            if (r.localDeleted &&
                !r.isDeleted &&
                r.passcodeHash == null &&
                r.isFullyBackedUp &&
                !picked.any((p) => p.localId == r.localId))
              r,
        ]..sort(
          (a, b) =>
              (checkedAt[a.localId] ?? 0).compareTo(checkedAt[b.localId] ?? 0),
        );
    picked.addAll(candidates.take(limit - picked.length));

    final lostIds = LostOriginals(recordStore);
    var checked = 0;
    var lost = 0;
    for (final record in picked) {
      var answered = true;
      var gone = false;
      for (final kind in [
        DerivativeKind.original,
        if (record.isLivePhoto) DerivativeKind.livePhoto,
      ]) {
        final proofs = await _proveEach(record, kind);
        if (proofs.isEmpty) continue;
        if (proofs.values.contains(CopyProof.unreachable)) answered = false;
        final everyMissing = proofs.values.every((p) => p == CopyProof.missing);
        if (everyMissing) {
          gone = true;
          await recordStore.updateDerivative(
            record.localId,
            kind,
            record.stateOf(kind).copyWith(status: UploadStatus.failed),
          );
        }
      }
      if (gone) {
        await lostIds.add(record.localId);
        lost++;
      }
      if (answered) {
        checkedAt[record.localId] = now.millisecondsSinceEpoch;
        checked++;
      }
      await _spotCheckThumbnail(record);
    }
    await recordStore.setAppState(
      _spotCheckedKey,
      jsonEncode({
        for (final e in checkedAt.entries)
          if (byId.containsKey(e.key)) e.key: e.value,
      }),
    );
    return SpotCheckResult(checked: checked, lost: lost);
  }

  /// A thumbnail gone from every bucket is put back from the cached picture
  /// while this phone still has one.
  Future<void> _spotCheckThumbnail(AssetRecord record) async {
    final state = record.stateOf(DerivativeKind.thumbnail);
    if (state.status != UploadStatus.uploaded || record.thumbnailPath == null) {
      return;
    }
    final proofs = await _proveEach(record, DerivativeKind.thumbnail);
    if (proofs.isEmpty || !proofs.values.every((p) => p == CopyProof.missing)) {
      return;
    }
    await recordStore.updateDerivative(
      record.localId,
      DerivativeKind.thumbnail,
      state.copyWith(status: UploadStatus.pending),
    );
    for (final id in proofs.keys) {
      await recordStore.forgetTargetUpload(
        record.localId,
        DerivativeKind.thumbnail,
        id,
      );
    }
  }

  Future<Map<String, int>> _spotCheckedAt() async {
    final raw = await recordStore.getAppState(_spotCheckedKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      return (jsonDecode(raw) as Map).cast<String, int>();
    } catch (_) {
      return {};
    }
  }

  // --------------------------------------------------------------- marking

  Future<void> _record(Object report) async {
    final (at, summary) = switch (report) {
      ReconcileReport r => (r.at, 'reconcile:${r.present}/${r.expected}'),
      DrillReport d => (d.at, 'drill:${d.verified}/${d.attempted}'),
      _ => (DateTime.now(), ''),
    };
    await recordStore.setAppState(verifiedAtKey, at.toIso8601String());
    await recordStore.setAppState(verifiedSummaryKey, summary);
  }
}
