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
    Future<List<AssetEntity>> Function(int page, int size)? listAssetPage,
    Future<AssetEntity?> Function(String id)? loadEntity,
    Future<List<String>> Function(List<String> ids)? deleteAssets,
  }) : _requestPermission =
           requestPermission ?? (() => PhotoManager.requestPermissionExtend()),
       _listAssetPage = listAssetPage ?? _defaultListAssetPage,
       _loadEntity = loadEntity ?? AssetEntity.fromId,
       _deleteAssets = deleteAssets ?? _defaultDeleteAssets;

  final AssetRecordStore store;
  final Future<PermissionState> Function() _requestPermission;
  final Future<List<AssetEntity>> Function(int page, int size) _listAssetPage;
  final Future<AssetEntity?> Function(String id) _loadEntity;

  /// Overridable for tests so they never really delete from the OS library.
  final Future<List<String>> Function(List<String> ids) _deleteAssets;

  static Future<List<String>> _defaultDeleteAssets(List<String> ids) =>
      PhotoManager.editor.deleteWithIds(ids);

  static const _pageSize = 200;

  /// One page of the camera roll, **newest first**. Metadata only — no
  /// `.file`/thumbnail bytes touched here, so no iCloud downloads
  /// triggered.
  ///
  /// The order is the whole point. A first scan works backwards from the
  /// most recent photo, so the page the user is actually looking at fills
  /// first and everything after it arrives off-screen, above. Scanning in
  /// library order would put 2011 on screen and then shove it around for a
  /// minute as the rest of the decade landed on top of it.
  static Future<List<AssetEntity>> _defaultListAssetPage(
    int page,
    int size,
  ) async {
    final paths = await PhotoManager.getAssetPathList(
      type: RequestType.common,
      onlyAll: true,
      filterOption: FilterOptionGroup(
        orders: const [
          OrderOption(type: OrderOptionType.createDate, asc: false),
        ],
      ),
    );
    if (paths.isEmpty) return const [];
    return paths.first.getAssetListPaged(page: page, size: size);
  }

  static const _idPrefix = 'photo:';

  static String localIdFor(AssetEntity entity) => '$_idPrefix${entity.id}';

  static String? entityIdFrom(String localId) => localId.startsWith(_idPrefix)
      ? localId.substring(_idPrefix.length)
      : null;

  /// Which asset in the OS photo library [record] currently *is*, or null
  /// if the library hasn't got it.
  ///
  /// [AssetRecord.libraryId] and nothing else. The id inside [localId] is
  /// only ever the id the photo was *first* scanned under: a photo that was
  /// hidden has left the library entirely, and one that came back is a new
  /// asset with a new id, so reading [localId] here would hand out the name
  /// of something PhotoKit destroyed. Rows written before the column
  /// existed are filled in by the schema migration, and the scan's own
  /// lookup ([AssetRecordStore.getByLibraryId]) matches them either way.
  static String? libraryIdOf(AssetRecord record) => record.libraryId;

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
  /// [onPage] is called as each page lands, newest photos first, so the
  /// screen can show the most recent day before the scan has walked back
  /// through the rest of the decade.
  ///
  /// [reconcileDeletions] also accounts for assets that have *gone* from
  /// the library since the last scan — see [_reconcileDeletions]. Off by
  /// default, and the caller must only turn it on with full access: under
  /// "Selected Photos" the listing is a handful of assets, and everything
  /// else would look deleted.
  Future<PhotoLibrarySyncResult> syncAll({
    bool reconcileDeletions = false,
    void Function(PhotoLibrarySyncResult page)? onPage,
  }) async {
    final added = <AssetRecord>[];
    final seen = <String>{};
    var updated = 0;

    // Page by page rather than the whole roll in one go: a decade of photos
    // is hundreds of thousands of entities, and holding them all in memory
    // to loop over once is a spike for nothing. Each page is also a chance
    // to show what's been found — see [onPage].
    for (var page = 0; ; page++) {
      final entities = await _listAssetPage(page, _pageSize);
      if (entities.isEmpty) break;
      final pageAdded = <AssetRecord>[];
      var pageUpdated = 0;
      for (final entity in entities) {
        final localId = localIdFor(entity);
        final existing = await store.getByLibraryId(entity.id);
        seen.add(existing?.localId ?? localId);
        if (existing != null) {
          if (existing.isFavorite != entity.isFavorite) {
            await store.setFavorite(existing.localId, entity.isFavorite);
            pageUpdated++;
          }
          // Back from the OS's own Recently Deleted, or restored some other
          // way: it has a local original again.
          if (existing.localDeleted && existing.sourcePath == null) {
            await store.setLocalDeleted(existing.localId, false);
            if (existing.isDeleted) await store.restore(existing.localId);
            pageUpdated++;
          }
          // Photos tracked before this app started keeping coordinates and
          // pixel sizes: the entity is right here, so the backfill is the
          // scan itself rather than a separate pass over the library.
          if (await _fillLibraryMetadata(existing, entity)) pageUpdated++;
          continue;
        }
        pageAdded.add(await _insert(entity, localId));
      }
      added.addAll(pageAdded);
      updated += pageUpdated;
      onPage?.call(
        PhotoLibrarySyncResult(added: pageAdded, updated: pageUpdated),
      );
      if (entities.length < _pageSize) break;
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
      final existing = await store.getByLibraryId(entity.id);
      if (existing == null) {
        added.add(await _insert(entity, localId));
        continue;
      }
      if (existing.isFavorite != entity.isFavorite) {
        await store.setFavorite(existing.localId, entity.isFavorite);
        updated++;
      }
      if (existing.localDeleted && existing.sourcePath == null) {
        await store.setLocalDeleted(existing.localId, false);
        if (existing.isDeleted) await store.restore(existing.localId);
        updated++;
      }
      if (await _fillLibraryMetadata(existing, entity)) updated++;
    }

    for (final id in change.deleted) {
      final record = await store.getByLibraryId(id);
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
      // A hidden photo is out of the library on purpose — this app took it
      // out itself, and holds the only copy. Nothing to reconcile.
      if (record.libraryId == null && record.sourcePath != null) continue;
      if (await _markGone(record)) changed++;
    }
    return changed;
  }

  Future<AssetRecord> _insert(AssetEntity entity, String localId) async {
    final latLng = _coordinatesOf(entity);
    final record = await store.upsert(
      localId: localId,
      contentHash: entity.id,
      platform: Platform.isIOS ? 'ios' : 'android',
      sourceType: AssetSourceType.photoManager,
      isVideo: entity.type == AssetType.video,
      isLivePhoto: entity.isLivePhoto,
      createdAt: entity.createDateTime,
      libraryId: entity.id,
      latitude: latLng?.latitude,
      longitude: latLng?.longitude,
      width: entity.width > 0 ? entity.width : null,
      height: entity.height > 0 ? entity.height : null,
    );
    if (!entity.isFavorite) return record;
    await store.setFavorite(localId, true);
    return record.withFavorite(true);
  }

  /// Writes anything the library knows and the record doesn't. Blanks
  /// only: a photo whose GPS tag was stripped keeps the coordinates it was
  /// scanned with rather than losing them to a re-scan.
  Future<bool> _fillLibraryMetadata(
    AssetRecord record,
    AssetEntity entity,
  ) async {
    final latLng = record.hasCoordinates ? null : _coordinatesOf(entity);
    final width = record.width == null && entity.width > 0
        ? entity.width
        : null;
    final height = record.height == null && entity.height > 0
        ? entity.height
        : null;
    if (latLng == null && width == null && height == null) return false;
    await store.setLibraryMetadata(
      record.localId,
      latitude: latLng?.latitude,
      longitude: latLng?.longitude,
      width: width,
      height: height,
    );
    return true;
  }

  /// What the library entry already carries, taken while the scan has it
  /// in hand — it costs nothing here and saves asking the OS again later,
  /// one photo at a time, for something it told us the first time.
  ///
  /// The synchronous reading only. On iOS that's `PHAsset.location`, which
  /// arrives with the asset; on Android GPS lives in the file's EXIF and
  /// only `latlngAsync` digs it out, which means reading the file — so
  /// there it stays a lazy, on-view lookup (`PhotoLocationService`).
  static LatLng? _coordinatesOf(AssetEntity entity) {
    final latLng = entity.latLng;
    if (latLng == null) return null;
    // A photo with no location tag reads back as 0,0 rather than null —
    // and Null Island is nobody's holiday.
    if (latLng.latitude == 0 && latLng.longitude == 0) return null;
    return latLng;
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
    final id = libraryIdOf(record);
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
    final id = libraryIdOf(record);
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
    final id = libraryIdOf(record);
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
    final id = libraryIdOf(record);
    if (id == null) return null;
    final entity = await AssetEntity.fromId(id);
    if (entity == null || !entity.isLivePhoto) return null;
    return entity.originFileWithSubtype;
  }

  /// Same resolution as [fileFor], without needing a [PhotoLibraryService]
  /// instance (a [store] to construct one) — for read-only call sites like
  /// the detail viewer that only ever look up, never sync.
  static Future<File?> resolveFile(AssetRecord record) async {
    final id = libraryIdOf(record);
    if (id == null) return null;
    final entity = await AssetEntity.fromId(id);
    return entity?.file;
  }
}
