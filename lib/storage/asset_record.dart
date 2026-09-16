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
    this.derivatives = const {},
    this.isFavorite = false,
    this.isHidden = false,
    this.deletedAt,
    this.description = '',
    this.tags = const [],
    this.location,
    this.event,
    this.passcodeHash,
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
    derivatives: derivatives ?? this.derivatives,
    isFavorite: isFavorite ?? this.isFavorite,
    isHidden: isHidden ?? this.isHidden,
    deletedAt: deletedAt != null ? deletedAt() : this.deletedAt,
    description: description ?? this.description,
    tags: tags ?? this.tags,
    location: location != null ? location() : this.location,
    event: event != null ? event() : this.event,
    passcodeHash: passcodeHash != null ? passcodeHash() : this.passcodeHash,
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
}
