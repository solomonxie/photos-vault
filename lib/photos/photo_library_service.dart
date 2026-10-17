import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';

import '../demo/demo_flag.dart';
import '../storage/asset_record.dart';
import 'manual_add.dart' show isGifPath;
import 'photo_changes.dart';
import 'photo_library_change.dart';
import '../storage/asset_record_store.dart';
import '../upload/lost_originals.dart';

enum PhotoLibraryAccess { granted, limited, denied }

/// A still's bytes as PhotoKit stores them, in a file under tmp, and
/// whether the photo is edited in Photos.
class StillResource {
  const StillResource(this.path, {required this.edited});

  final String path;
  final bool edited;
}

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
    Future<String> Function(AssetEntity entity)? loadTitle,
    Future<StillResource?> Function(AssetEntity entity, {required bool base})?
    loadResource,
    PhotoChanges? changes,
  }) : _changes = changes ?? PhotoChanges(),
       _loadResource = loadResource ?? _resourceOf,
       // A library handed in has no plugin behind it to ask.
       _loadTitle =
           loadTitle ??
           (listAssetPage == null && loadEntity == null
               ? ((entity) => entity.titleAsync)
               : ((entity) async => entity.title ?? '')),
       _requestPermission =
           requestPermission ??
           // Demo mode never reaches the real camera roll: an empty,
           // authorised library, so nothing asks and nothing is read.
           (() => DemoFlag.active
               ? Future.value(PermissionState.authorized)
               : PhotoManager.requestPermissionExtend()),
       _openListing = listAssetPage != null
           ? (() => listAssetPage)
           : (() => DemoFlag.active
                 ? ((page, size) => Future.value(const <AssetEntity>[]))
                 : _cameraRollListing()),
       _loadEntity =
           loadEntity ??
           ((id) => DemoFlag.active ? Future.value() : AssetEntity.fromId(id)),
       _deleteAssets =
           deleteAssets ??
           ((ids) => DemoFlag.active
               ? Future.value(const <String>[])
               : _defaultDeleteAssets(ids));

  final AssetRecordStore store;
  final Future<PermissionState> Function() _requestPermission;
  final PhotoChanges _changes;
  final Future<String> Function(AssetEntity entity) _loadTitle;

  /// A pager for one pass: [_cameraRollListing] in the app.
  final Future<List<AssetEntity>> Function(int page, int size) Function()
  _openListing;
  final Future<AssetEntity?> Function(String id) _loadEntity;
  final Future<StillResource?> Function(
    AssetEntity entity, {
    required bool base,
  })
  _loadResource;

  /// Overridable for tests so they never really delete from the OS library.
  final Future<List<String>> Function(List<String> ids) _deleteAssets;

  static Future<List<String>> _defaultDeleteAssets(List<String> ids) =>
      PhotoManager.editor.deleteWithIds(ids);

  static const _pageSize = 200;

  /// One pass over the camera roll, a page at a time, **newest first**.
  /// Metadata only — no `.file`/thumbnail bytes touched here, so no iCloud
  /// downloads triggered. The album is looked up on the first page and kept
  /// for the rest of the pass.
  ///
  /// The order is the whole point. A first scan works backwards from the
  /// most recent photo, so the page the user is actually looking at fills
  /// first and everything after it arrives off-screen, above. Scanning in
  /// library order would put 2011 on screen and then shove it around for a
  /// minute as the rest of the decade landed on top of it.
  static Future<List<AssetEntity>> Function(int page, int size)
  _cameraRollListing() {
    Future<AssetPathEntity?>? album;
    return (page, size) async {
      final path = await (album ??= _cameraRoll());
      if (path == null) return const [];
      return path.getAssetListPaged(page: page, size: size);
    };
  }

  static Future<AssetPathEntity?> _cameraRoll() async {
    final paths = await PhotoManager.getAssetPathList(
      type: RequestType.common,
      onlyAll: true,
      filterOption: FilterOptionGroup(
        // No filename: on iOS each one is an asset-resource lookup. Only a
        // new image needs it (the GIF check), so [_titleOf] asks for those.
        imageOption: const FilterOption(needTitle: false),
        orders: const [
          OrderOption(type: OrderOptionType.createDate, asc: false),
        ],
      ),
    );
    return paths.firstOrNull;
  }

  /// The filename, which is the only thing that says "this is a GIF":
  /// PhotoKit's asset type calls it an image, and `mimeType` is null on
  /// iOS. Images only; a failed lookup is no filename.
  Future<String> _titleOf(AssetEntity entity) async {
    if (entity.type != AssetType.image) return '';
    final listed = entity.title;
    if (listed != null && listed.isNotEmpty) return listed;
    try {
      return await _loadTitle(entity);
    } catch (_) {
      return '';
    }
  }

  static const _idPrefix = 'photo:';

  static String localIdFor(AssetEntity entity) => localIdForAssetId(entity.id);

  static String localIdForAssetId(String id) => '$_idPrefix$id';

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
    // Taken before the listing: whatever changes while it runs is after
    // the token, so the next [syncChanges] still sees it.
    final token = await _changes.token();
    final listPage = _openListing();

    // Page by page rather than the whole roll in one go: a decade of photos
    // is hundreds of thousands of entities, and holding them all in memory
    // to loop over once is a spike for nothing. Each page is also a chance
    // to show what's been found — see [onPage].
    for (var page = 0; ; page++) {
      final entities = await listPage(page, _pageSize);
      if (entities.isEmpty) break;
      final result = await _applyPage(entities, seen);
      added.addAll(result.added);
      updated += result.updated;
      onPage?.call(result);
      if (entities.length < _pageSize) break;
    }

    if (reconcileDeletions) {
      // Every asset has been offered to the restored rows: what is left
      // waiting has no asset on this phone.
      await store.clearRelinkPending();
      updated += await _reconcileDeletions(seen);
    }
    await _markFullPass(token, reconciled: reconcileDeletions);
    return PhotoLibrarySyncResult(added: added, updated: updated);
  }

  static const changeTokenKey = 'library_change_token';
  static const fullPassAtKey = 'library_full_pass_at';

  /// Whether the last full pass reconciled deletions (full access) or not.
  /// A delta only stands in for a pass made under the same access.
  static const fullPassAccessKey = 'library_full_pass_access';

  /// The most ids one delta is applied for, one lookup each; past it the
  /// paged full pass is cheaper.
  static const deltaLimit = 2000;

  Future<void> _markFullPass(String? token, {required bool reconciled}) async {
    await store.setAppState(fullPassAccessKey, reconciled ? 'full' : 'partial');
    await store.setAppState(fullPassAtKey, DateTime.now().toIso8601String());
    if (token != null) await store.setAppState(changeTokenKey, token);
  }

  /// When the last [syncAll] finished, or null if none has here.
  Future<DateTime?> lastFullPassAt() async =>
      DateTime.tryParse(await store.getAppState(fullPassAtKey) ?? '');

  /// What changed in Photos since the last pass, from PhotoKit's change
  /// history, through [applyChange] — so a resume costs what changed, not
  /// what the library holds.
  ///
  /// Null when the history can't stand in for a [syncAll]: no token yet
  /// (or iOS 15), the token expired, access changed since the last full
  /// pass, restored rows wait for an asset (only a full pass offers them
  /// every one), or more changed than [deltaLimit]. Deletions go through
  /// [applyChange]'s own rule: full access and a live lookup per id.
  Future<PhotoLibrarySyncResult?> syncChanges() async {
    final token = await store.getAppState(changeTokenKey);
    if (token == null) return null;
    final access = await requestAccess();
    if (access == PhotoLibraryAccess.denied) return null;
    final passAccess = access == PhotoLibraryAccess.granted
        ? 'full'
        : 'partial';
    if (await store.getAppState(fullPassAccessKey) != passAccess) return null;
    if (await store.hasRelinkPending()) return null;
    final delta = await _changes.since(token);
    if (delta == null || delta.change.length > deltaLimit) return null;
    final result = await applyChange(delta.change);
    // Only once applied: a failure above replays the same history.
    await store.setAppState(changeTokenKey, delta.token);
    return result;
  }

  /// The newest [pages] pages of the camera roll and nothing else — what
  /// the app runs every time it opens or comes back to the foreground.
  ///
  /// [syncAll] is correct and slow: a pass over a decade of photos is a
  /// database lookup per asset, and while it is working through 2014 the
  /// photos taken — and deleted — this morning are the ones on screen.
  /// This is the same work over the near end of the library, bounded, so
  /// coming back from Photos shows what just changed there in a moment
  /// rather than at the end of a full re-read.
  ///
  /// [reconcileDeletions] is bounded the same way: a record newer than the
  /// oldest asset this pass saw, which the pass did *not* see, is gone from
  /// the library. Older records are the full scan's business, because this
  /// pass has no opinion about them. Same access rule as [syncAll] — full
  /// access only, or everything outside the selection looks deleted.
  Future<PhotoLibrarySyncResult> syncRecent({
    int pages = 2,
    bool reconcileDeletions = false,
  }) async {
    final added = <AssetRecord>[];
    final seen = <String>{};
    var updated = 0;
    DateTime? oldest;
    var wholeLibrary = false;

    final listPage = _openListing();
    for (var page = 0; page < pages; page++) {
      final entities = await listPage(page, _pageSize);
      if (entities.isEmpty) {
        wholeLibrary = true;
        break;
      }
      final result = await _applyPage(entities, seen);
      added.addAll(result.added);
      updated += result.updated;
      for (final entity in entities) {
        final at = entity.createDateTime;
        if (oldest == null || at.isBefore(oldest)) oldest = at;
      }
      if (entities.length < _pageSize) {
        wholeLibrary = true;
        break;
      }
    }

    if (reconcileDeletions) {
      updated += await _reconcileDeletions(
        seen,
        // A library small enough to fit in the window was read in full, so
        // there is no near end to limit the check to.
        newerThan: wholeLibrary ? null : oldest,
      );
    }
    return PhotoLibrarySyncResult(added: added, updated: updated);
  }

  /// One page of listed entities into the store. [seen] collects the
  /// `localId` of everything the page accounted for, which is what
  /// [_reconcileDeletions] measures absence against.
  ///
  /// New assets go in as one transaction, and the page's favourite and
  /// metadata writes as another, rather than a commit per row. Restored
  /// rows waiting for their asset take the one-by-one path, which offers
  /// each new asset to them first.
  Future<PhotoLibrarySyncResult> _applyPage(
    List<AssetEntity> entities,
    Set<String> seen,
  ) async {
    final added = <AssetRecord>[];
    var updated = 0;
    final known = await store.getByLibraryIds(entities.map((e) => e.id));
    final fresh = [
      for (final entity in entities)
        if (known[entity.id] == null) entity,
    ];
    if (fresh.isNotEmpty) {
      if (await store.hasRelinkPending()) {
        for (final entity in fresh) {
          // Read before a swap could move a record onto this asset: the
          // store's one-record-per-asset rule hands that record back.
          final localId = localIdFor(entity);
          final inserted = await _insert(entity, localId);
          seen.add(inserted.localId);
          if (inserted.localId == localId) added.add(inserted);
        }
      } else {
        await _insertPage(fresh, seen, added);
      }
    }
    final favorites = <String, bool>{};
    final metadata = <String, LibraryMetadata>{};
    final modified = <String, int>{};
    for (final entity in entities) {
      final existing = known[entity.id];
      if (existing == null) continue;
      seen.add(existing.localId);
      if (modifiedStamp(existing, entity) case final at?) {
        modified[existing.localId] = at;
      }
      if (await _relink(existing, entity)) updated++;
      if (existing.isFavorite != entity.isFavorite) {
        favorites[existing.localId] = entity.isFavorite;
        updated++;
      }
      if (await _cameBack(existing)) updated++;
      // Photos tracked before this app started keeping coordinates and
      // pixel sizes: the entity is right here, so the backfill is the
      // scan itself rather than a separate pass over the library.
      if (_libraryMetadataOf(existing, entity) case final filled?) {
        metadata[existing.localId] = filled;
        updated++;
      }
    }
    await store.applyScanUpdates(favorites: favorites, metadata: metadata);
    await store.noteModified(modified);
    return PhotoLibrarySyncResult(added: added, updated: updated);
  }

  /// [entity]'s modification date, for a backed-up record read from it:
  /// what tells a change check an edit in Photos may have happened. Null
  /// for anything the check doesn't read from PhotoKit.
  static int? modifiedStamp(AssetRecord record, AssetEntity entity) {
    if (record.sourcePath != null || record.passcodeHash != null) return null;
    if (record.stateOf(DerivativeKind.original).status !=
        UploadStatus.uploaded) {
      return null;
    }
    return entity.modifiedDateSecond;
  }

  /// [_insert] for a page of new assets, in one transaction. An asset the
  /// store didn't take (its `photo:` id already holds another asset) goes
  /// through [_insert] after all, which hands back what is there.
  Future<void> _insertPage(
    List<AssetEntity> fresh,
    Set<String> seen,
    List<AssetRecord> added,
  ) async {
    final titles = await Future.wait(fresh.map(_titleOf));
    final platform = Platform.isIOS ? 'ios' : 'android';
    final rows = <ScannedAsset>[];
    for (final (i, entity) in fresh.indexed) {
      final latLng = _coordinatesOf(entity);
      rows.add(
        ScannedAsset(
          localId: localIdFor(entity),
          libraryId: entity.id,
          platform: platform,
          isVideo: entity.type == AssetType.video,
          isGif: isGifPath(titles[i]),
          isLivePhoto: entity.isLivePhoto,
          isFavorite: entity.isFavorite,
          createdAt: entity.createDateTime,
          latitude: latLng?.latitude,
          longitude: latLng?.longitude,
          width: entity.width > 0 ? entity.width : null,
          height: entity.height > 0 ? entity.height : null,
        ),
      );
    }
    final held = await store.insertScanned(rows);
    for (final entity in fresh) {
      final localId = localIdFor(entity);
      final record = held[entity.id] ?? await _insert(entity, localId);
      seen.add(record.localId);
      if (record.localId == localId) added.add(record);
    }
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
        final inserted = await _insert(entity, localId);
        if (inserted.localId == localId) added.add(inserted);
        continue;
      }
      if (await _relink(existing, entity)) updated++;
      if (modifiedStamp(existing, entity) case final at?) {
        await store.noteModified({existing.localId: at});
      }
      if (existing.isFavorite != entity.isFavorite) {
        await store.setFavorite(existing.localId, entity.isFavorite);
        updated++;
      }
      if (await _cameBack(existing)) updated++;
      if (await _fillLibraryMetadata(existing, entity)) updated++;
      if (change.updated.contains(id) &&
          !change.created.contains(id) &&
          await _refreshDate(existing, entity)) {
        updated++;
      }
    }

    updated += await _markMissing(change.deleted);
    return PhotoLibrarySyncResult(added: added, updated: updated);
  }

  /// A row found only by its own id (`photo:<asset>`) with no link: one the
  /// v23 upgrade unlinked as a second record of an asset, now the only one
  /// on it. Linked back. Never a held file (hidden, or taken out).
  Future<bool> _relink(AssetRecord record, AssetEntity entity) async {
    if (record.libraryId != null ||
        record.sourcePath != null ||
        record.passcodeHash != null ||
        record.localId != localIdFor(entity)) {
      return false;
    }
    try {
      await store.setLibraryId(record.localId, entity.id);
      return true;
    } catch (_) {
      // Another record holds it: this one stays unlinked.
      return false;
    }
  }

  /// Listed again: back from the OS's own Recently Deleted, or restored
  /// some other way. A bin entry the scan made, or one too old to say who
  /// made it, comes back out; one the user made stays where they put it.
  Future<bool> _cameBack(AssetRecord record) async {
    var moved = false;
    if (record.localDeleted && record.sourcePath == null) {
      await store.setLocalDeleted(record.localId, false);
      moved = true;
    }
    if (record.isDeleted && await store.unbinListed(record.localId)) {
      moved = true;
    }
    return moved;
  }

  /// A date changed over in Photos (04#12). Only from an edit iOS reported,
  /// not from every scan: a scan would also undo a date set here that
  /// Photos refused, or one a fresh save hasn't been given yet.
  Future<bool> _refreshDate(AssetRecord record, AssetEntity entity) async {
    if (record.sourcePath != null || record.passcodeHash != null) {
      return false;
    }
    final listed = entity.createDateTime;
    if (listed.millisecondsSinceEpoch <= 0) return false;
    if (listed.millisecondsSinceEpoch ~/ 1000 ==
        record.createdAt.millisecondsSinceEpoch ~/ 1000) {
      return false;
    }
    await store.setCreatedAt(record.localId, listed);
    return true;
  }

  /// Library ids something says are gone: a deletion notice, or a grid
  /// tile whose thumbnail didn't come back. Neither is proof. Full access
  /// only (a deselected photo looks deleted too), and each id is asked
  /// about again; a failed lookup means still there.
  Future<int> _markMissing(Set<String> libraryIds) async {
    if (libraryIds.isEmpty || !await hasFullAccess()) return 0;
    final records = await store.getByLibraryIds(libraryIds);
    var changed = 0;
    for (final MapEntry(key: id, value: record) in records.entries) {
      if (await _missingFromLibrary(id) == null) continue;
      if (await _markGone(record)) changed++;
    }
    return changed;
  }

  /// Whether an absence from the library can mean anything. Under
  /// "Selected Photos" every unselected photo looks deleted.
  Future<bool> hasFullAccess() async {
    try {
      return await requestAccess() == PhotoLibraryAccess.granted;
    } catch (_) {
      return false;
    }
  }

  /// True when Photos has asset [id], false when it answered it hasn't,
  /// null when the lookup failed.
  Future<bool?> hasAsset(String id) async {
    try {
      return await _loadEntity(id) != null;
    } catch (_) {
      return null;
    }
  }

  /// Photos answered it has no asset [libraryId]. A failed lookup is
  /// false. Pair with [hasFullAccess].
  Future<bool> isGone(String libraryId) async =>
      await _missingFromLibrary(libraryId) != null;

  /// Deals with camera-roll records the library no longer has an asset for.
  ///
  /// Only with full access, and only for a record a live lookup confirms is
  /// gone. Never by deleting the row. The row is where this app's own work lives
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
  ///    Deleted, marked as binned by the library. Leaving it in the main
  ///    grid would claim it's still yours; binning it keeps the record (and
  ///    its metadata) recoverable, and the scan takes it back out if the
  ///    photo returns.
  ///
  /// [newerThan] bounds the check to records created after that moment —
  /// how [syncRecent] limits itself to the part of the library it actually
  /// read. Null checks everything, which only a pass over the whole roll
  /// may ask for.
  Future<int> _reconcileDeletions(
    Set<String> seen, {
    DateTime? newerThan,
  }) async {
    if (!await hasFullAccess()) return 0;
    var changed = 0;
    for (final record in await store.listAll()) {
      if (record.sourceType != AssetSourceType.photoManager) continue;
      if (seen.contains(record.localId)) continue;
      if (newerThan != null && !record.createdAt.isAfter(newerThan)) continue;
      // No library id: hidden (taken out on purpose) or nothing to ask
      // about. Either way absence proves nothing.
      final libraryId = record.libraryId;
      if (libraryId == null) continue;
      // Absent from the listing isn't the same as gone. Pages shift under a
      // scan as photos arrive and leave, so a photo can fall through the
      // gap between two of them and be perfectly fine — ask about this one
      // before writing it off, which costs a metadata lookup and only for
      // the handful the listing didn't account for. A failed lookup is not
      // an answer: still there.
      if (await _missingFromLibrary(libraryId) == null) continue;
      if (await _markGone(record)) changed++;
    }
    return changed;
  }

  Future<AssetRecord> _insert(AssetEntity entity, String localId) async {
    final restored = await _adoptRestored(entity);
    if (restored != null) return restored;
    final latLng = _coordinatesOf(entity);
    final record = await store.upsert(
      localId: localId,
      contentHash: entity.id,
      platform: Platform.isIOS ? 'ios' : 'android',
      sourceType: AssetSourceType.photoManager,
      isVideo: entity.type == AssetType.video,
      isGif: isGifPath(await _titleOf(entity)),
      isLivePhoto: entity.isLivePhoto,
      createdAt: entity.createDateTime,
      libraryId: entity.id,
      latitude: latLng?.latitude,
      longitude: latLng?.longitude,
      width: entity.width > 0 ? entity.width : null,
      height: entity.height > 0 ? entity.height : null,
    );
    // Already held: the store handed back the record on it.
    if (record.localId != localId || !entity.isFavorite) return record;
    await store.setFavorite(localId, true);
    return record.withFavorite(true);
  }

  /// A row restored from another phone's backup, for the asset it was there:
  /// the same capture second and shape, and an old asset id this phone
  /// doesn't have. Taken over rather than a second record added beside it
  /// with none of its captions, albums or people. Any doubt adds the record.
  Future<AssetRecord?> _adoptRestored(AssetEntity entity) async {
    try {
      final twin = await store.relinkCandidate(
        createdAt: entity.createDateTime,
        isVideo: entity.type == AssetType.video,
        width: entity.width > 0 ? entity.width : null,
        height: entity.height > 0 ? entity.height : null,
      );
      if (twin == null) return null;
      final old = twin.libraryId;
      if (old != null && old != entity.id) {
        final here = await hasAsset(old);
        // Its own asset is on this phone: not a stranger's record.
        if (here == true) await store.clearRelinkPending(twin.localId);
        // A failed lookup decides nothing either.
        if (here != false) return null;
      }
      if (!await store.adoptAsset(
        twin.localId,
        entity.id,
        width: entity.width > 0 ? entity.width : null,
        height: entity.height > 0 ? entity.height : null,
      )) {
        return null;
      }
      await store.clearRelinkPending(twin.localId);
      return await store.getByLocalId(twin.localId);
    } catch (_) {
      return null;
    }
  }

  /// Writes anything the library knows and the record doesn't. Blanks
  /// only: a photo whose GPS tag was stripped keeps the coordinates it was
  /// scanned with rather than losing them to a re-scan.
  Future<bool> _fillLibraryMetadata(
    AssetRecord record,
    AssetEntity entity,
  ) async {
    final filled = _libraryMetadataOf(record, entity);
    if (filled == null) return false;
    await store.setLibraryMetadata(
      record.localId,
      latitude: filled.latitude,
      longitude: filled.longitude,
      width: filled.width,
      height: filled.height,
    );
    return true;
  }

  /// The blanks [_fillLibraryMetadata] would fill, or null for none.
  static LibraryMetadata? _libraryMetadataOf(
    AssetRecord record,
    AssetEntity entity,
  ) {
    final latLng = record.hasCoordinates ? null : _coordinatesOf(entity);
    final width = record.width == null && entity.width > 0
        ? entity.width
        : null;
    final height = record.height == null && entity.height > 0
        ? entity.height
        : null;
    if (latLng == null && width == null && height == null) return null;
    return (
      latitude: latLng?.latitude,
      longitude: latLng?.longitude,
      width: width,
      height: height,
    );
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
  /// change notification. Returns whether anything actually moved. Only
  /// ever cloud-only or the bin, never the row: see [_reconcileDeletions].
  Future<bool> _markGone(AssetRecord record) async {
    // Already accounted for, or holding a local copy of its own — an
    // original restored from the bucket lives in app storage, not in the
    // photo library, so its absence there says nothing.
    if (record.isDeleted || record.localDeleted) return false;
    if (record.sourcePath != null || record.passcodeHash != null) return false;
    // A Live Photo counts only with both halves up — see
    // [AssetRecord.isFullyBackedUp]. Calling one cloud-only on the
    // strength of its still would claim a photo is safe when its motion
    // and sound are gone.
    if (record.isFullyBackedUp) {
      await store.setLocalDeleted(record.localId, true);
      // The row says it is backed up; the bucket hasn't been asked. The next
      // sync proves it, and flags the photo Lost if the bucket has let go.
      await ProofQueue(store).add(record.localId);
    } else {
      // Even with nothing left to give back: the row holds the captions,
      // albums and people, and the photo may come back out of Photos'
      // own Recently Deleted.
      await store.softDelete(record.localId, byLibrary: true);
    }
    return true;
  }

  /// How long a video runs, off the library entry. A video carrier's decoy
  /// is held for exactly this long: 200 MB over three minutes is an
  /// ordinary capture, the same bytes over two seconds is nothing anyone
  /// ever shot.
  Future<Duration?> durationOf(AssetRecord record) async {
    try {
      final entity = await entityFor(record);
      final seconds = entity?.duration ?? 0;
      return seconds <= 0 ? null : Duration(seconds: seconds);
    } catch (_) {
      return null;
    }
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

  /// [record]'s original as PhotoKit stores it (BG-2): the unedited base
  /// resource of a photo edited in Photos, `originFile` otherwise. Never a
  /// render. Null when it can't be had now; a skip, never a fallback to a
  /// render under the original's name.
  Future<StillResource?> originalResourceFor(AssetRecord record) =>
      _resource(record, base: true);

  /// [record]'s current look as PhotoKit stores it: an edit's full-size
  /// render, or the original's bytes when unedited (`originFile`).
  Future<StillResource?> currentResourceFor(AssetRecord record) =>
      _resource(record, base: false);

  Future<StillResource?> _resource(
    AssetRecord record, {
    required bool base,
  }) async {
    try {
      final entity = await entityFor(record);
      if (entity == null) return null;
      return await _loadResource(entity, base: base);
    } catch (_) {
      return null;
    }
  }

  /// photo_manager 3.12 writes both under `tmp/.image/` keyed by id and
  /// modification date (`TempRenders` cleans them up). `originFile` of an
  /// edited photo is its `.fullSizePhoto` render; `getBaseFile` is the
  /// `.photo` original.
  static Future<StillResource?> _resourceOf(
    AssetEntity entity, {
    required bool base,
  }) async {
    final darwin = Platform.isIOS || Platform.isMacOS;
    final edited = darwin && await entity.darwin.hasAdjustments;
    final file = edited && base
        ? await entity.darwin.getBaseFile()
        : await entity.originFile;
    if (file == null) return null;
    return StillResource(file.path, edited: edited);
  }

  /// PhotoKit's modification date for [record], read live, in seconds.
  Future<int?> modifiedSecondsOf(AssetRecord record) async {
    try {
      return (await entityFor(record))?.modifiedDateSecond;
    } catch (_) {
      return null;
    }
  }

  /// [fileFor], but only when the original is already on this phone — null
  /// rather than an iCloud download.
  Future<File?> localFileFor(AssetRecord record) async {
    final entity = await entityFor(record);
    if (entity == null || !await entity.isLocallyAvailable()) return null;
    return entity.file;
  }

  /// Deletes [record] from the OS photo library itself — this app never
  /// keeps its own copy of a camera-roll asset, so this is the only way to
  /// reclaim its device storage. iOS prompts for confirmation and moves it
  /// to the system's own Recently Deleted; returns whether it actually
  /// went (false if the user declined the prompt, or it wasn't ours to
  /// delete).
  Future<bool> deleteFromLibrary(
    AssetRecord record, {
    bool missingCountsAsDeleted = false,
  }) async => (await deleteManyFromLibrary([
    record,
  ], missingCountsAsDeleted: missingCountsAsDeleted)).contains(record.localId);

  /// The most photos one call may take out. iOS puts up a single
  /// confirmation listing what's about to go, and past a hundred thumbnails
  /// that sheet stops being something anyone reads — a confirmation nobody
  /// can check is not a confirmation. Anything over the cap is left for the
  /// next batch rather than silently going with the rest.
  static const deleteBatchLimit = 100;

  /// The same delete for a batch, in **one** call — iOS prompts once per
  /// `deleteWithIds`, so clearing fifty photos one at a time is fifty
  /// prompts. Returns the `localId`s that actually went; anything past
  /// [deleteBatchLimit] simply isn't in it.
  ///
  /// [limit] lifts the cap for a prompt the person asked to be one: the
  /// originals a whole Optimize run replaced, all at once at its end.
  Future<Set<String>> deleteManyFromLibrary(
    List<AssetRecord> records, {
    int limit = deleteBatchLimit,
    bool missingCountsAsDeleted = false,
  }) async {
    final localIds = <String, String>{};
    for (final record in records) {
      final id = libraryIdOf(record);
      if (id != null) localIds[id] = record.localId;
      if (localIds.length == limit) break;
    }
    if (localIds.isEmpty) return const {};
    final deleted = (await _deleteAssets(localIds.keys.toList())).toSet();
    if (!missingCountsAsDeleted) {
      return {for (final id in deleted) ?localIds[id]};
    }
    // An id Photos no longer has can't be deleted and comes back unlisted,
    // which used to leave its record undeletable for good. It's gone. Only
    // for a delete: to hiding, "not found" must never pass for "removed".
    final missing = await Future.wait([
      for (final id in localIds.keys)
        if (!deleted.contains(id)) _missingFromLibrary(id),
    ]);
    return {
      for (final id in deleted) ?localIds[id],
      for (final id in missing.nonNulls) ?localIds[id],
    };
  }

  /// [id] when Photos answers that it has no such asset; null when it has
  /// it or can't say — a failed lookup is not proof of absence.
  Future<String?> _missingFromLibrary(String id) async {
    try {
      return await _loadEntity(id) == null ? id : null;
    } catch (_) {
      return null;
    }
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
    if (DemoFlag.active) return null;
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
    if (!record.isLivePhoto) return null;
    final id = libraryIdOf(record);
    if (id != null) {
      final entity = await AssetEntity.fromId(id);
      final file = await entity?.originFileWithSubtype;
      if (file != null) return file;
    }
    // Taken out of Photos by hiding: the `.mov` was copied beside the still.
    final still = record.sourcePath;
    if (still != null) {
      final held = File(heldLiveVideoPath(still));
      if (await held.exists()) return held;
    }
    // Nothing in the photo library — removed from the device, or restored
    // onto a fresh install. The `.mov` that came back down from the bucket
    // is named after its object key (`OriginalRestore`), so a restored
    // Live Photo still moves and still has its sound.
    return restoredLivePhotoVideo(record);
  }

  /// Where this app keeps a Live Photo's `.mov` once it holds the still at
  /// [stillPath] — see `LibraryCustody`.
  static String heldLiveVideoPath(String stillPath) => '$stillPath.live.mov';

  /// The re-downloaded `.mov`, if one has been pulled back.
  static Future<File?> restoredLivePhotoVideo(AssetRecord record) async {
    final key = record.stateOf(DerivativeKind.livePhoto).destinationKey;
    if (key == null) return null;
    try {
      final dir = await getApplicationSupportDirectory();
      final file = File(p.join(dir.path, p.basename(key)));
      return await file.exists() ? file : null;
    } catch (_) {
      return null;
    }
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
