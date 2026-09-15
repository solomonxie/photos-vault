/// Lets a caller stop a [BackupCoordinator.backUpBatch] run already in
/// progress (the Backup Queue screen's "Clear Queue" button) without
/// touching any record's state — whatever hasn't been attempted yet just
/// stays pending, to be picked up by the next manual or scheduled sync.
class BackupCancelToken {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() => _cancelled = true;
}
