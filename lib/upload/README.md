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

`backup_verifier.dart` is the only thing in the app that asks the *bucket*
whether a backup exists, instead of asking this app's database.
`proveOriginal` is one presigned HEAD, and nothing removes the last local copy
of anything without it (`../photos/asset_removal.dart`); `reconcile` is one
listing pass per thousand keys, which is what a batch of removals and the
safety screen's Check Now use; `testRestore` downloads three photos back and
checks them. An unreachable bucket is deliberately **not** a missing one — it
blocks the delete and says which happened, rather than reporting a loss that
hasn't occurred.

`library_restore.dart` is the bulk of the other direction: after a reinstall
the records come back from the app-data snapshot but the thumbnails died with
the container, so it refills them from `thumbnails/`. Thumbnails only —
originals stay in the bucket until something opens one.

`s3_object_delete.dart` is the only thing in the app that removes an object
from the bucket, and only `PendingDeletes` calls it: a permanent delete, the
bin emptying or expiring (30 days), or a hide retracting plain copies. Tasks
are durable and retried on every sync; keys are resolved per bucket
(`object_keys.dart`). Everything short of that — including an ordinary delete
— leaves the backup alone, because it's the copy that outlives the phone.

## Bucket import and flagged objects

`bucket_import.dart` lists each bucket into `bucket_object` (`BucketIndexer`),
and "Import from Bucket" renames every flagged plain file. `bucket_flagged.dart`
decides what is flagged (not pointed at by a record, not named like ours) and
holds the fixes: Rename (server-side copy, size check, then delete), Re-format
(download, HEIF, upload; only for files proven not to be carriers) and Remove
orphan. `bucket_ops.dart` is the bucket side: flat listing, ranged reads, copy,
size. `name_migration.dart` renames old `photo_<id>` backups in batches.
`scripts/import-to-bucket.sh` puts a folder in the bucket. Design:
`docs/design/bucket-import/`.

## Background run

`background_sync.dart` is the headless pass behind an iOS `BGProcessingTask`
(`ios/Runner/BackgroundSync.swift`): a second Flutter engine, no screen,
running `SyncEngine` (`sync_engine.dart`, the same code the library screen
drives). iOS decides when — typically overnight, on power and Wi-Fi — and
whether at all; nothing here can promise a schedule.

Backup is always automatic (no schedule to pick; `autoSyncFrequency`, 15
min). It exits early, in this order, when: demo mode is on, no bucket is
configured, the app was in the foreground in the last 5 minutes
(`ForegroundHeartbeat`), the last pass was under 15 minutes ago, or nothing
is pending. While running it stops if the app returns to the foreground or
iOS expires the task. Change-check re-hashing and the full camera-roll scan
stay with the foreground app. Hidden photos are never queued anywhere: they
back up on their own runner while the app is open (`../vault/README.md`).
