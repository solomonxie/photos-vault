/// What a queued job actually does when a worker picks it up. Every unit of
/// sync work is one of these against one asset — including the metadata-only
/// change check, so "what is it doing right now" is always answerable from
/// the queue rather than from a counter somewhere.
enum SyncJobKind {
  /// Re-hash the local file and flip the asset back to pending if it's been
  /// edited since its last successful backup.
  checkChanges,

  /// Upload the full-resolution original.
  uploadOriginal,

  /// Upload the moving half of a Live Photo — the paired `.mov`, where
  /// the motion and the sound are. Without it the backup is a still.
  uploadLivePhoto,

  /// Generate/cache the thumbnail, and upload it unless the original is
  /// already small enough not to warrant a second object.
  uploadThumbnail,

  /// Look at the photo on-device (Apple Vision) for tags and faces. A job
  /// like any other so a library-wide pass is pausable, resumable and
  /// visible by name rather than an opaque background grind.
  analyzePhoto,
}

enum SyncJobStatus { pending, running, done, failed }

/// One queued unit of work. Persisted, so a queue survives the app being
/// killed mid-sync and can be paused, retried, and cleared.
class SyncJob {
  const SyncJob({
    required this.id,
    required this.localId,
    required this.kind,
    required this.displayName,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    required this.assetCreatedAt,
    this.errorMessage,
  });

  final String id;

  /// The `AssetRecord` this job is for.
  final String localId;
  final SyncJobKind kind;

  /// What the queue list shows — the asset's filename where there is one.
  final String displayName;
  final SyncJobStatus status;
  final String? errorMessage;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// When the photo was taken — not when the job was made. The queue runs
  /// newest-first, so this is what orders it: the picture from ten minutes
  /// ago goes up before the one from 2014, whichever was queued first. A
  /// job carried over from before this was recorded has the epoch here and
  /// sorts last, behind everything with a real date.
  final DateTime assetCreatedAt;

  bool get isFinished =>
      status == SyncJobStatus.done || status == SyncJobStatus.failed;
}
