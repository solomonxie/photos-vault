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
    Future<List<String>> Function(List<String> ids)? deleteAssets,
  }) : _requestPermission =
           requestPermission ?? (() => PhotoManager.requestPermissionExtend()),
       _listAllAssets = listAllAssets ?? _defaultListAllAssets,
       _loadEntity = loadEntity ?? AssetEntity.fromId,
       _deleteAssets = deleteAssets ?? _defaultDeleteAssets;

  final AssetRecordStore store;
  final Future<PermissionState> Function() _requestPermission;
  final Future<List<AssetEntity>> Function() _listAllAssets;
  final Future<AssetEntity?> Function(String id) _loadEntity;

  /// Overridable for tests so they never really delete from the OS library.
  final Future<List<String>> Function(List<String> ids) _deleteAssets;

  static Future<List<String>> _defaultDeleteAssets(List<String> ids) =>
      PhotoManager.editor.deleteWithIds(ids);

  static const _pageSize = 200;

  /// Metadata-only pull of the whole camera roll, paginated — no `.file`/
  /// thumbnail bytes touched here, so no iCloud downloads triggered.
  static Future<List<AssetEntity>> _defaultListAllAssets() async {
    final paths = await PhotoManager.getAssetPathList(
      type: RequestType.common,
      onlyAll: true,
    );
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

  static String? entityIdFrom(String localId) => localId.startsWith(_idPrefix)
      ? localId.substring(_idPrefix.length)
      : null;

  Future<PhotoLibraryAccess> requestAccess() async {
    final state = await _requestPermission();
    if (state.isAuth) return PhotoLibraryAccess.granted;
    if (state == PermissionState.limited) return PhotoLibraryAccess.limited;
    return PhotoLibraryAccess.denied;
  }

  /// Pulls every camera-roll asset and upserts it into [store] as a
  /// `photoManager`-sourced record — a no-op for ones already tracked,
  /// except for the favourite flag: Photos owns that for its own assets, so
  /// a heart added over there shows up here on the next scan. The reverse
  /// direction is [setFavoriteInLibrary].
  Future<List<AssetRecord>> syncAll() async {
    final entities = await _listAllAssets();
    final added = <AssetRecord>[];
    for (final entity in entities) {
      final localId = localIdFor(entity);
      final existing = await store.getByLocalId(localId);
      if (existing != null) {
        if (existing.isFavorite != entity.isFavorite) {
          await store.setFavorite(localId, entity.isFavorite);
        }
        continue;
      }
      final record = await store.upsert(
        localId: localId,
        contentHash: entity.id,
        platform: Platform.isIOS ? 'ios' : 'android',
        sourceType: AssetSourceType.photoManager,
        isVideo: entity.type == AssetType.video,
        isLivePhoto: entity.isLivePhoto,
        createdAt: entity.createDateTime,
      );
      if (entity.isFavorite) await store.setFavorite(localId, true);
      added.add(entity.isFavorite ? record.withFavorite(true) : record);
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

  /// Deletes [record] from the OS photo library itself — this app never
  /// keeps its own copy of a camera-roll asset, so this is the only way to
  /// reclaim its device storage. iOS prompts for confirmation and moves it
  /// to the system's own Recently Deleted; returns whether it actually
  /// went (false if the user declined the prompt, or it wasn't ours to
  /// delete).
  Future<bool> deleteFromLibrary(AssetRecord record) async {
    final id = entityIdFrom(record.localId);
    if (id == null) return false;
    final deleted = await _deleteAssets([id]);
    return deleted.contains(id);
  }

  /// Mirrors a favourite back into the OS photo library, so a heart set
  /// here is the same heart Photos shows. Silently does nothing for
  /// anything that isn't a camera-roll asset — a manually-added file has no
  /// entry over there to mark.
  ///
  /// Best-effort by design: this is a nicety on top of a change that's
  /// already saved locally, so a refused write (permission dropped to
  /// limited access, asset deleted since) must not fail the user's tap.
  static Future<void> setFavoriteInLibrary(
    AssetRecord record,
    bool isFavorite,
  ) async {
    final entity = await _entityOf(record);
    if (entity == null) return;
    try {
      if (Platform.isIOS || Platform.isMacOS) {
        await PhotoManager.editor.darwin.favoriteAsset(
          entity: entity,
          favorite: isFavorite,
        );
      } else if (Platform.isAndroid) {
        await PhotoManager.editor.android.favoriteAsset(
          entity: entity,
          favorite: isFavorite,
        );
      }
    } catch (_) {
      // See above.
    }
  }

  /// Same deal for a corrected date/time: PhotoKit's `creationDate` is
  /// writable, so "Adjust Date" here moves the photo in Photos' own
  /// timeline too rather than leaving the two disagreeing.
  static Future<void> setCreatedAtInLibrary(
    AssetRecord record,
    DateTime createdAt,
  ) async {
    final entity = await _entityOf(record);
    if (entity == null) return;
    try {
      if (Platform.isIOS || Platform.isMacOS) {
        await PhotoManager.editor.darwin.updateCreationDate(
          entity: entity,
          creationDate: createdAt,
        );
      } else if (Platform.isAndroid) {
        await PhotoManager.editor.android.updateCreationDate(
          entity: entity,
          creationDate: createdAt,
        );
      }
    } catch (_) {
      // See [setFavoriteInLibrary].
    }
  }

  static Future<AssetEntity?> _entityOf(AssetRecord record) async {
    if (record.sourceType != AssetSourceType.photoManager) return null;
    final id = entityIdFrom(record.localId);
    if (id == null) return null;
    try {
      return await AssetEntity.fromId(id);
    } catch (_) {
      return null;
    }
  }

  /// The paired video half of a Live Photo, for hold-to-play in the
  /// viewer — `null` for a still, for a non-camera-roll asset, or when the
  /// video component can't be materialised (not downloaded from iCloud,
  /// Android). Asking for the origin *with* the subtype is what makes
  /// `photo_manager` hand back the `.mov` rather than the still frame.
  static Future<File?> resolveLivePhotoVideo(AssetRecord record) async {
    final id = entityIdFrom(record.localId);
    if (id == null) return null;
    final entity = await AssetEntity.fromId(id);
    if (entity == null || !entity.isLivePhoto) return null;
    return entity.originFileWithSubtype;
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
