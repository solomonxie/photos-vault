import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../settings/backup_targets_store.dart';
import '../settings/s3_backup_target.dart';
import '../settings/s3_listing.dart';
import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
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

  bool get isClean => reachedBucket && missingLocalIds.isEmpty;
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

  Future<CopyProof> _prove(AssetRecord record, DerivativeKind kind) async {
    final key = record.stateOf(kind).destinationKey;
    if (key == null) return CopyProof.notRecorded;
    final targets = await _targets();
    if (targets.isEmpty) return CopyProof.unreachable;
    var answered = false;
    for (final target in targets) {
      try {
        final response = await _head(
          await presignHeadUrl(target: target, key: key),
        );
        if (response.statusCode == 200) return CopyProof.present;
        // 403 on a bucket without HeadObject permission is not "absent" —
        // only a 404 is the bucket saying it hasn't got it.
        if (response.statusCode == 404) answered = true;
      } catch (_) {
        // Network, DNS, a target that no longer exists — next one.
      }
    }
    return answered ? CopyProof.missing : CopyProof.unreachable;
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

  /// `null` rather than `false` for an optimized upload: `backedUpHash` is
  /// the hash of the file *on the phone*, and an optimized upload re-encoded
  /// it to WebP on the way, so the object is supposed to differ. Reporting
  /// that as a mismatch would fail every drill on the default format.
  static bool? _identical(Uint8List bytes, String? backedUpHash, String key) {
    if (backedUpHash == null) return null;
    if (key.toLowerCase().endsWith('.webp')) return null;
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

  /// Lists every object under each target's `originals/` and compares it
  /// against what this app believes is up there.
  ///
  /// One listing per thousand keys rather than one HEAD per photo: a
  /// library of thirty thousand is thirty requests this way and thirty
  /// thousand the other.
  Future<ReconcileReport> reconcile() async {
    final records = [
      for (final record in await recordStore.listAll())
        if (!record.isDeleted) record,
    ];
    final expected = <String, String>{}; // key -> localId
    // A Live Photo's `.mov` sits beside its still under `originals/`, and a
    // missing one makes the photo missing — the bulk Remove from Device
    // trusts this list.
    final motion = <String, String>{};
    for (final record in records) {
      final key = record.stateOf(DerivativeKind.original).destinationKey;
      if (key != null) expected[key] = record.localId;
      final live = record.isLivePhoto
          ? record.stateOf(DerivativeKind.livePhoto).destinationKey
          : null;
      if (live != null) motion[live] = record.localId;
    }

    final seen = <String>{};
    var reached = false;
    for (final target in await _targets()) {
      final prefix = _originalsPrefix(target);
      String? token;
      do {
        final result = await _list(
          target: target,
          prefix: prefix,
          continuationToken: token,
        );
        if (!result.isOk || result.page == null) break;
        reached = true;
        for (final object in result.page!.objects) {
          if (object.size > 0) seen.add(object.key);
        }
        token = result.page!.nextToken;
      } while (token != null);
    }

    final report = ReconcileReport(
      at: DateTime.now(),
      expected: expected.length,
      present: expected.keys.where(seen.contains).length,
      missingLocalIds: {
        for (final entry in [...expected.entries, ...motion.entries])
          if (!seen.contains(entry.key)) entry.value,
      }.toList(),
      unreferencedKeys: [
        for (final key in seen)
          if (!expected.containsKey(key) && !motion.containsKey(key)) key,
      ],
      reachedBucket: reached,
    );
    if (reached) await _record(report);
    return report;
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

  static String _originalsPrefix(S3BackupTarget target) {
    final prefix = target.prefix;
    final normalized = prefix.isEmpty || prefix.endsWith('/')
        ? prefix
        : '$prefix/';
    return '${normalized}originals/';
  }

  /// Puts every photo [report] found missing back in the upload queue, and
  /// returns how many moved.
  ///
  /// The point of finding out is fixing it. A report that only counted
  /// would leave the user holding a number and no way to act on it, and the
  /// records would go on claiming to be backed up — which is what let the
  /// local copy be deleted in the first place.
  Future<int> requeueMissing(ReconcileReport report) async {
    var requeued = 0;
    for (final localId in report.missingLocalIds) {
      final record = await recordStore.getByLocalId(localId);
      if (record == null) continue;
      var touched = false;
      for (final kind in [
        DerivativeKind.original,
        if (record.isLivePhoto) DerivativeKind.livePhoto,
      ]) {
        final state = record.stateOf(kind);
        if (state.status == UploadStatus.pending) continue;
        await recordStore.updateDerivative(
          localId,
          kind,
          state.copyWith(status: UploadStatus.pending),
        );
        touched = true;
      }
      if (touched) requeued++;
    }
    return requeued;
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
