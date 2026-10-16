import 'package:path/path.dart' as p;

import 'package:photos_vault/storage/asset_record.dart';
import 'package:photos_vault/storage/asset_record_store.dart';
import 'package:photos_vault/storage/bucket_object.dart';

/// Pure-Dart, in-memory stand-in for [AssetRecordStore] — for widget tests.
///
/// Widget tests run in `testWidgets`' fake-async zone, where real
/// `sqflite_common_ffi` calls (isolate round-trips) never resolve without
/// `tester.runAsync` gymnastics around every call site, including teardown.
/// Overriding every method here keeps the real database out of the picture
/// entirely; use the real ffi-backed store (via a plain `test()`, not
/// `testWidgets()`) to test `AssetRecordStore` itself.
class FakeAssetRecordStore implements AssetRecordStore {
  final _records = <String, AssetRecord>{};

  @override
  Future<void> close() async {}

  @override
  Future<bool> keyHeldByOthers(String key, String? exceptLocalId) async {
    for (final MapEntry(key: slot, value: held) in uploads.entries) {
      if (slot.startsWith('$exceptLocalId/')) continue;
      if (held.values.any((v) => v.key == key)) return true;
    }
    return _records.values.any(
      (r) =>
          r.localId != exceptLocalId &&
          DerivativeKind.values.any((k) => r.stateOf(k).destinationKey == key),
    );
  }

  @override
  Future<bool> originalStemHeld(String stem) async => _records.values.any(
    (r) => switch (r.stateOf(DerivativeKind.original).destinationKey) {
      final key? => p.posix.basenameWithoutExtension(key) == stem,
      null => false,
    },
  );

  @override
  Future<List<Map<String, Object?>>> uploadRows() async => [
    for (final MapEntry(:key, :value) in uploads.entries)
      for (final e in value.entries)
        {
          'local_id': key.substring(0, key.lastIndexOf('/')),
          'kind': key.substring(key.lastIndexOf('/') + 1),
          'target_id': e.key,
          'destination_key': e.value.key,
          'source_hash': e.value.hash,
        },
  ];

  @override
  Future<Map<String, Map<DerivativeKind, Map<String, String>>>>
  allHoldings() async {
    final out = <String, Map<DerivativeKind, Map<String, String>>>{};
    for (final MapEntry(:key, :value) in uploads.entries) {
      final cut = key.lastIndexOf('/');
      final kind = DerivativeKind.values.byName(key.substring(cut + 1));
      (out[key.substring(0, cut)] ??= {})[kind] = {
        for (final e in value.entries) e.key: e.value.key,
      };
    }
    return out;
  }

  @override
  Future<void> forgetTargetUpload(
    String localId,
    DerivativeKind kind,
    String targetId,
  ) async {
    uploads['$localId/${kind.name}']?.remove(targetId);
  }

  @override
  Future<AssetRecord> upsert({
    required String localId,
    required String contentHash,
    required String platform,
    AssetSourceType sourceType = AssetSourceType.photoManager,
    String? sourcePath,
    bool isVideo = false,
    bool isGif = false,
    bool isLivePhoto = false,
    DateTime? createdAt,
    DateTime? addedAt,
    double? latitude,
    double? longitude,
    int? width,
    int? height,
    String? libraryId,
    String? passcodeHash,
    bool isHidden = false,
    bool keepOnLibraryConflict = false,
  }) async {
    final existing = _records[localId];
    if (existing != null) return existing;
    // As the real store's unique index: one record per asset.
    if (libraryId != null) {
      final holder = _records.values
          .where((r) => r.libraryId == libraryId)
          .firstOrNull;
      if (holder != null) {
        if (!keepOnLibraryConflict) return holder;
        libraryId = null;
      }
    }
    final now = createdAt ?? DateTime.now();
    final record = AssetRecord(
      localId: localId,
      contentHash: contentHash,
      platform: platform,
      sourceType: sourceType,
      sourcePath: sourcePath,
      isVideo: isVideo,
      isGif: isGif,
      isLivePhoto: isLivePhoto,
      libraryId: libraryId,
      latitude: latitude,
      longitude: longitude,
      width: width,
      height: height,
      passcodeHash: passcodeHash,
      isHidden: isHidden,
      createdAt: now,
      updatedAt: now,
      addedAt: addedAt,
    );
    _records[localId] = record;
    upserts.add(record);
    return record;
  }

  /// Every record as its first write made it.
  final upserts = <AssetRecord>[];

  final transitions = <String, TransitionRow>{};

  /// Names a journal write to fail, once — a kill at that point.
  String? crashAt;

  void _maybeCrash(String at) {
    if (crashAt != at) return;
    crashAt = null;
    throw StateError('killed at $at');
  }

  @override
  Future<List<TransitionRow>> openTransitions() async => [
    ...transitions.values,
  ];

  @override
  Future<void> openTransition(
    String localId,
    String kind, {
    String payload = '',
    String? passcodeHash,
  }) async {
    _maybeCrash('open');
    if (passcodeHash != null) await setPasscodeHash(localId, passcodeHash);
    transitions[localId] = TransitionRow(
      localId: localId,
      kind: kind,
      step: 0,
      payload: payload,
    );
  }

  @override
  Future<void> retractUploads(
    String localId, {
    required int step,
    String? payload,
    bool unhide = false,
  }) async {
    _maybeCrash('retract');
    await forgetUploads(localId);
    for (final kind in DerivativeKind.values) {
      await updateDerivative(localId, kind, const DerivativeState());
    }
    if (unhide) await setPasscodeHash(localId, null);
    final row = transitions[localId];
    if (row != null) {
      transitions[localId] = TransitionRow(
        localId: localId,
        kind: row.kind,
        step: step,
        payload: payload ?? row.payload,
      );
    }
  }

  @override
  Future<void> closeTransition(String localId, {bool unhide = false}) async {
    _maybeCrash('close');
    if (unhide) await setPasscodeHash(localId, null);
    transitions.remove(localId);
  }

  @override
  Future<AssetRecord?> getByLocalId(String localId) async => _records[localId];

  @override
  Future<void> updateDerivative(
    String localId,
    DerivativeKind kind,
    DerivativeState state,
  ) async {
    final existing = _records[localId];
    if (existing == null) return;
    _records[localId] = existing.withDerivative(kind, state);
  }

  /// Set to make [listAll] throw, like a locked or corrupt database.
  var throwOnListAll = false;

  @override
  Future<List<AssetRecord>> listAll() async {
    if (throwOnListAll) throw StateError('database unavailable');
    return _records.values.toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
  }

  @override
  Future<List<AssetRecord>> listNewest(int limit) async {
    final all = _records.values.toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return all.sublist(all.length > limit ? all.length - limit : 0);
  }

  @override
  Future<void> remove(String localId) async {
    _records.remove(localId);
    // As the real store: its upload rows go with it.
    uploads.removeWhere((key, _) => key.startsWith('$localId/'));
    removed.add(localId);
  }

  final removed = <String>{};

  @override
  Future<void> removeMany(Iterable<String> localIds) async {
    for (final id in localIds.toList()) {
      await remove(id);
    }
  }

  @override
  Future<Set<String>> removedIds() async => {...removed};

  @override
  Future<void> forgetRemoved(Iterable<String> localIds) async {
    removed.removeAll(localIds);
    merged.removeWhere((id, _) => localIds.contains(id));
  }

  @override
  Future<void> setSourcePath(String localId, String value) async {
    final existing = _records[localId];
    if (existing == null) return;
    _records[localId] = existing.withSourcePath(value, DateTime.now());
  }

  @override
  Future<void> setThumbnailPath(String localId, String? value) async {
    final existing = _records[localId];
    if (existing == null) return;
    _records[localId] = existing.withThumbnailPath(value);
  }

  @override
  Future<void> setLocalDeleted(String localId, bool value) async {
    final existing = _records[localId];
    if (existing == null) return;
    _records[localId] = existing.withLocalDeleted(value);
  }

  @override
  Future<void> setFavorite(String localId, bool value) async {
    final existing = _records[localId];
    if (existing == null) return;
    _records[localId] = existing.withFavorite(value);
  }

  @override
  Future<void> setLocked(String localId, bool value) async {
    final existing = _records[localId];
    if (existing == null) return;
    _records[localId] = existing.withLocked(value);
  }

  @override
  Future<void> setLocalOptimized(String localId, bool value) async {
    final existing = _records[localId];
    if (existing == null) return;
    _records[localId] = existing.withLocalOptimized(value);
  }

  @override
  Future<void> setHidden(String localId, bool value) async {
    final existing = _records[localId];
    if (existing == null) return;
    _records[localId] = existing.withHidden(value);
  }

  @override
  Future<void> softDelete(String localId, {bool byLibrary = false}) async {
    final existing = _records[localId];
    if (existing == null) return;
    _legacyBinned.remove(localId);
    _records[localId] = existing.withDeletedAt(
      DateTime.now(),
      byLibrary: byLibrary,
    );
  }

  /// Back-dates a bin entry, keeping who binned it.
  void binnedAt(String localId, DateTime at) {
    final existing = _records[localId];
    if (existing == null) return;
    _records[localId] = existing.withDeletedAt(
      at,
      byLibrary: existing.binnedByLibrary,
    );
  }

  @override
  Future<void> restore(String localId) async {
    final existing = _records[localId];
    if (existing == null) return;
    _legacyBinned.remove(localId);
    _records[localId] = existing.withDeletedAt(null);
  }

  /// Bin entries from before `binned_by`: who binned them is unknown.
  final _legacyBinned = <String>{};

  void binLegacy(String localId) {
    final existing = _records[localId];
    if (existing == null) return;
    _legacyBinned.add(localId);
    _records[localId] = existing.withDeletedAt(DateTime.now());
  }

  @override
  Future<bool> unbinListed(String localId) async {
    final existing = _records[localId];
    if (existing == null ||
        !existing.isDeleted ||
        existing.passcodeHash != null ||
        !(existing.binnedByLibrary || _legacyBinned.contains(localId))) {
      return false;
    }
    await restore(localId);
    return true;
  }

  @override
  Future<void> setCreatedAt(String localId, DateTime value) async {
    final existing = _records[localId];
    if (existing == null) return;
    _records[localId] = existing.withCreatedAt(value);
  }

  @override
  Future<void> setDescription(String localId, String value) async {
    final existing = _records[localId];
    if (existing == null) return;
    _records[localId] = existing.withDescription(value);
  }

  @override
  Future<void> setTags(String localId, List<String> value) async {
    final existing = _records[localId];
    if (existing == null) return;
    _records[localId] = existing.withTags(value);
  }

  @override
  Future<void> setLibraryId(String localId, String? value) async {
    final existing = _records[localId];
    if (existing == null) return;
    _records[localId] = existing.withLibraryId(value);
  }

  @override
  Future<AssetRecord?> getByLibraryId(String libraryId) async {
    for (final record in _records.values) {
      if (record.libraryId == libraryId) return record;
    }
    for (final record in _records.values) {
      if (record.libraryId == null && record.localId == 'photo:$libraryId') {
        return record;
      }
    }
    return null;
  }

  final swaps = <String, PendingSwap>{};

  @override
  Future<bool> fileSwap(PendingSwap swap) async {
    _maybeCrash('fileSwap');
    if (swaps.containsKey(swap.localId)) return false;
    swaps[swap.localId] = swap;
    return true;
  }

  @override
  Future<List<PendingSwap>> pendingSwaps() async => [...swaps.values];

  @override
  Future<int> pendingSwapCount() async => swaps.length;

  @override
  Future<void> markSwapsProved(Iterable<String> localIds) async {
    for (final id in localIds) {
      final s = swaps[id];
      if (s == null) continue;
      swaps[id] = PendingSwap(
        localId: s.localId,
        oldAsset: s.oldAsset,
        newAsset: s.newAsset,
        keeperId: s.keeperId,
        flag: s.flag,
        keepNew: s.keepNew,
        width: s.width,
        height: s.height,
        oldBytes: s.oldBytes,
        newBytes: s.newBytes,
        provedAt: DateTime.now(),
      );
    }
  }

  @override
  Future<void> dropSwaps(Iterable<String> localIds) async {
    for (final id in localIds) {
      swaps.remove(id);
    }
  }

  @override
  Future<void> binSwapped(String localId) async {
    _maybeCrash('binSwapped');
    await softDelete(localId);
    swaps.remove(localId);
  }

  @override
  Future<bool> adoptAsset(
    String localId,
    String libraryId, {
    int? width,
    int? height,
    bool optimized = false,
    bool closeSwap = false,
  }) async {
    _maybeCrash('adopt');
    var keeper = _records[localId];
    if (keeper == null) return false;
    final holders = [
      for (final r in _records.values)
        if (r.libraryId == libraryId && r.localId != localId) r,
    ];
    if (holders.any((h) => h.passcodeHash != null || h.isLocked)) {
      return false;
    }
    for (final h in holders) {
      keeper = keeper!
          .withTags({...keeper.tags, ...h.tags}.toList())
          .withFavorite(keeper.isFavorite || h.isFavorite);
      if (keeper.description.isEmpty) {
        keeper = keeper.withDescription(h.description);
      }
      await remove(h.localId);
      merged[h.localId] = localId;
    }
    keeper = keeper!.withLibraryId(libraryId);
    if (optimized) keeper = keeper.withLocalOptimized(true);
    _records[localId] = keeper;
    await setLibraryMetadata(localId, width: width, height: height);
    if (closeSwap) swaps.remove(localId);
    return true;
  }

  final merged = <String, String>{};

  /// Restored rows waiting for their asset, as the real `relink_pending`.
  final relinkPending = <String, DateTime>{};

  @override
  Future<void> markRelinkPending(String localId, DateTime createdAt) async {
    relinkPending[localId] = createdAt;
  }

  @override
  Future<void> clearRelinkPending([String? localId]) async {
    if (localId == null) {
      relinkPending.clear();
    } else {
      relinkPending.remove(localId);
    }
  }

  static bool _fits(AssetRecord r, bool isVideo, int? width, int? height) =>
      r.isVideo == isVideo &&
      (r.width == null || width == null || r.width == width) &&
      (r.height == null || height == null || r.height == height);

  @override
  Future<AssetRecord?> relinkCandidate({
    required DateTime createdAt,
    required bool isVideo,
    int? width,
    int? height,
  }) async {
    final fits = [
      for (final MapEntry(key: id, value: at) in relinkPending.entries)
        if (at == createdAt &&
            _records[id] != null &&
            _fits(_records[id]!, isVideo, width, height))
          _records[id]!,
    ];
    return fits.length == 1 ? fits.single : null;
  }

  @override
  Future<AssetRecord?> scannedTwin({
    required DateTime createdAt,
    required bool isVideo,
    required String except,
    int? width,
    int? height,
  }) async {
    final fits = [
      for (final r in _records.values)
        if (r.createdAt == createdAt &&
            r.localId != except &&
            r.libraryId != null &&
            r.sourceType == AssetSourceType.photoManager &&
            !relinkPending.containsKey(r.localId) &&
            _fits(r, isVideo, width, height))
          r,
    ];
    return fits.length == 1 ? fits.single : null;
  }

  @override
  Future<Map<String, String>> mergedInto() async => {...merged};

  @override
  Future<Map<String, AssetRecord>> getByLocalIds(
    Iterable<String> localIds,
  ) async => {for (final id in localIds) id: ?_records[id]};

  @override
  Future<Map<String, AssetRecord>> getByLibraryIds(
    Iterable<String> libraryIds,
  ) async => {for (final id in libraryIds) id: ?await getByLibraryId(id)};

  final _appState = <String, String>{};

  @override
  Future<String?> getAppState(String key) async => _appState[key];

  @override
  Future<void> setAppState(String key, String value) async =>
      _appState[key] = value;

  final _placeNames = <String, PlaceNameEntry>{};

  @override
  Future<void> setLibraryMetadata(
    String localId, {
    double? latitude,
    double? longitude,
    int? width,
    int? height,
  }) async {
    final existing = _records[localId];
    if (existing == null) return;
    // Matches the real store's SQL: a null argument leaves the column
    // alone, a non-null one *writes*. `AssetRecord.withLibraryMetadata`
    // fills blanks only, which is a call-site rule, not this one's.
    _records[localId] = AssetRecord(
      localId: existing.localId,
      contentHash: existing.contentHash,
      platform: existing.platform,
      createdAt: existing.createdAt,
      updatedAt: DateTime.now(),
      sourceType: existing.sourceType,
      sourcePath: existing.sourcePath,
      thumbnailPath: existing.thumbnailPath,
      localDeleted: existing.localDeleted,
      isVideo: existing.isVideo,
      isLivePhoto: existing.isLivePhoto,
      isGif: existing.isGif,
      addedAt: existing.addedAt,
      derivatives: existing.derivatives,
      isFavorite: existing.isFavorite,
      isHidden: existing.isHidden,
      isLocked: existing.isLocked,
      localOptimized: existing.localOptimized,
      deletedAt: existing.deletedAt,
      binnedByLibrary: existing.binnedByLibrary,
      description: existing.description,
      tags: existing.tags,
      location: existing.location,
      passcodeHash: existing.passcodeHash,
      latitude: latitude ?? existing.latitude,
      longitude: longitude ?? existing.longitude,
      width: width ?? existing.width,
      height: height ?? existing.height,
      libraryId: existing.libraryId,
    );
  }

  @override
  Future<List<AssetRecord>> listAwaitingPlaceName({int limit = 200}) async =>
      _records.values
          .where(
            (r) =>
                r.hasCoordinates &&
                (r.location == null || r.location!.isEmpty) &&
                !r.isDeleted,
          )
          .take(limit)
          .toList();

  @override
  Future<PlaceNameEntry?> cachedPlaceName(String cell) async =>
      _placeNames[cell];

  @override
  Future<void> cachePlaceName(String cell, String? name) async =>
      _placeNames[cell] = PlaceNameEntry(name);

  @override
  Future<void> setLocation(String localId, String? value) async {
    final existing = _records[localId];
    if (existing == null) return;
    _records[localId] = existing.withLocation(value);
  }

  @override
  Future<Set<String>> allLocations() async => _records.values
      .map((r) => r.location)
      .whereType<String>()
      .where((l) => l.isNotEmpty)
      .toSet();

  @override
  Future<Set<String>> allTags() async =>
      _records.values.expand((r) => r.tags).toSet();

  @override
  Future<void> setPasscodeHash(String localId, String? value) async {
    final existing = _records[localId];
    if (existing == null) return;
    _records[localId] = existing.withPasscodeHash(value);
  }

  @override
  Future<void> setLivePhoto(String localId, bool value) async {
    final existing = _records[localId];
    if (existing == null) return;
    _records[localId] = existing.withLivePhoto(value);
  }

  @override
  Future<Set<String>> passcodeHashes() async => {
    for (final r in _records.values) ?r.passcodeHash,
  };

  @override
  Future<List<AssetRecord>> forPasscodeHash(String hash) async =>
      _records.values.where((r) => r.passcodeHash == hash).toList()
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt));

  /// No log: these fakes are maps. `LocalVault` reads it as "nothing to
  /// snapshot".
  /// Settable, so a test can say "something changed" without arranging a
  /// write for every table the real triggers watch.
  var mark = 0;

  @override
  Future<int> changeMark() async => mark;

  /// `localId/kind` → `targetId` → `(key, hash)`.
  final uploads = <String, Map<String, ({String key, String? hash})>>{};

  @override
  Future<Map<String, String>> targetsHolding(
    String localId,
    DerivativeKind kind, {
    String? sourceHash,
  }) async => {
    for (final entry in (uploads['$localId/${kind.name}'] ?? const {}).entries)
      if (sourceHash == null || entry.value.hash == sourceHash)
        entry.key: entry.value.key,
  };

  @override
  Future<void> recordUpload({
    required String localId,
    required DerivativeKind kind,
    required String targetId,
    required String destinationKey,
    String? sourceHash,
  }) async {
    (uploads['$localId/${kind.name}'] ??= {})[targetId] = (
      key: destinationKey,
      hash: sourceHash,
    );
    final edits = bucketEdits[targetId];
    if (edits != null &&
        edits.containsKey(destinationKey) &&
        edits[destinationKey] == null) {
      edits.remove(destinationKey);
    }
  }

  final bucketObjects = <String, List<BucketObject>>{};

  /// Records are replaced, never changed in place: their identities are
  /// the revision.
  @override
  Future<int> revision() async =>
      Object.hashAll([for (final r in _records.values) identityHashCode(r)]);

  @override
  Future<String> bucketStamp() async => Object.hashAll([
    for (final MapEntry(:key, :value) in bucketObjects.entries)
      for (final o in value) Object.hash(key, o.key, o.size, o.lastModified),
    for (final MapEntry(:key, :value) in uploads.entries)
      for (final e in value.entries) Object.hash(key, e.key, e.value.key),
  ]).toString();

  @override
  Future<void> replaceBucketObjects(
    String targetId,
    List<BucketObject> objects,
  ) async {
    bucketObjects[targetId] = objects;
    bucketEdits.remove(targetId);
  }

  /// As the real store's `bucket_edit`: null is a key gone.
  final bucketEdits = <String, Map<String, BucketObject?>>{};

  @override
  Future<void> forgetBucketListing(String targetId) async {
    bucketObjects.remove(targetId);
    bucketEdits.remove(targetId);
  }

  @override
  Future<bool> isListed(String targetId, String key) async =>
      (bucketObjects[targetId] ?? const <BucketObject>[]).any(
        (o) => o.key == key,
      );

  @override
  Future<List<String>> listedSiblings(String targetId, String key) async => [
    for (final o in bucketObjects[targetId] ?? const <BucketObject>[])
      if (o.key != key &&
          p.posix.withoutExtension(o.key) == p.posix.withoutExtension(key))
        o.key,
  ];

  @override
  Future<void> forgetBucketObject(String targetId, String key) async {
    bucketObjects[targetId]?.removeWhere((o) => o.key == key);
    (bucketEdits[targetId] ??= {})[key] = null;
  }

  @override
  Future<void> moveBucketObject(BucketObject from, BucketObject to) async {
    bucketObjects[from.targetId]?.removeWhere((o) => o.key == from.key);
    (bucketObjects[to.targetId] ??= [])
      ..removeWhere((o) => o.key == to.key)
      ..add(to);
    (bucketEdits[from.targetId] ??= {})[from.key] = null;
    (bucketEdits[to.targetId] ??= {})[to.key] = to;
  }

  final bucketScans = <String, Map<String, String?>>{};
  final bucketStaged = <String, Map<String, BucketObject>>{};

  @override
  Future<({String? token, bool done})?> bucketScanProgress(
    String targetId,
    String dir,
  ) async {
    final scan = bucketScans[targetId];
    if (scan == null || !scan.containsKey(dir)) return null;
    return (token: scan[dir], done: scan[dir] == null);
  }

  @override
  Future<void> stageBucketPage(
    String targetId,
    String dir,
    String? nextToken,
    List<BucketObject> objects,
  ) async {
    (bucketScans[targetId] ??= {})[dir] = nextToken;
    final staged = bucketStaged[targetId] ??= {};
    for (final o in objects) {
      staged[o.key] = o;
    }
  }

  @override
  Future<void> commitBucketScan(String targetId) async {
    final listed = {...?bucketStaged[targetId]};
    for (final MapEntry(:key, :value)
        in (bucketEdits.remove(targetId) ?? {}).entries) {
      if (value == null) {
        listed.remove(key);
      } else {
        listed[key] = value;
      }
    }
    bucketObjects[targetId] = [...listed.values];
    await discardBucketScan(targetId);
  }

  @override
  Future<void> discardBucketScan(String targetId) async {
    bucketScans.remove(targetId);
    bucketStaged.remove(targetId);
  }

  @override
  Future<Set<String>> bucketTargetIds() async => {
    for (final e in bucketObjects.entries)
      if (e.value.isNotEmpty) e.key,
  };

  @override
  Future<List<BucketObject>> listBucketObjects() async => [
    for (final list in bucketObjects.values) ...list,
  ];

  @override
  Future<Set<String>> referencedKeys() async => {
    for (final r in _records.values)
      for (final kind in DerivativeKind.values) ?r.stateOf(kind).destinationKey,
    for (final upload in uploads.values)
      for (final entry in upload.values) entry.key,
  };

  @override
  Future<void> renameUploadKey({
    required String localId,
    required DerivativeKind kind,
    required String targetId,
    required String destinationKey,
  }) async {
    final row = uploads['$localId/${kind.name}']?[targetId];
    if (row != null) {
      uploads['$localId/${kind.name}']![targetId] = (
        key: destinationKey,
        hash: row.hash,
      );
    }
  }

  @override
  Future<void> forgetUploads(String localId) async {
    uploads.removeWhere((key, _) => key.startsWith('$localId/'));
  }

  /// Set to make [clearAll] throw — the one step of a wipe whose failure
  /// must not strand the steps after it.
  var throwOnClear = false;

  /// Mirrors the real store: `app_state` and the place-name cache go with
  /// the records. A wipe that left the bookkeeping behind would hide the
  /// very thing [AppDataRemoval] exists to handle.
  @override
  Future<void> clearAll() async {
    if (throwOnClear) throw StateError('database unavailable');
    _records.clear();
    _appState.clear();
    _placeNames.clear();
    swaps.clear();
    relinkPending.clear();
  }

  @override
  Future<List<Map<String, Object?>>> changeLogRows() async => const [];

  final hiddenNotes = <String, Map<String, Object?>>{};

  @override
  Future<List<Map<String, Object?>>> hiddenNoteRows(String albumTag) async =>
      hiddenNotes.values.where((r) => r['album_tag'] == albumTag).toList()
        ..sort(
          (a, b) => (b['created_at'] as int).compareTo(a['created_at'] as int),
        );

  @override
  Future<void> putHiddenNote({
    required String id,
    required String albumTag,
    required String payload,
    required DateTime createdAt,
    required DateTime updatedAt,
  }) async {
    hiddenNotes[id] = {
      'id': id,
      'album_tag': albumTag,
      'payload': payload,
      'created_at': createdAt.millisecondsSinceEpoch,
      'updated_at': updatedAt.millisecondsSinceEpoch,
    };
  }

  @override
  Future<void> removeHiddenNote(String id) async => hiddenNotes.remove(id);

  final heldNames = <String, String>{};

  @override
  Future<int> retag(String from, String to) async {
    var moved = 0;
    for (final r in _records.values.toList()) {
      if (r.passcodeHash != from) continue;
      _records[r.localId] = r.withPasscodeHash(to);
      moved++;
    }
    return moved;
  }

  @override
  Future<List<AssetRecord>> hiddenRecords() async => [
    for (final r in _records.values)
      if (r.passcodeHash != null) r,
  ];

  @override
  Future<Set<String>> hiddenIds() async => {
    for (final r in _records.values)
      if (r.passcodeHash != null) r.localId,
  };

  @override
  Future<void> moveSourcePath(
    String localId,
    String path, {
    String? heldName,
    bool clearHeld = false,
  }) async {
    await setSourcePath(localId, path);
    if (heldName != null) heldNames[localId] = heldName;
    if (clearHeld) heldNames.remove(localId);
  }

  @override
  Future<String?> heldNameOf(String localId) async => heldNames[localId];

  @override
  Future<bool> sourcePathShared(String path, String localId) async =>
      _records.values.any((r) => r.localId != localId && r.sourcePath == path);

  @override
  Future<List<String>> plainIdsUnder(String dir) async => [
    for (final r in _records.values)
      if (r.passcodeHash == null &&
          (r.sourcePath?.startsWith('$dir/') ?? false))
        r.localId,
  ];

  @override
  Future<List<Map<String, Object?>>> allHiddenNoteRows() async => [
    ...hiddenNotes.values,
  ];

  @override
  Future<void> restoreHiddenNote(Map<String, Object?> row) async {
    final id = row['id'];
    if (id is String) hiddenNotes.putIfAbsent(id, () => {...row});
  }

  @override
  Future<bool> copyTo(String dest) async => false;
}
