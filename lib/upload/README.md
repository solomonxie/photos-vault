# upload

Fans one derivative file out to every configured S3 target and records the
aggregate outcome.

```text
BackupCoordinator.backUpDerivative(record, kind, filePath)
  │ marks derivative `uploading`             ../storage/asset_record_store.dart
  ▼
targets = BackupTargetsStore.loadAll()       ../settings/backup_targets_store.dart
  │
  ▼ for each target
key = derivativeKey(prefix, derivativeDir, fileName)      signing.dart
  ▼
url = presignPutUrl(target, key)             signing.dart — AWS SigV4, PUT, 15 min
  ▼
S3Uploader.put(filePath, key, target)
  │ background_downloader UploadTask, HTTP PUT to the presigned url
  │ survives backgrounding; single-part only (T3.3 handles large files)
  ▼
succeeded++ on TaskStatus.complete
  ▼
finalStatus = uploaded (>=1 succeeded) | failed (all failed) | pending (no targets)
records aggregate status + first destinationKey    ../storage/asset_record_store.dart
```

- `backup_coordinator.dart` — the fan-out and status bookkeeping above.
- `s3_uploader.dart` — one presigned PUT via `background_downloader`.
- `signing.dart` — AWS SigV4 presigning and the `thumbnails/`/`medium/`/
  `originals/` key layout.

Known limitation: status/key is tracked once per derivative, not once per
target — see `backup_coordinator.dart`'s doc comment.

The queue is **capped** at `SyncQueue.capacity` unfinished jobs and refuses
past it, including everything while paused. A library bigger than the cap is
backed up a queueful at a time — `LibraryScreen` refills it whenever a drain
that actually did work finishes, so the refill continues a sync rather than
starting one the sync-frequency setting didn't ask for.
