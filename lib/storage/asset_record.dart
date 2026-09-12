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
  const DerivativeState({this.status = UploadStatus.pending, this.destinationKey});

  final UploadStatus status;
  final String? destinationKey;

  DerivativeState copyWith({UploadStatus? status, String? destinationKey}) => DerivativeState(
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
    this.derivatives = const {},
  });

  final String localId;
  final String contentHash;
  final String platform;
  final DateTime createdAt;
  final DateTime updatedAt;
  final AssetSourceType sourceType;

  /// Absolute file path, set only for [AssetSourceType.manualFile].
  final String? sourcePath;
  final Map<DerivativeKind, DerivativeState> derivatives;

  DerivativeState stateOf(DerivativeKind kind) => derivatives[kind] ?? const DerivativeState();

  AssetRecord withDerivative(DerivativeKind kind, DerivativeState state) =>
      AssetRecord(
        localId: localId,
        contentHash: contentHash,
        platform: platform,
        createdAt: createdAt,
        updatedAt: DateTime.now(),
        sourceType: sourceType,
        sourcePath: sourcePath,
        derivatives: {...derivatives, kind: state},
      );
}
