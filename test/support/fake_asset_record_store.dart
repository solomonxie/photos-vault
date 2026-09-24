import 'dart:io';

import 'package:photos_vault/storage/asset_record.dart';
import 'package:photos_vault/storage/asset_record_store.dart';

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
    double? latitude,
    double? longitude,
    int? width,
    int? height,
    String? libraryId,
  }) async {
    final existing = _records[localId];
    if (existing != null) return existing;
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
      createdAt: now,
      updatedAt: now,
    );
    _records[localId] = record;
    return record;
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

  @override
  Future<List<AssetRecord>> listAll() async =>
      _records.values.toList()
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt));

  @override
  Future<void> remove(String localId) async => _records.remove(localId);

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
  Future<void> softDelete(String localId) async {
    final existing = _records[localId];
    if (existing == null) return;
    _records[localId] = existing.withDeletedAt(DateTime.now());
  }

  @override
  Future<void> restore(String localId) async {
    final existing = _records[localId];
    if (existing == null) return;
    _records[localId] = existing.withDeletedAt(null);
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
      if (record.libraryId == null && record.localId == 'photo:$libraryId') {
        return record;
      }
    }
    return null;
  }

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
      derivatives: existing.derivatives,
      isFavorite: existing.isFavorite,
      isHidden: existing.isHidden,
      deletedAt: existing.deletedAt,
      description: existing.description,
      tags: existing.tags,
      location: existing.location,
      event: existing.event,
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
  Future<void> setEvent(String localId, String? value) async {
    final existing = _records[localId];
    if (existing == null) return;
    _records[localId] = existing.withEvent(value);
  }

  @override
  Future<Set<String>> allEvents() async => _records.values
      .map((r) => r.event)
      .whereType<String>()
      .where((e) => e.isNotEmpty)
      .toSet();

  @override
  Future<void> setPasscodeHash(String localId, String? value) async {
    final existing = _records[localId];
    if (existing == null) return;
    _records[localId] = existing.withPasscodeHash(value);
  }

  @override
  Future<List<AssetRecord>> forPasscodeHash(String hash) async =>
      _records.values.where((r) => r.passcodeHash == hash).toList()
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt));

  /// No file and no log: these fakes are maps, and the tier-1 copy has
  /// nothing to copy. `LocalVault` treats both as "nothing to snapshot".
  @override
  Future<File?> checkpointedFile() async => null;

  /// Settable, so a test can say "something changed" without arranging a
  /// write for every table the real triggers watch.
  var mark = 0;

  @override
  Future<int> changeMark() async => mark;

  @override
  Future<void> clearAll() async => _records.clear();

  @override
  Future<List<Map<String, Object?>>> changeLogRows() async => const [];
}
