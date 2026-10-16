import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../settings/backup_targets_store.dart';
import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import '../storage/bucket_object.dart';
import '../upload/bucket_flagged.dart';
import '../upload/bucket_import.dart' show BucketIndexer;
import '../vault/hidden_repair.dart';
import 'fix_queue.dart';
import 'storage_advice.dart';

/// Everything Flagged Items lists, from one scan.
///
/// [flags] is every kind together, one entry per id, hidden photos never
/// among them, before the queue's own filter (done, kept, filed).
class FlagScanResult {
  const FlagScanResult({
    this.flags = const [],
    this.review = const [],
    this.storageScannedAt,
    this.stamp,
  });

  final List<Flag> flags;

  /// The one-time repair's list, ordinary photos only.
  final List<RepairItem> review;

  /// When the storage pass last reached the end.
  final DateTime? storageScannedAt;

  /// What the inputs looked like when this was worked out ([FlagScan.stamp]);
  /// null before any scan.
  final String? stamp;
}

/// The one detector behind Flagged Items: storage, duplicates, cloud-only,
/// records and the bucket, read from one snapshot of the library and the
/// bucket index, one scan at a time.
///
/// The last result is kept in app state with the [stamp] of the inputs it
/// came from, so the page shows it at once and scans again only when the
/// library, the bucket index or a fix's bookkeeping moved. A part that
/// can't be read keeps what it found last time; nothing is cleared while a
/// scan runs. After every scan the queue is [FixQueue.settle]d, which is
/// what makes a fix stay fixed.
///
/// Owned by the library screen, beside the queue, so a scan outlives the
/// page and a second page joins it.
class FlagScan extends ChangeNotifier {
  FlagScan({
    required this.store,
    required this.targetsStore,
    required this.advisor,
    required this.queue,
    this._relist,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final AssetRecordStore store;
  final BackupTargetsStore targetsStore;
  final StorageAdvisor advisor;
  final FixQueue queue;
  final Future<bool> Function()? _relist;
  final DateTime Function() _now;

  static const stateKey = 'flag_scan_v1';

  /// App state a detector reads besides the library and the bucket index.
  static const _inputs = [
    'import_copies_v1',
    'flag_kept_v1',
    'bucket_ignored_keys',
    'remote_optimized_v1',
    'smallest_already_v1',
    'lost_original_ids',
    HiddenRepair.stateKey,
  ];

  FlagScanResult _result = const FlagScanResult();
  FlagScanResult get result => _result;

  /// A scan is under way; [result] is the last one until it lands.
  bool get running => _running != null;

  /// The bucket's part is still being read.
  bool bucketRunning = false;

  /// The storage pass, measured so far of how many.
  bool storageRunning = false;
  int scanned = 0;
  int toScan = 0;

  // Each part as last found. One that failed keeps its last value.
  List<Flag> _storage = const [];
  List<Flag> _duplicates = const [];
  List<Flag> _cloudOnly = const [];
  List<Flag> _records = const [];
  List<Flag> _bucket = const [];
  List<RepairItem> _review = const [];
  DateTime? _storageAt;

  /// Whether the parts the storage list is filtered by were read. Until
  /// both are, Optimize is not offered: it could be an exact copy, or a
  /// photo whose smaller copy is already in Photos.
  bool _duplicatesKnown = false;
  bool _recordsKnown = false;

  bool _loaded = false;

  /// The inputs in one string: the record revision, the bucket index and
  /// upload rows, and the app state the detectors read. A few aggregate
  /// queries and small reads, cheap enough to ask while the page is open.
  Future<String> stamp() async {
    final digest = sha1.convert(
      utf8.encode(
        [for (final key in _inputs) (await store.getAppState(key)) ?? '']
            .join('\u0000'),
      ),
    );
    return '${await store.revision()}|${await store.bucketStamp()}|$digest';
  }

  /// The page opening: the last result at once, then a scan only if
  /// something it was worked out from has moved.
  Future<void> open() async {
    await queue.loadKept();
    if (!_loaded) await _load();
    try {
      await BucketIndexer(
        targetsStore: targetsStore,
        recordStore: store,
      ).forgetRemovedBuckets();
    } catch (_) {
      // Keychain unreadable: the listing stands until the scan.
    }
    if (_result.stamp == null ||
        _storageAt == null ||
        await stamp() != _result.stamp) {
      unawaited(run());
    }
  }

  DateTime? _lastRun;

  /// While the page is open: scans again when an input moved, at most
  /// every [minGap], and never under a running fix (the run's end does).
  Future<void> refreshIfChanged({
    Duration minGap = const Duration(seconds: 15),
  }) async {
    if (running || queue.running) return;
    final last = _lastRun;
    if (last != null && _now().difference(last) < minGap) return;
    if (await stamp() == _result.stamp) return;
    await run();
  }

  Future<void>? _running;
  bool _again = false;
  bool _againRelist = false;
  bool _againRestart = false;

  /// One scan. Asked while one runs, it runs once more after it, with
  /// everything that was asked for; the caller waits for both.
  /// [relist] lists the buckets first; [restart] measures every photo
  /// again.
  Future<void> run({bool relist = false, bool restart = false}) {
    if (_running case final busy?) {
      _again = true;
      _againRelist |= relist;
      _againRestart |= restart;
      return busy;
    }
    final run = _running = _loop(relist, restart);
    notifyListeners();
    return run.whenComplete(() {
      _running = null;
      notifyListeners();
    });
  }

  Future<void> _loop(bool relist, bool restart) async {
    var (l, r) = (relist, restart);
    do {
      _again = false;
      await _scanOnce(relist: l, restart: r);
      (l, r) = (_againRelist, _againRestart);
      _againRelist = _againRestart = false;
    } while (_again);
  }

  Future<void> _scanOnce({required bool relist, required bool restart}) async {
    final started = _now();
    _lastRun = started;
    var whole = true;

    var objects = await store.listBucketObjects();
    if (relist || objects.isEmpty) {
      bucketRunning = true;
      notifyListeners();
      try {
        await (_relist ??
            BucketIndexer(
              targetsStore: targetsStore,
              recordStore: store,
            ).refresh)();
        objects = await store.listBucketObjects();
      } catch (_) {
        // Offline: the index on file stands.
      }
    }
    var records = await store.listAll();

    StorageScan sized;
    try {
      sized = await advisor.cached(records: records, objects: objects);
      _setStorage(sized);
    } catch (_) {
      sized = const StorageScan();
      whole = false;
    }
    try {
      _duplicates = [
        for (final item in await advisor.duplicates(
          records: records,
          sized: sized,
        ))
          Flag.storage(item),
      ];
      _duplicatesKnown = true;
    } catch (_) {
      whole = false;
    }
    try {
      _cloudOnly = [
        for (final item in await advisor.cloudOnly(
          records: records,
          objects: objects,
        ))
          Flag.storage(item),
      ];
    } catch (_) {
      whole = false;
    }
    final fixer = queue.records;
    if (fixer == null) {
      _recordsKnown = true;
    } else {
      try {
        final found = await fixer.scan(records: records, objects: objects);
        _records = [
          ...found.lost,
          ...found.leftoverCopies,
          ...found.importCopies,
          ...found.noThumbnail,
        ];
        _recordsKnown = true;
        // It may have pointed a record at what the bucket has.
        records = await store.listAll();
      } catch (_) {
        whole = false;
      }
    }
    try {
      _review = [
        for (final f in await HiddenRepair(store: store).findings() ?? [])
          if (!f.hidden && f.kind == RepairKind.carrierStem) f,
      ];
    } catch (_) {}
    _publish(records);

    final parts = await Future.wait([
      _measure(
        due: restart || !sized.complete,
        restart: restart,
        records: records,
      ),
      _scanBucket(objects, records),
    ]);
    whole = whole && parts.every((ok) => ok);

    final at = await stamp();
    _publish(await store.listAll(), stamp: at);
    await _save();
    if (whole && _storageAt != null) {
      await queue.settle(_result.flags, started);
    }
  }

  /// The storage pass, flat out: the page is the one time somebody waits
  /// for it. Off the page it trickles (`StorageAdvisor.sweep`).
  Future<bool> _measure({
    required bool due,
    required bool restart,
    required List<AssetRecord> records,
  }) async {
    if (!due) return true;
    storageRunning = true;
    notifyListeners();
    try {
      final found = await advisor.scan(
        restart: restart,
        onProgress: (items, done, total) {
          scanned = done;
          toScan = total;
          _setStorage(StorageScan(items: items, scannedAt: _storageAt));
          _publish(records);
        },
      );
      _setStorage(found);
      return true;
    } catch (_) {
      return false;
    } finally {
      storageRunning = false;
      _publish(records);
    }
  }

  void _setStorage(StorageScan scan) {
    _storageAt = scan.scannedAt ?? _storageAt;
    _storage = [for (final item in scan.items) Flag.storage(item)];
  }

  Future<bool> _scanBucket(
    List<BucketObject> objects,
    List<AssetRecord> records,
  ) async {
    bucketRunning = true;
    notifyListeners();
    final fixer = queue.fixer;
    final reformatable = {
      for (final f in _bucket)
        if (f.solutions.contains(FlagSolution.reformat)) f.id,
    };
    try {
      final found = await BucketFlags(store: store).detect(
        inspect: fixer.inspect,
        etag: fixer.etagOf,
        objects: objects,
        records: records,
      );
      // What was known to re-format still is while it is asked again: the
      // row doesn't drop out and come back.
      _bucket = [
        for (final o in found)
          Flag.bucket(
            o,
            reformatable: reformatable.contains(bucketFlagId(o.object)),
          ),
      ];
      _publish(records);
      // Re-format only once the header says the file isn't a hidden
      // photo: a read per object, a few at a time, after the list.
      final candidates = [
        for (final o in found)
          if (o.kind == FlagKind.offProtocol && !o.isVideo) o,
      ];
      for (var i = 0; i < candidates.length; i += 8) {
        final chunk = candidates.skip(i).take(8).toList();
        final ok = await Future.wait(chunk.map(fixer.canReformat));
        final verdict = {
          for (final (j, o) in chunk.indexed) bucketFlagId(o.object): ok[j],
        };
        _bucket = [
          for (final f in _bucket)
            if (verdict[f.id] case final yes? when f.bucket != null)
              Flag.bucket(f.bucket!, reformatable: yes)
            else
              f,
        ];
        _publish(records);
      }
      return true;
    } catch (_) {
      // Offline: whatever the index already had stays listed.
      return false;
    } finally {
      // Saved even when left mid-way: what was read stays read.
      try {
        await fixer.saveLooks();
      } catch (_) {}
      bucketRunning = false;
      notifyListeners();
    }
  }

  /// Every part into one list. Once per part landing, never per build.
  void _publish(List<AssetRecord> records, {String? stamp}) {
    final byId = {for (final r in records) r.localId: r};
    bool visible(Flag f) {
      final id = f.record?.localId;
      if (id == null) return true;
      final r = byId[id];
      return r != null && !r.isDeleted && !r.isHidden && r.passcodeHash == null;
    }

    final copies = {for (final f in _duplicates) f.id};
    // A photo whose copy is already in Photos is finished, not optimized
    // again: that would file a second copy for it.
    final hasCopy = {
      for (final f in _records)
        if (f.solutions.contains(FlagSolution.finishOptimize) ||
            f.solutions.contains(FlagSolution.removeExtraCopies))
          ?f.asset?.localId,
    };
    final storage = _duplicatesKnown && _recordsKnown
        ? [
            for (final f in _storage)
              if (!copies.contains(f.id) &&
                  !hasCopy.contains(f.storage?.record.localId))
                f,
          ]
        : const <Flag>[];
    final seen = <String>{};
    final flags = [
      for (final f in [
        ..._duplicates,
        ...storage,
        ..._cloudOnly,
        ..._records,
        ..._bucket,
      ])
        if (visible(f) && seen.add(f.id)) f,
    ]..sort(_stable);
    _result = FlagScanResult(
      flags: flags,
      review: [
        for (final item in _review)
          if (byId[item.localId] case final r?
              when !r.isHidden && r.passcodeHash == null && !r.isDeleted)
            item,
      ],
      storageScannedAt: _storageAt,
      stamp: stamp ?? _result.stamp,
    );
    notifyListeners();
  }

  /// Biggest first, then by id: the same scan always lists the same way.
  static int _stable(Flag a, Flag b) {
    final bySize = b.bytes.compareTo(a.bytes);
    return bySize != 0 ? bySize : a.id.compareTo(b.id);
  }

  // ------------------------------------------------------------- persisted

  Future<void> _save() async {
    try {
      await store.setAppState(
        stateKey,
        jsonEncode({
          'stamp': _result.stamp,
          'duplicatesKnown': _duplicatesKnown,
          'recordsKnown': _recordsKnown,
          'duplicates': [for (final f in _duplicates) _storageRow(f)],
          'cloudOnly': [for (final f in _cloudOnly) _storageRow(f)],
          'records': [for (final f in _records) _assetRow(f)],
          'bucket': [for (final f in _bucket) _bucketRow(f)],
          'review': [for (final r in _review) r.toJson()],
        }),
      );
    } catch (_) {
      // Worked out again next time.
    }
  }

  /// The last result, bound to the records and the index as they are now.
  /// Storage comes from the advisor's own file.
  Future<void> _load() async {
    _loaded = true;
    try {
      final raw = await store.getAppState(stateKey);
      final records = await store.listAll();
      final objects = await store.listBucketObjects();
      _setStorage(await advisor.cached(records: records, objects: objects));
      if (raw == null) {
        _publish(records);
        return;
      }
      final byId = {for (final r in records) r.localId: r};
      final byKey = {for (final o in objects) bucketFlagId(o): o};
      final saved = jsonDecode(raw) as Map<String, dynamic>;
      List<Map<String, dynamic>> rows(String key) =>
          ((saved[key] as List?) ?? const []).cast<Map<String, dynamic>>();
      _duplicates = [
        for (final row in rows('duplicates')) ?_storageFlag(row, byId),
      ];
      _cloudOnly = [
        for (final row in rows('cloudOnly')) ?_storageFlag(row, byId),
      ];
      _records = [for (final row in rows('records')) ?_assetFlag(row, byId)];
      _bucket = [for (final row in rows('bucket')) ?_bucketFlag(row, byKey)];
      _review = [for (final row in rows('review')) ?RepairItem.fromJson(row)];
      _duplicatesKnown = saved['duplicatesKnown'] == true;
      _recordsKnown = saved['recordsKnown'] == true;
      _publish(records, stamp: saved['stamp'] as String?);
    } catch (_) {
      // An older shape, or half written: the scan finds it all again.
    }
  }

  static Map<String, Object?> _storageRow(Flag f) {
    final item = f.storage!;
    return {
      'id': item.record.localId,
      'bytes': item.bytes,
      'name': item.name,
      'owned': item.appOwned,
      'issues': [for (final i in item.issues) i.name],
      'fixes': [for (final x in item.fixes) x.name],
      'dupOf': item.duplicateOf,
      'kept': item.keptId,
    };
  }

  static Flag? _storageFlag(
    Map<String, dynamic> row,
    Map<String, AssetRecord> byId,
  ) {
    final record = byId[row['id']];
    if (record == null) return null;
    final issues = StorageIssue.values.asNameMap();
    final fixes = StorageFix.values.asNameMap();
    final fix = [
      for (final name in (row['fixes'] as List).cast<String>()) ?fixes[name],
    ];
    if (fix.isEmpty) return null;
    return Flag.storage(
      StorageItem(
        record: record,
        bytes: row['bytes'] as int,
        name: row['name'] as String,
        appOwned: row['owned'] as bool,
        issues: {
          for (final name in (row['issues'] as List).cast<String>())
            ?issues[name],
        },
        fixes: fix,
        duplicateOf: row['dupOf'] as String?,
        keptId: row['kept'] as String?,
      ),
    );
  }

  static Map<String, Object?> _assetRow(Flag f) => {
    'id': f.asset!.localId,
    'problem': f.problems.first.name,
    'solutions': [for (final s in f.solutions) s.name],
    'bytes': f.bytes,
    'name': f.name,
  };

  static Flag? _assetFlag(
    Map<String, dynamic> row,
    Map<String, AssetRecord> byId,
  ) {
    final record = byId[row['id']];
    final problem = FlagProblem.values.asNameMap()[row['problem']];
    if (record == null || problem == null) return null;
    final names = FlagSolution.values.asNameMap();
    return Flag.asset(
      record,
      problem: problem,
      solutions: [
        for (final s in (row['solutions'] as List).cast<String>()) ?names[s],
      ],
      bytes: row['bytes'] as int? ?? 0,
      name: row['name'] as String? ?? '',
    );
  }

  static Map<String, Object?> _bucketRow(Flag f) {
    final b = f.bucket!;
    return {
      't': b.object.targetId,
      'k': b.object.key,
      'kind': b.kind.name,
      'takenAt': b.takenAt?.toIso8601String(),
      'dupOf': b.likelyDuplicateOf,
      'owner': b.ownerId,
      'reformat': f.solutions.contains(FlagSolution.reformat),
    };
  }

  static Flag? _bucketFlag(
    Map<String, dynamic> row,
    Map<String, BucketObject> byKey,
  ) {
    final object = byKey['bucket:${row['t']}|${row['k']}'];
    final kind = FlagKind.values.asNameMap()[row['kind']];
    if (object == null || kind == null) return null;
    return Flag.bucket(
      FlaggedObject(
        object: object,
        kind: kind,
        takenAt: DateTime.tryParse(row['takenAt'] as String? ?? ''),
        likelyDuplicateOf: row['dupOf'] as String?,
        ownerId: row['owner'] as String?,
      ),
      reformatable: row['reformat'] == true,
    );
  }
}
