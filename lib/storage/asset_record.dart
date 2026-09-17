/// Where an asset's bytes come from. `photoManager` assets are resolved
/// on-demand via `localId` through the `photo_manager` plugin (T2.1);
/// `manualFile` assets (manual add, T2.5, or the share extension, T2.6)
/// carry their own `sourcePath` since there's no photo-library id for them.
enum AssetSourceType { photoManager, manualFile }

/// One of the derivatives generated per asset — each uploads independently.
enum DerivativeKind { thumbnail, medium, original }

/// Per-derivative upload lifecycle. `uploaded` and `failed` are terminal
/// until the scheduler (T3.4) retries.
enum UploadStatus { pending, uploading, uploaded, failed }

/// Upload state for one derivative of an asset.
class DerivativeState {
  const DerivativeState({
    this.status = UploadStatus.pending,
    this.destinationKey,
    this.backedUpHash,
  });

  final UploadStatus status;
  final String? destinationKey;

  /// Content hash (`photos/file_hash.dart`) of the local file as of the
  /// last successful upload of this derivative — `BackupCoordinator`
  /// re-hashes the current file and compares against this to detect a
  /// local edit since backup, flipping the derivative back to `pending`.
  final String? backedUpHash;

  DerivativeState copyWith({
    UploadStatus? status,
    String? destinationKey,
    String? backedUpHash,
  }) => DerivativeState(
    status: status ?? this.status,
    destinationKey: destinationKey ?? this.destinationKey,
    backedUpHash: backedUpHash ?? this.backedUpHash,
  );
}

/// A tracked camera-roll asset and its backup progress. `localId` is the
/// `photo_manager` asset id (stable per-device identifier, not global).
class AssetRecord {
  const AssetRecord({
    required this.localId,
    required this.contentHash,
    required this.platform,
    required this.createdAt,
    required this.updatedAt,
    this.sourceType = AssetSourceType.photoManager,
    this.sourcePath,
    this.thumbnailPath,
    this.localDeleted = false,
    this.isVideo = false,
    this.isLivePhoto = false,
    this.derivatives = const {},
    this.isFavorite = false,
    this.isHidden = false,
    this.deletedAt,
    this.description = '',
    this.tags = const [],
    this.location,
    this.event,
    this.passcodeHash,
    this.latitude,
    this.longitude,
    this.width,
    this.height,
    this.libraryId,
  });

  final String localId;
  final String contentHash;
  final String platform;
  final DateTime createdAt;
  final DateTime updatedAt;
  final AssetSourceType sourceType;

  /// Absolute file path, set only for [AssetSourceType.manualFile].
  final String? sourcePath;

  /// Absolute path to this app's own cached thumbnail (`ThumbnailCache`),
  /// once one has been generated. Kept for every photo — including ones
  /// small enough that no separate `thumbnails/` upload was worth it — so
  /// the grid still has something to draw after [localDeleted].
  final String? thumbnailPath;

  /// The full-resolution local copy has been deleted to reclaim device
  /// space, but the asset is still backed up and still belongs in the
  /// library — grids draw [thumbnailPath], and the detail screen offers to
  /// re-download the original from the bucket. Unrelated to [deletedAt],
  /// which is Photos-style "Recently Deleted".
  final bool localDeleted;

  /// Set once at creation (from the file extension for `manualFile`, from
  /// `AssetEntity.type` for `photoManager`) — `photoManager` assets have no
  /// `sourcePath` to derive it from on demand.
  final bool isVideo;

  /// iOS Live Photo — a still with a paired few-second video, resolved on
  /// demand through `photo_manager` (there's no second file of our own).
  /// Always false on Android and for manually-added files.
  final bool isLivePhoto;

  final Map<DerivativeKind, DerivativeState> derivatives;

  final bool isFavorite;
  final bool isHidden;

  /// Set when soft-deleted (Photos' "Recently Deleted") — `remove()` in the
  /// store is the separate, permanent delete.
  final DateTime? deletedAt;

  final String description;
  final List<String> tags;

  /// A free-text place name — this app doesn't read EXIF GPS tags, so
  /// there's no reverse-geocoding; the user types it themselves.
  final String? location;

  /// A free-text occasion ("Nina's Wedding", "Japan 2019") — what the
  /// Events collection groups by. Same pick-or-type field as [location];
  /// the AI smart collection's own guessed labels stay separate
  /// (`AiPhotoAnalysis.eventLabel`) until the user adopts one here.
  final String? event;

  /// SHA-256 of a 4-digit private-album passcode, or `null` if this asset
  /// isn't in one. There's no separate "private album" entity anywhere —
  /// the group of assets sharing one hash *is* the album; it stops
  /// existing the moment none do. See `private_album_gate.dart`.
  final String? passcodeHash;

  /// Where the camera says the photo was taken, copied off the library
  /// entry when the scan first sees it. Kept as numbers, not just the
  /// place name they resolve to: the name is a lookup away and can change
  /// (a different language, a better geocoder), the coordinates can't.
  final double? latitude;
  final double? longitude;

  /// Pixel size, likewise read off the library entry rather than by
  /// decoding the photo — the info panel used to decode a full-size
  /// original just to print "5857 × 3905".
  final int? width;
  final int? height;

  bool get hasCoordinates => latitude != null && longitude != null;

  /// The OS photo library's own id for this photo, while the library has
  /// it. Separate from [localId] because the two are separate things: this
  /// app's name for a photo has to outlive the library's, which changes
  /// when a hidden photo is taken out of Photos and handed back later —
  /// PhotoKit gives back a *new* asset, and everything this app knows about
  /// the photo (its tags, who's in it, which albums it's in) is keyed on
  /// [localId].
  ///
  /// `null` for a photo the library doesn't have: one imported by hand, or
  /// one in a hidden album.
  final String? libraryId;

  bool get isDeleted => deletedAt != null;

  DerivativeState stateOf(DerivativeKind kind) =>
      derivatives[kind] ?? const DerivativeState();

  AssetRecord _copyWith({
    Map<DerivativeKind, DerivativeState>? derivatives,
    bool? isFavorite,
    bool? isHidden,
    DateTime? Function()? deletedAt,
    String? sourcePath,
    String? thumbnailPath,
    bool? localDeleted,
    DateTime? updatedAt,
    DateTime? createdAt,
    String? description,
    List<String>? tags,
    String? Function()? location,
    String? Function()? event,
    String? Function()? passcodeHash,
    double? latitude,
    double? longitude,
    int? width,
    int? height,
    String? Function()? libraryId,
  }) => AssetRecord(
    localId: localId,
    contentHash: contentHash,
    platform: platform,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? DateTime.now(),
    sourceType: sourceType,
    sourcePath: sourcePath ?? this.sourcePath,
    thumbnailPath: thumbnailPath ?? this.thumbnailPath,
    localDeleted: localDeleted ?? this.localDeleted,
    isVideo: isVideo,
    isLivePhoto: isLivePhoto,
    derivatives: derivatives ?? this.derivatives,
    isFavorite: isFavorite ?? this.isFavorite,
    isHidden: isHidden ?? this.isHidden,
    deletedAt: deletedAt != null ? deletedAt() : this.deletedAt,
    description: description ?? this.description,
    tags: tags ?? this.tags,
    location: location != null ? location() : this.location,
    event: event != null ? event() : this.event,
    passcodeHash: passcodeHash != null ? passcodeHash() : this.passcodeHash,
    latitude: latitude ?? this.latitude,
    longitude: longitude ?? this.longitude,
    width: width ?? this.width,
    height: height ?? this.height,
    libraryId: libraryId != null ? libraryId() : this.libraryId,
  );

  AssetRecord withDerivative(DerivativeKind kind, DerivativeState state) =>
      _copyWith(derivatives: {...derivatives, kind: state});

  AssetRecord withFavorite(bool value) => _copyWith(isFavorite: value);

  AssetRecord withHidden(bool value) => _copyWith(isHidden: value);

  AssetRecord withDeletedAt(DateTime? value) =>
      _copyWith(deletedAt: () => value);

  AssetRecord withCreatedAt(DateTime value) => _copyWith(createdAt: value);

  AssetRecord withDescription(String value) => _copyWith(description: value);

  AssetRecord withTags(List<String> value) => _copyWith(tags: value);

  AssetRecord withLocation(String? value) => _copyWith(location: () => value);

  AssetRecord withEvent(String? value) => _copyWith(event: () => value);

  AssetRecord withPasscodeHash(String? value) =>
      _copyWith(passcodeHash: () => value);

  /// Used by [AssetRecordStore.upsert] to heal a stale `sourcePath`.
  AssetRecord withSourcePath(String value, DateTime updatedAt) =>
      _copyWith(sourcePath: value, updatedAt: updatedAt);

  AssetRecord withThumbnailPath(String value) =>
      _copyWith(thumbnailPath: value);

  AssetRecord withLocalDeleted(bool value) => _copyWith(localDeleted: value);

  /// Which photo-library asset this record is currently the record *of* —
  /// null once the library no longer has it.
  AssetRecord withLibraryId(String? value) => _copyWith(libraryId: () => value);

  /// What the photo library knows about the photo itself, as opposed to
  /// what this app has done with it. Only ever fills blanks — a null here
  /// means "the library didn't say", not "forget what you had".
  AssetRecord withLibraryMetadata({
    double? latitude,
    double? longitude,
    int? width,
    int? height,
  }) => _copyWith(
    latitude: latitude,
    longitude: longitude,
    width: width,
    height: height,
  );
}

/// A cached reverse-geocode result. Distinct from a bare `String?` so
/// "never looked up" and "looked up, nothing there" can't be confused —
/// see `AssetRecordStore.cachedPlaceName`.
class PlaceNameEntry {
  const PlaceNameEntry(this.name);

  final String? name;
}
