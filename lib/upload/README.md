# upload

Fans one derivative file out to every configured target — S3, COS or OSS,
all over the S3 API — and records the aggregate outcome.

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
- `signing.dart` — SigV4 presigning (host from
  `../settings/bucket_endpoint.dart`) and the `thumbnails/`/`medium/`/
  `originals/` key layout.

A Live Photo goes up as **two** objects under one `originals/` prefix —
`photo_X.HEIC` and `photo_X.mov`, the second being where the motion and the
sound are. They are one photo, so they share a folder and a base name.
`DerivativeKind.livePhoto` is never re-encoded whatever `BackupFormat`
says: the QuickTime metadata pairing the halves doesn't survive it. See
`docs/design/uiux/detail.md`.

`AssetRecord.isFullyBackedUp` — not the original's status — is what gates
every "drop the local copy" path, because a Live Photo backed up as a still
alone is a silent still.

Known limitation: status/key is tracked once per derivative, not once per
target — see `backup_coordinator.dart`'s doc comment.

The queue is **capped** at `SyncQueue.capacity` unfinished jobs and refuses
past it, including everything while paused. A library bigger than the cap is
backed up a queueful at a time — `LibraryScreen` refills it whenever a drain
that actually did work finishes, so the refill continues a sync rather than
starting one the sync-frequency setting didn't ask for.

`s3_object_delete.dart` is the only thing in the app that removes an object
from the bucket, and it's reached from exactly one place: emptying this app's
Recently Deleted (`BackupCoordinator.deleteBackup`). Everything short of that
— including an ordinary delete — leaves the backup alone, because it's the
copy that outlives the phone.
