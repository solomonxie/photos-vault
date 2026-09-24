import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:photo_manager/photo_manager.dart';

import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import 'photo_library_service.dart';
import 'thumbnail_cache.dart';

/// What's costing space on one asset. An asset can carry several — a 40 MB
/// 6000-px PNG carries three.
///
/// "Not backed up" is deliberately not one of them: it's a backup problem,
/// answered by the sync queue, and a page about reclaiming space that
/// listed every un-uploaded photo would be a second, worse copy of it. It
/// only shows up here as [StorageFix.backUpFirst] — the gate in front of a
/// real fix, on a photo that has a real problem.
enum StorageIssue { onDevice, largeFile, highResolution, optimizableFormat }

/// The one thing offered about an asset. Only ever something this app can
/// actually do: a backed-up video is listed nowhere here, because removing
/// it would leave the grid with nothing to draw (no video thumbnail
/// pipeline yet, T2.3) and there's no video re-encoder either.
enum StorageFix {
  backUpFirst,
  removeFromDevice,
  reduceResolution,
  convertFormat,
}

/// Past this, a single file is worth calling out whatever else is true
/// about it. Two numbers because one would be wrong for both: 10 MB is a
/// fat photo and an unremarkable video.
const largePhotoBytes = 10 * 1024 * 1024;
const largeVideoBytes = 100 * 1024 * 1024;

int largeFileThreshold({required bool isVideo}) =>
    isVideo ? largeVideoBytes : largePhotoBytes;

/// More pixels than a phone screen can ever show, and more than the
/// bucket needs to keep a usable local copy.
const highResolutionEdge = 4000;

/// What [StorageFix.reduceResolution] shrinks to — still sharp full-screen
/// on a 3x display, a fraction of the bytes.
const optimizedMaxEdge = 2560;

/// Formats that re-encode dramatically smaller. HEIC and JPEG are left out
/// on purpose: they're already compressed, and converting them buys little
/// for the quality it costs.
const _optimizableFormats = {'.png', '.bmp', '.tif', '.tiff'};

/// One asset with something to fix about it.
class StorageItem {
  const StorageItem({
    required this.record,
    required this.bytes,
    required this.name,
    required this.appOwned,
    required this.issues,
    required this.fix,
  });

  final AssetRecord record;

  /// Size of the local copy. For a camera-roll asset that's PhotoKit's own
  /// figure for the current resource — metadata, never a download.
  final int bytes;

  final String name;

  /// See [AssetMeasure.appOwned]. Carried so a cached scan can be re-read
  /// against a changed record without measuring the file again.
  final bool appOwned;

  final Set<StorageIssue> issues;
  final StorageFix fix;

  /// Exact for a removal, a guess for the two re-encodes — nothing knows
  /// what the encoder will produce until it has run. Every total built on
  /// this is shown as "about".
  int get estimatedSaving => switch (fix) {
    StorageFix.backUpFirst => 0,
    StorageFix.removeFromDevice => bytes,
    StorageFix.convertFormat => (bytes * 0.5).round(),
    StorageFix.reduceResolution => _resizedSaving,
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
}) {
  if (!worthMeasuring(record)) return null;

  // Both halves for a Live Photo: shrinking or dropping a local copy whose
  // `.mov` isn't in the bucket loses the motion and the sound.
  final backedUp = record.isFullyBackedUp;
  final still = !record.isVideo;
  final issues = <StorageIssue>{};

  // Facts about the file, whatever can or can't be done about them — the
  // tags are there to explain the size, not only to justify the button.
  //
  // Videos count now that they get a poster frame out of the photo
  // library: the grid has something to draw once the movie itself is
  // gone, which is the only thing that ever ruled them out.
  if (backedUp && ThumbnailCache.canThumbnail(record)) {
    issues.add(StorageIssue.onDevice);
  }
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

  final fix = _fixFor(issues, backedUp: backedUp, appOwned: appOwned);
  if (fix == null) return null;
  return StorageItem(
    record: record,
    bytes: bytes,
    name: name,
    appOwned: appOwned,
    issues: issues,
    fix: fix,
  );
}

/// Gentlest first: shrink it in place if this app owns the file, and only
/// remove the local copy when there's nothing smaller to make of it.
///
/// Everything here either replaces the local copy or deletes it, so all of
/// it waits on the bucket holding the original — hence the one gate in
/// front: back it up first, and the real fix is here on the next pass.
StorageFix? _fixFor(
  Set<StorageIssue> issues, {
  required bool backedUp,
  required bool appOwned,
}) {
  if (issues.isEmpty) return null;
  if (!backedUp) return StorageFix.backUpFirst;
  if (appOwned && issues.contains(StorageIssue.highResolution)) {
    return StorageFix.reduceResolution;
  }
  if (appOwned && issues.contains(StorageIssue.optimizableFormat)) {
    return StorageFix.convertFormat;
  }
  if (issues.contains(StorageIssue.onDevice)) {
    return StorageFix.removeFromDevice;
  }
  return null;
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
    PhotoLibraryService? library,
    Future<AssetMeasure?> Function(AssetRecord record)? measure,
    DateTime Function()? now,
  }) : _library = library,
       _measure = measure,
       _now = now ?? DateTime.now;

  final AssetRecordStore store;
  final PhotoLibraryService? _library;

  /// Overridable for tests so they never reach a real photo library.
  final Future<AssetMeasure?> Function(AssetRecord record)? _measure;

  final DateTime Function() _now;

  static const _reportEvery = 50;
  static const _cacheKey = 'storage_scan_v1';

  /// What the last scan found, or an empty never-scanned result.
  ///
  /// Only the measured **size** is taken from the cache. Everything else —
  /// backed up or not, still on the device, binned since — is re-read off
  /// the current record, because those answers are free and a stale one
  /// would offer a fix for something already fixed.
  Future<StorageScan> cached() async {
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
        onProgress?.call(scan.items, done, total);
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
