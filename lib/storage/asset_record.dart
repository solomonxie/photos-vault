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
  });

  final UploadStatus status;
  final String? destinationKey;

  DerivativeState copyWith({UploadStatus? status, String? destinationKey}) =>
      DerivativeState(
        status: status ?? this.status,
        destinationKey: destinationKey ?? this.destinationKey,
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
    this.isVideo = false,
    this.derivatives = const {},
    this.isFavorite = false,
    this.isHidden = false,
    this.deletedAt,
    this.description = '',
    this.tags = const [],
    this.location,
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
    DateTime? updatedAt,
    DateTime? createdAt,
    String? description,
    List<String>? tags,
    String? Function()? location,
    String? Function()? passcodeHash,
  }) => AssetRecord(
    localId: localId,
    contentHash: contentHash,
    platform: platform,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? DateTime.now(),
    sourceType: sourceType,
    sourcePath: sourcePath ?? this.sourcePath,
    isVideo: isVideo,
    derivatives: derivatives ?? this.derivatives,
    isFavorite: isFavorite ?? this.isFavorite,
    isHidden: isHidden ?? this.isHidden,
    deletedAt: deletedAt != null ? deletedAt() : this.deletedAt,
    description: description ?? this.description,
    tags: tags ?? this.tags,
    location: location != null ? location() : this.location,
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

  AssetRecord withPasscodeHash(String? value) =>
      _copyWith(passcodeHash: () => value);

  /// Used by [AssetRecordStore.upsert] to heal a stale `sourcePath`.
  AssetRecord withSourcePath(String value, DateTime updatedAt) =>
      _copyWith(sourcePath: value, updatedAt: updatedAt);
}
