import 'dart:io';

import 'package:photo_manager/photo_manager.dart';

import '../storage/asset_record.dart';
import 'photo_library_change.dart';
import '../storage/asset_record_store.dart';

enum PhotoLibraryAccess { granted, limited, denied }

/// What one [PhotoLibraryService.syncAll] pass found.
///
/// [added] is what's newly tracked and therefore needs backing up;
/// [updated] counts assets already tracked whose metadata moved underneath
/// us (a heart added or removed over in Photos). Both matter to the caller
/// and they mean different things — a scan that added nothing but updated
/// something still has to redraw.
class PhotoLibrarySyncResult {
  const PhotoLibrarySyncResult({this.added = const [], this.updated = 0});

  final List<AssetRecord> added;
  final int updated;

  bool get isEmpty => added.isEmpty && updated == 0;
}

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
  /// [reconcileDeletions] also accounts for assets that have *gone* from
  /// the library since the last scan — see [_reconcileDeletions]. Off by
  /// default, and the caller must only turn it on with full access: under
  /// "Selected Photos" the listing is a handful of assets, and everything
  /// else would look deleted.
  Future<PhotoLibrarySyncResult> syncAll({
    bool reconcileDeletions = false,
  }) async {
    final entities = await _listAllAssets();
    final added = <AssetRecord>[];
    final seen = <String>{};
    var updated = 0;
    for (final entity in entities) {
      final localId = localIdFor(entity);
      seen.add(localId);
      final existing = await store.getByLocalId(localId);
      if (existing != null) {
        if (existing.isFavorite != entity.isFavorite) {
          await store.setFavorite(localId, entity.isFavorite);
          updated++;
        }
        // Back from the OS's own Recently Deleted, or restored some other
        // way: it has a local original again.
        if (existing.localDeleted && existing.sourcePath == null) {
          await store.setLocalDeleted(localId, false);
          if (existing.isDeleted) await store.restore(localId);
          updated++;
        }
        continue;
      }
      added.add(await _insert(entity, localId));
    }
    if (reconcileDeletions) updated += await _reconcileDeletions(seen);
    return PhotoLibrarySyncResult(added: added, updated: updated);
  }

  /// Applies one [PhotoLibraryChange] — the precise set of assets iOS says
  /// were added, altered or removed while we were watching.
  ///
  /// This is the cheap path, and the one that runs almost all the time:
  /// work proportional to what changed rather than to library size, so
  /// keeping up with Photos costs nothing measurable whether the user has
  /// two hundred photos or two hundred thousand. [syncAll] stays as the
  /// backstop for what happened while nobody was watching — notifications
  /// only arrive while the app is running.
  Future<PhotoLibrarySyncResult> applyChange(PhotoLibraryChange change) async {
    final added = <AssetRecord>[];
    var updated = 0;

    for (final id in {...change.created, ...change.updated}) {
      final entity = await _loadEntity(id);
      // Gone again between the notification and now (a burst of edits, or
      // a create-then-delete): the delete pass below, or the next scan,
      // deals with it.
      if (entity == null) continue;
      final localId = localIdFor(entity);
      final existing = await store.getByLocalId(localId);
      if (existing == null) {
        added.add(await _insert(entity, localId));
        continue;
      }
      if (existing.isFavorite != entity.isFavorite) {
        await store.setFavorite(localId, entity.isFavorite);
        updated++;
      }
      if (existing.localDeleted && existing.sourcePath == null) {
        await store.setLocalDeleted(localId, false);
        if (existing.isDeleted) await store.restore(localId);
        updated++;
      }
    }

    for (final id in change.deleted) {
      final record = await store.getByLocalId('$_idPrefix$id');
      if (record == null) continue;
      if (await _markGone(record)) updated++;
    }

    return PhotoLibrarySyncResult(added: added, updated: updated);
  }

  /// Deals with camera-roll records the library no longer has an asset for.
  ///
  /// Never by deleting the row. The row is where this app's own work lives
  /// — captions, tags, people, album membership — and a photo deleted in
  /// Photos can come back out of the OS's 30-day Recently Deleted, at which
  /// point throwing that away would have been unrecoverable. What happens
  /// instead depends on whether the photo was actually backed up, because
  /// that's the difference between "the original moved to the cloud" and
  /// "this is gone":
  ///
  ///  * **backed up** → marked [AssetRecord.localDeleted]: it stays in the
  ///    library as a cloud-only item, drawn from the cached thumbnail, with
  ///    the viewer offering to pull the original back down. This is the
  ///    whole point of the app, and it's the same state "Remove from
  ///    Device" produces.
  ///  * **not backed up** → soft-deleted into this app's own Recently
  ///    Deleted. Nothing about it survives anywhere, so leaving it in the
  ///    main grid would claim it's still yours; binning it keeps the record
  ///    (and its metadata) recoverable without pretending.
  Future<int> _reconcileDeletions(Set<String> seen) async {
    var changed = 0;
    for (final record in await store.listAll()) {
      if (record.sourceType != AssetSourceType.photoManager) continue;
      if (seen.contains(record.localId)) continue;
      if (await _markGone(record)) changed++;
    }
    return changed;
  }

  Future<AssetRecord> _insert(AssetEntity entity, String localId) async {
    final record = await store.upsert(
      localId: localId,
      contentHash: entity.id,
      platform: Platform.isIOS ? 'ios' : 'android',
      sourceType: AssetSourceType.photoManager,
      isVideo: entity.type == AssetType.video,
      isLivePhoto: entity.isLivePhoto,
      createdAt: entity.createDateTime,
    );
    if (!entity.isFavorite) return record;
    await store.setFavorite(localId, true);
    return record.withFavorite(true);
  }

  /// The "no longer in the photo library" rule, shared by the scan and the
  /// change notification. Returns whether anything actually moved.
  Future<bool> _markGone(AssetRecord record) async {
    // Already accounted for, or holding a local copy of its own — an
    // original restored from the bucket lives in app storage, not in the
    // photo library, so its absence there says nothing.
    if (record.isDeleted || record.localDeleted) return false;
    if (record.sourcePath != null) return false;
    final backedUp =
        record.stateOf(DerivativeKind.original).status == UploadStatus.uploaded;
    if (backedUp) {
      await store.setLocalDeleted(record.localId, true);
    } else {
      await store.softDelete(record.localId);
    }
    return true;
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
