import 'dart:io';

import 'package:photo_manager/photo_manager.dart';

import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';

enum PhotoLibraryAccess { granted, limited, denied }

/// Bridges the OS photo library (via `photo_manager`) into `asset_record` —
/// the real camera-roll source, alongside manually-added/demo files. See
/// IMPLEMENTATION_PLAN.md T2.1.
///
/// `AssetEntity`s aren't stored directly — only their id, as
/// `AssetSourceType.photoManager` records with no `sourcePath` — so
/// thumbnails/originals are always resolved on demand via [entityFor]/
/// [fileFor]. That keeps `syncAll` cheap (metadata only, no iCloud
/// downloads) even for a large library.
class PhotoLibraryService {
  PhotoLibraryService({
    required this.store,
    Future<PermissionState> Function()? requestPermission,
    Future<List<AssetEntity>> Function()? listAllAssets,
    Future<AssetEntity?> Function(String id)? loadEntity,
  }) : _requestPermission = requestPermission ?? (() => PhotoManager.requestPermissionExtend()),
       _listAllAssets = listAllAssets ?? _defaultListAllAssets,
       _loadEntity = loadEntity ?? AssetEntity.fromId;

  final AssetRecordStore store;
  final Future<PermissionState> Function() _requestPermission;
  final Future<List<AssetEntity>> Function() _listAllAssets;
  final Future<AssetEntity?> Function(String id) _loadEntity;

  static const _pageSize = 200;

  /// Metadata-only pull of the whole camera roll, paginated — no `.file`/
  /// thumbnail bytes touched here, so no iCloud downloads triggered.
  static Future<List<AssetEntity>> _defaultListAllAssets() async {
    final paths = await PhotoManager.getAssetPathList(type: RequestType.common, onlyAll: true);
    if (paths.isEmpty) return const [];
    final all = paths.first;
    final total = await all.assetCountAsync;
    final entities = <AssetEntity>[];
    for (var page = 0; page * _pageSize < total; page++) {
      entities.addAll(await all.getAssetListPaged(page: page, size: _pageSize));
    }
    return entities;
  }

  static const _idPrefix = 'photo:';

  static String localIdFor(AssetEntity entity) => '$_idPrefix${entity.id}';

  static String? entityIdFrom(String localId) => localId.startsWith(_idPrefix) ? localId.substring(_idPrefix.length) : null;

  Future<PhotoLibraryAccess> requestAccess() async {
    final state = await _requestPermission();
    if (state.isAuth) return PhotoLibraryAccess.granted;
    if (state == PermissionState.limited) return PhotoLibraryAccess.limited;
    return PhotoLibraryAccess.denied;
  }

  /// Pulls every camera-roll asset and upserts it into [store] as a
  /// `photoManager`-sourced record — a no-op for ones already tracked.
  Future<List<AssetRecord>> syncAll() async {
    final entities = await _listAllAssets();
    final added = <AssetRecord>[];
    for (final entity in entities) {
      added.add(
        await store.upsert(
          localId: localIdFor(entity),
          contentHash: entity.id,
          platform: Platform.isIOS ? 'ios' : 'android',
          sourceType: AssetSourceType.photoManager,
          isVideo: entity.type == AssetType.video,
          createdAt: entity.createDateTime,
        ),
      );
    }
    return added;
  }

  /// Resolves a `photoManager` record back to its [AssetEntity], or null if
  /// it's been deleted from the library since, or [record] isn't
  /// `photoManager`-sourced.
  Future<AssetEntity?> entityFor(AssetRecord record) {
    final id = entityIdFrom(record.localId);
    if (id == null) return Future.value(null);
    return _loadEntity(id);
  }

  /// Resolves the actual file on disk for [record] — used to feed the
  /// backup pipeline, which only understands file paths. Triggers an iCloud
  /// download on iOS if the original isn't on-device yet, so can be slow.
  Future<File?> fileFor(AssetRecord record) async {
    final entity = await entityFor(record);
    return entity?.file;
  }

  /// Same resolution as [fileFor], without needing a [PhotoLibraryService]
  /// instance (a [store] to construct one) — for read-only call sites like
  /// the detail viewer that only ever look up, never sync.
  static Future<File?> resolveFile(AssetRecord record) async {
    final id = entityIdFrom(record.localId);
    if (id == null) return null;
    final entity = await AssetEntity.fromId(id);
    return entity?.file;
  }
}
