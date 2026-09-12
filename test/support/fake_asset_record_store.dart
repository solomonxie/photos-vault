import 'package:back_your_own_photos/storage/asset_record.dart';
import 'package:back_your_own_photos/storage/asset_record_store.dart';

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
  }) async {
    final existing = _records[localId];
    if (existing != null) return existing;
    final now = DateTime.now();
    final record = AssetRecord(
      localId: localId,
      contentHash: contentHash,
      platform: platform,
      sourceType: sourceType,
      sourcePath: sourcePath,
      createdAt: now,
      updatedAt: now,
    );
    _records[localId] = record;
    return record;
  }

  @override
  Future<AssetRecord?> getByLocalId(String localId) async => _records[localId];

  @override
  Future<void> updateDerivative(String localId, DerivativeKind kind, DerivativeState state) async {
    final existing = _records[localId];
    if (existing == null) return;
    _records[localId] = existing.withDerivative(kind, state);
  }

  @override
  Future<List<AssetRecord>> listAll() async =>
      _records.values.toList()..sort((a, b) => a.createdAt.compareTo(b.createdAt));
}
