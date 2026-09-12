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
    this.derivatives = const {},
  });

  final String localId;
  final String contentHash;
  final String platform;
  final DateTime createdAt;
  final DateTime updatedAt;
  final Map<DerivativeKind, DerivativeState> derivatives;

  DerivativeState stateOf(DerivativeKind kind) => derivatives[kind] ?? const DerivativeState();

  AssetRecord withDerivative(DerivativeKind kind, DerivativeState state) =>
      AssetRecord(
        localId: localId,
        contentHash: contentHash,
        platform: platform,
        createdAt: createdAt,
        updatedAt: DateTime.now(),
        derivatives: {...derivatives, kind: state},
      );
}
