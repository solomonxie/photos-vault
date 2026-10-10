import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:photo_manager/photo_manager.dart';

import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import 'photo_library_service.dart';

/// What's costing space on one asset. An asset can carry several — a 40 MB
/// 6000-px PNG carries three.
///
/// "Not backed up" is deliberately not one of them: it's a backup problem,
/// answered by the sync queue, and a page about reclaiming space that
/// listed every un-uploaded photo would be a second, worse copy of it. It
/// only shows up here as [StorageFix.backUpFirst] — the gate in front of a
/// real fix, on a photo that has a real problem.
enum StorageIssue {
  onDevice,
  largeFile,
  highResolution,
  optimizableFormat,

  /// The same file, byte for byte, as another photo in the library.
  duplicate,
}

/// What can be done about an asset — several at once, gentlest first. Only
/// ever something this app can actually do.
enum StorageFix {
  backUpFirst,
  optimize,

  /// The bucket's copy only: a smaller one takes its place there, and the
  /// phone keeps its own.
  optimizeRemote,
  removeFromDevice,
  removeDuplicate,
}

/// Past this, a single file is worth calling out whatever else is true
/// about it. Two numbers because one would be wrong for both: 10 MB is a
/// fat photo and an unremarkable video.
const largePhotoBytes = 10 * 1024 * 1024;
const largeVideoBytes = 100 * 1024 * 1024;

int largeFileThreshold({required bool isVideo}) =>
    isVideo ? largeVideoBytes : largePhotoBytes;

/// Past an ordinary iPhone photo (12 MP is 4032 px): 24 and 48 MP shots,
/// panoramas, scans. Flagging every normal photo as a problem made the
/// count meaningless.
const highResolutionEdge = 4100;

/// What [StorageFix.optimize] makes of a video: 1080p HEVC.
const compressedVideoEdge = 1920;

/// What [StorageFix.optimize] shrinks a photo to — still sharp full-screen
/// on a 3x display, a fraction of the bytes.
const optimizedMaxEdge = 2560;

/// Formats that re-encode dramatically smaller. HEIC and JPEG are left out
/// on purpose: they're already compressed, and converting them buys little
/// for the quality it costs.
const _optimizableFormats = {'.png', '.bmp', '.tif', '.tiff'};

/// One asset with something to fix about it.
class StorageItem {
  StorageItem({
    required this.record,
    required this.bytes,
    required this.name,
    required this.appOwned,
    required this.issues,
    required this.fixes,
    StorageFix? fix,
    this.duplicateOf,
  }) : fix = fix ?? fixes.first;

  /// For a [StorageIssue.duplicate]: the name of the copy that is kept.
  final String? duplicateOf;

  final AssetRecord record;

  /// Size of the local copy. For a camera-roll asset that's PhotoKit's own
  /// figure for the current resource — metadata, never a download.
  final int bytes;

  final String name;

  /// See [AssetMeasure.appOwned]. Carried so a cached scan can be re-read
  /// against a changed record without measuring the file again.
  final bool appOwned;

  final Set<StorageIssue> issues;

  /// Every fix on offer, gentlest first.
  final List<StorageFix> fixes;

  /// The one a run carries out — the first unless one was picked.
  final StorageFix fix;

  StorageItem withFix(StorageFix chosen) => StorageItem(
    record: record,
    bytes: bytes,
    name: name,
    appOwned: appOwned,
    issues: issues,
    fixes: fixes,
    fix: chosen,
    duplicateOf: duplicateOf,
  );

  /// Exact for a removal, a guess for the two re-encodes — nothing knows
  /// what the encoder will produce until it has run. Every total built on
  /// this is shown as "about".
  int get estimatedSaving => switch (fix) {
    StorageFix.backUpFirst => 0,
    StorageFix.removeFromDevice || StorageFix.removeDuplicate => bytes,
    StorageFix.optimize || StorageFix.optimizeRemote =>
      record.isVideo ? (bytes * 0.6).round() : _resizedSaving,
  };

  int get _resizedSaving {
    final edge = longestEdgeOf(record);
    if (edge == null || edge <= optimizedMaxEdge) return (bytes * 0.5).round();
    final ratio = optimizedMaxEdge / edge;
    return (bytes * (1 - ratio * ratio)).round();
  }
}

int? longestEdgeOf(AssetRecord record) {
  final width = record.width, height = record.height;
  if (width == null || height == null) return null;
  return width > height ? width : height;
}

/// What's worth saying about one measured asset, or null when there's
/// nothing this page can offer about it.
StorageItem? adviseOn({
  required AssetRecord record,
  required int bytes,
  required String name,
  required bool appOwned,
  bool remoteOptimized = false,
}) {
  if (!worthMeasuring(record)) return null;

  // Both halves for a Live Photo: shrinking or dropping a local copy whose
  // `.mov` isn't in the bucket loses the motion and the sound.
  final backedUp = record.isFullyBackedUp;
  final still = !record.isVideo;
  final issues = <StorageIssue>{};

  // Only something actually wrong with the file. Being on the phone and
  // in the bucket is not: what to keep locally is the person's call, and
  // this page never offers to delete a local copy.
  if (bytes >= largeFileThreshold(isVideo: record.isVideo)) {
    issues.add(StorageIssue.largeFile);
  }
  if (still) {
    final edge = longestEdgeOf(record);
    if (edge != null && edge > highResolutionEdge) {
      issues.add(StorageIssue.highResolution);
    }
    if (_optimizableFormats.contains(p.extension(name).toLowerCase())) {
      issues.add(StorageIssue.optimizableFormat);
    }
  }

  final fixes = _fixesFor(
    record,
    issues,
    name: name,
    bytes: bytes,
    backedUp: backedUp,
    appOwned: appOwned,
    remoteOptimized: remoteOptimized,
  );
  if (fixes.isEmpty) return null;
  return StorageItem(
    record: record,
    bytes: bytes,
    name: name,
    appOwned: appOwned,
    issues: issues,
    fixes: fixes,
  );
}

/// A smaller copy on the phone (which the next sync also sends to the
/// bucket), or in the bucket only. Both wait on the bucket holding the
/// original — hence the one gate in front:
/// back it up first, and the real fixes are here on the next pass.
///
/// A camera-roll photo is shrunk too: the smaller copy goes back into
/// Photos in its place (`StorageOptimizer`).
List<StorageFix> _fixesFor(
  AssetRecord record,
  Set<StorageIssue> issues, {
  required String name,
  required int bytes,
  required bool backedUp,
  required bool appOwned,
  bool remoteOptimized = false,
}) {
  if (issues.isEmpty) return const [];
  if (!backedUp) return const [StorageFix.backUpFirst];
  final edge = longestEdgeOf(record);
  final ext = p.extension(name).toLowerCase();
  // One test for every re-encode: a smaller photo, a 1080p video, or a
  // bulky format made compact.
  final shrinkable =
      !record.localOptimized &&
      (record.isVideo
          ? (edge != null && edge > compressedVideoEdge) ||
                bytes >= largeVideoBytes
          : (edge != null &&
                    edge > optimizedMaxEdge &&
                    (appOwned || ext != '.gif')) ||
                (appOwned && issues.contains(StorageIssue.optimizableFormat)));
  return [
    if (shrinkable) StorageFix.optimize,
    if (shrinkable && !remoteOptimized) StorageFix.optimizeRemote,
  ];
}

/// Already cloud-only, binned, or behind a passcode — none of which has a
/// local copy this page may talk about.
bool worthMeasuring(AssetRecord record) =>
    !record.isDeleted &&
    !record.localDeleted &&
    !record.isHidden &&
    // A locked photo is being kept as it is, which is the opposite of
    // every fix this screen offers. Excluded here rather than at each fix,
    // so it never appears in the list, the total, or "free up to …" —
    // offering space that cannot be freed is worse than not offering it.
    !record.isLocked &&
    record.passcodeHash == null;

/// What one asset's local copy actually is, as opposed to what the record
/// remembers about it.
class AssetMeasure {
  const AssetMeasure({
    required this.bytes,
    required this.name,
    required this.appOwned,
  });

  final int bytes;
  final String name;

  /// This app wrote the file and may rewrite it. False for a camera-roll
  /// asset, whose bytes belong to PhotoKit.
  final bool appOwned;
}

/// One scan's findings, and how far through the library it got.
class StorageScan {
  const StorageScan({
    this.items = const [],
    this.scannedAt,
    this.measured = const {},
    this.complete = false,
  });

  final List<StorageItem> items;

  /// When the pass last reached the end. Null while one has never
  /// finished — which is not the same as never started.
  final DateTime? scannedAt;

  /// Every `localId` measured so far this pass. Persisted, so leaving the
  /// page (or the app) halfway through costs nothing: the next round picks
  /// up where this one stopped instead of walking the library again.
  final Set<String> measured;

  /// Nothing was left to measure when the last round ended.
  final bool complete;

  bool get neverScanned => scannedAt == null && measured.isEmpty;
}

/// Walks the library measuring local copies and turns each into advice,
/// then remembers what it found.
///
/// Deliberately metadata-only for camera-roll assets: `AssetEntity.fileSize`
/// reads `PHAssetResource.fileSize`, so a ten-year library can be sized
/// without pulling a single photo down from iCloud. It's still a channel
/// call per photo, which is why the result is filed in app state rather
/// than re-derived every time the page opens — see [cached].
class StorageAdvisor {
  StorageAdvisor({
    required this.store,
    this._library,
    this._measure,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final AssetRecordStore store;
  final PhotoLibraryService? _library;

  /// Overridable for tests so they never reach a real photo library.
  final Future<AssetMeasure?> Function(AssetRecord record)? _measure;

  final DateTime Function() _now;

  static const _reportEvery = 50;
  static const _cacheKey = 'storage_scan_v1';
  static const _remoteKey = 'remote_optimized_v1';

  /// Photos whose bucket copy has already been made smaller.
  Set<String> _remoteDone = {};

  Future<void> _loadRemoteDone() async {
    try {
      final raw = await store.getAppState(_remoteKey);
      _remoteDone = raw == null
          ? {}
          : {...(jsonDecode(raw) as List).cast<String>()};
    } catch (_) {
      _remoteDone = {};
    }
  }

  Future<void> markRemoteOptimized(String localId) async {
    await _loadRemoteDone();
    _remoteDone.add(localId);
    await store.setAppState(_remoteKey, jsonEncode([..._remoteDone]));
  }

  /// Photos that are the same file, byte for byte, as another in the
  /// library — by the hash taken when each was backed up, so only exact
  /// copies, never look-alikes. One per group is kept: a favourite, else
  /// the first added. Locked and hidden photos are never offered.
  Future<List<StorageItem>> duplicates() async {
    final groups = <String, List<AssetRecord>>{};
    for (final r in await store.listAll()) {
      if (r.isDeleted || r.isLocked || r.passcodeHash != null) continue;
      final hash = r.stateOf(DerivativeKind.original).backedUpHash;
      if (hash == null) continue;
      (groups[hash] ??= []).add(r);
    }
    final sizes = {
      for (final item in (await cached()).items) item.record.localId: item,
    };
    final out = <StorageItem>[];
    for (final group in groups.values) {
      if (group.length < 2) continue;
      group.sort((a, b) {
        if (a.isFavorite != b.isFavorite) return a.isFavorite ? -1 : 1;
        return a.addedAt.compareTo(b.addedAt);
      });
      final kept = group.first;
      final keptName = sizes[kept.localId]?.name ?? _recordName(kept);
      for (final r in group.skip(1)) {
        final known = sizes[r.localId];
        out.add(
          StorageItem(
            record: r,
            bytes: known?.bytes ?? 0,
            name: known?.name ?? _recordName(r),
            appOwned: r.sourcePath != null,
            issues: const {StorageIssue.duplicate},
            fixes: const [StorageFix.removeDuplicate],
            duplicateOf: keptName,
          ),
        );
      }
    }
    return out;
  }

  /// Photos with no copy on this phone whose bucket copy could be smaller:
  /// sized from the bucket listing, since there's nothing here to measure.
  /// Only ever offered Optimize in the bucket.
  Future<List<StorageItem>> cloudOnly() async {
    await _loadRemoteDone();
    final sizes = {
      for (final o in await store.listBucketObjects()) o.key: o.size,
    };
    final out = <StorageItem>[];
    for (final r in await store.listAll()) {
      if (!r.localDeleted ||
          r.isDeleted ||
          r.isHidden ||
          r.isLocked ||
          r.passcodeHash != null ||
          !r.isFullyBackedUp ||
          _remoteDone.contains(r.localId)) {
        continue;
      }
      final key = r.stateOf(DerivativeKind.original).destinationKey;
      final bytes = key == null ? null : sizes[key];
      if (key == null || bytes == null) continue;
      final edge = longestEdgeOf(r);
      final issues = {
        if (bytes >= largeFileThreshold(isVideo: r.isVideo))
          StorageIssue.largeFile,
        if (!r.isVideo && edge != null && edge > highResolutionEdge)
          StorageIssue.highResolution,
      };
      final shrinkable = r.isVideo
          ? (edge != null && edge > compressedVideoEdge) ||
                bytes >= largeVideoBytes
          : edge != null &&
                edge > optimizedMaxEdge &&
                p.extension(key).toLowerCase() != '.gif';
      if (issues.isEmpty || !shrinkable) continue;
      out.add(
        StorageItem(
          record: r,
          bytes: bytes,
          name: p.basename(key),
          appOwned: false,
          issues: issues,
          fixes: const [StorageFix.optimizeRemote],
        ),
      );
    }
    return out;
  }

  static String _recordName(AssetRecord r) =>
      r.sourcePath != null ? p.basename(r.sourcePath!) : r.localId;

  /// What the last scan found, or an empty never-scanned result.
  ///
  /// Only the measured **size** is taken from the cache. Everything else —
  /// backed up or not, still on the device, binned since — is re-read off
  /// the current record, because those answers are free and a stale one
  /// would offer a fix for something already fixed.
  Future<StorageScan> cached() async {
    await _loadRemoteDone();
    final raw = await store.getAppState(_cacheKey);
    if (raw == null) return const StorageScan();
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      final rows = (decoded['items'] as List?) ?? const [];
      final records = {
        for (final record in await store.listAll()) record.localId: record,
      };
      final items = <StorageItem>[];
      for (final row in rows.cast<Map<String, dynamic>>()) {
        final record = records[row['localId'] as String];
        if (record == null) continue;
        final item = adviseOn(
          record: record,
          bytes: row['bytes'] as int,
          name: row['name'] as String,
          appOwned: row['appOwned'] as bool,
          remoteOptimized: _remoteDone.contains(record.localId),
        );
        if (item != null) items.add(item);
      }
      return StorageScan(
        items: _ranked(items),
        scannedAt: DateTime.tryParse(decoded['scannedAt'] as String? ?? ''),
        measured: {
          for (final id in (decoded['measured'] as List?) ?? const [])
            id as String,
        },
        complete: decoded['complete'] as bool? ?? false,
      );
    } catch (_) {
      // An older build's shape, or a half-written value — scanning again
      // is cheaper than guessing what it meant.
      return const StorageScan();
    }
  }

  /// Measures whatever hasn't been measured yet and files the result.
  ///
  /// **Resumable, and saved as it goes.** Walking a ten-year library is a
  /// channel call per photo; a pass that only wrote its answer at the end
  /// meant leaving the page halfway threw the whole thing away and the
  /// next visit started at zero. Every [_reportEvery] photos the running
  /// total goes to disk, so stopping costs at most that many.
  ///
  /// [restart] measures everything again — what the Rescan button does.
  /// [limit] caps how many photos this round touches, which is what makes
  /// the background sweep cheap enough to run unasked.
  ///
  /// [onProgress] lands on the same beat, so the page fills as it goes.
  Future<StorageScan> scan({
    bool restart = false,
    int? limit,
    void Function(List<StorageItem> found, int done, int total)? onProgress,
  }) async {
    await _loadRemoteDone();
    final previous = restart ? const StorageScan() : await cached();
    final candidates = (await store.listAll()).where(worthMeasuring).toList();
    final measured = {...previous.measured};
    final found = [...previous.items];
    final todo = candidates
        .where((r) => !measured.contains(r.localId))
        .toList();
    final total = candidates.length;

    if (todo.isEmpty) {
      return _save(
        StorageScan(
          items: _ranked(found),
          scannedAt: previous.scannedAt ?? _now(),
          measured: measured,
          complete: true,
        ),
      );
    }

    final take = limit == null || limit > todo.length ? todo.length : limit;
    var scan = previous;
    for (var i = 0; i < take; i++) {
      final record = todo[i];
      measured.add(record.localId);
      final measure = await _measureOne(record);
      if (measure != null) {
        final item = adviseOn(
          record: record,
          bytes: measure.bytes,
          name: measure.name,
          appOwned: measure.appOwned,
          remoteOptimized: _remoteDone.contains(record.localId),
        );
        if (item != null) found.add(item);
      }
      final last = i == take - 1;
      if ((i + 1) % _reportEvery == 0 || last) {
        final done = measured.length;
        scan = await _save(
          StorageScan(
            items: _ranked(found),
            // Only a pass that reached the end gets to claim a date.
            scannedAt: done >= total ? _now() : previous.scannedAt,
            measured: measured,
            complete: done >= total,
          ),
        );
        // This pass's own progress: only what wasn't measured before.
        onProgress?.call(scan.items, i + 1, take);
      }
    }
    return scan;
  }

  /// One small, unasked round of the same pass — for the background
  /// trickle. Deliberately a handful of photos at a time: this is the app
  /// keeping its own answer fresh, and it has all day to do it.
  static const sweepSize = 50;

  Future<StorageScan> sweep() => scan(limit: sweepSize);

  /// Re-measures only the assets a fix just touched and files the result
  /// back. Walking the whole library again to find out what one removal
  /// did would be the entire scan over.
  Future<StorageScan> remeasure(StorageScan scan, Set<String> localIds) async {
    await _loadRemoteDone();
    final records = {
      for (final record in await store.listAll()) record.localId: record,
    };
    final items = <StorageItem>[];
    for (final item in scan.items) {
      final record = records[item.record.localId];
      if (record == null) continue;
      final measure = localIds.contains(item.record.localId)
          ? await _measureOne(record)
          : AssetMeasure(
              bytes: item.bytes,
              name: item.name,
              appOwned: item.appOwned,
            );
      if (measure == null) continue;
      final again = adviseOn(
        record: record,
        bytes: measure.bytes,
        name: measure.name,
        appOwned: measure.appOwned,
        remoteOptimized: _remoteDone.contains(record.localId),
      );
      if (again != null) items.add(again);
    }
    return _save(
      StorageScan(
        items: _ranked(items),
        scannedAt: scan.scannedAt,
        measured: scan.measured,
        complete: scan.complete,
      ),
    );
  }

  Future<StorageScan> _save(StorageScan scan) async {
    await store.setAppState(
      _cacheKey,
      jsonEncode({
        'scannedAt': scan.scannedAt?.toIso8601String(),
        'complete': scan.complete,
        'measured': scan.measured.toList(),
        'items': [
          for (final item in scan.items)
            {
              'localId': item.record.localId,
              'bytes': item.bytes,
              'name': item.name,
              'appOwned': item.appOwned,
            },
        ],
      }),
    );
    return scan;
  }

  /// Biggest file first. The page is about where the space went, and the
  /// answer to that is the size on disk — not how much of it a particular
  /// fix happens to give back.
  static List<StorageItem> _ranked(List<StorageItem> items) =>
      [...items]..sort((a, b) => b.bytes.compareTo(a.bytes));

  Future<AssetMeasure?> _measureOne(AssetRecord record) async {
    final measure = _measure;
    if (measure != null) return measure(record);

    final path = record.sourcePath;
    if (path != null) {
      try {
        final file = File(path);
        if (await file.exists()) {
          return AssetMeasure(
            bytes: (await file.stat()).size,
            name: p.basename(path),
            appOwned: true,
          );
        }
      } catch (_) {
        // Unreadable — fall through to the photo library.
      }
    }

    final library = _library;
    if (library == null) return null;
    if (record.sourceType != AssetSourceType.photoManager) return null;
    try {
      final entity = await library.entityFor(record);
      if (entity == null) return null;
      final bytes = await entity.fileSize;
      if (bytes <= 0) return null;
      return AssetMeasure(
        bytes: bytes,
        name: await _nameOf(entity),
        appOwned: false,
      );
    } catch (_) {
      // Gone from the library since, or no plugin at all.
      return null;
    }
  }

  static Future<String> _nameOf(AssetEntity entity) async {
    try {
      final title = await entity.titleAsync;
      if (title.isNotEmpty) return title;
    } catch (_) {
      // No filename to be had — the date on the card says which photo it is.
    }
    return entity.title ?? '';
  }
}

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var value = bytes / 1024;
  var i = 0;
  while (value >= 1024 && i < units.length - 1) {
    value /= 1024;
    i++;
  }
  return '${value.toStringAsFixed(1)} ${units[i]}';
}
