# 02 Upload & bucket — findings

Scope: `lib/upload/` plus the callers that decide bucket deletes (`photos/fix_queue.dart`,
`photos/record_fixer.dart`, `settings/bucket_browser_screen.dart`, `viewer/library_screen.dart`).
Read-only review; nothing run. Device evidence came from a copy of `/tmp/pv_pull2/photos_vault.db`.

Bucket delete paths found (README says only `PendingDeletes` does this; that's wrong, see #18):
`PendingDeletes.drain`; `BucketFixer._deleteObject` in rename/reformat/replaceRemoteOriginal/
removeOldCopy/removeOrphan; `NameMigration._migrate`; `BucketBrowserScreen` (direct).

## P0

**1. Re-format can re-encode a hidden carrier and delete it if one header read fails.** PLAUSIBLE (path CONFIRMED)
`upload/bucket_flagged.dart:629-638`, `:725-793`
- `canReformat` gets `ok = probe(...) == null`. If the read fails, `CarrierProbe.probe` returns null, so `ok` comes back **true**. It is only not cached (`if (!failed())`). It also ignores the scan's own `known['c'] == true`.
- Scenario: an off-protocol JPEG carrier (v1 or an old name) is flagged `offProtocol`. Re-format runs (batchable). The range read inside `reformat()`'s `canReformat` times out (20 s, flaky cellular). The full `http.get` then succeeds, the carrier is HEIF-encoded (payload gone), uploaded, and the original is deleted at `:792`. For a carrier from another device or an old build, the bucket copy is the only copy.
- Fix: `ok = !failed() && probe == null`. Return false when `_looked(...)['c'] == true`. Never treat a read failure as "not a carrier" anywhere.

**2. "Old copy" of a video is decided by capture second, and Fix All deletes it.** PLAUSIBLE (path CONFIRMED)
`upload/bucket_flagged.dart:171-195`, `:291-299`, `:939-959`; `photos/fix_queue.dart:134` (batchable)
- `videoTwin` flags an unclaimed video as `oldCopy` when its file capture date falls in the same second as a library video in the same bucket, and it is ≤ 1.01× that video's size. `removeOldCopy` only checks that the twin exists, then deletes.
- Scenario: two phones film the same moment (a birthday). The partner's clip is put in the bucket with `import-to-bucket.sh`, starts in the same second and is smaller. It is flagged "old copy", and "Remove old copy" on all deletes the only copy.
- Fix: before deleting, require more than the timestamp (same duration and dimensions, or a frame print match). Make this flag `oneAtATime` with a preview, or list-only.

## P1

**3. Rename/Import treats an unreadable header as "not a carrier".** PLAUSIBLE (path CONFIRMED)
`upload/bucket_flagged.dart:656-677`, `:707-717`; `upload/bucket_import.dart:258-268` (6 at a time)
- `rename()` probes with an unwatched reader. A failed read means `carrier == null`, so the object is copied to an ordinary name, `_importRecord` runs, and the old key is deleted.
- Scenario: Import from Bucket runs 6 at a time and a range read for a JPEG carrier fails. The hidden photo shows up in the library as its decoy picture, and the album can no longer find it. If the user then deletes that "photo", the carrier goes through `PendingDeletes`, so the hidden photo is lost.
- Fix: use `_watched` as `inspect` does, and fail the fix when the read failed.

**4. Live Photo halves: the detector and `adopt` disagree, and the second half is offered forever.** CONFIRMED (device DB shows 1 case)
`upload/bucket_flagged.dart:159-168` vs `:604`; `_importRecord` `:1038-1084`; `upload/bucket_import.dart:258-268`
- `heldSibling` only matches siblings of the same video-ness. `originalStemHeld` (GLOB `*/stem.*`) matches any extension. So once `X.HEIC` is adopted, the unreferenced `X.mov` stays `unclaimed`, and `adopt` refuses it every time ("already in library").
- `_importRecord` never records the `.mov` as `livePhoto`. Bucket import adopts both halves concurrently: both pass `originalStemHeld` and upsert the same `bucket:X` record, and the last one wins (it can end up `isVideo` and pointing at the `.mov`).
- Device: `photos-vault/originals/20250616032353_1237….mov` is unreferenced, and its stem is a record's original. It is re-offered on every scan (see also #27).
- Fix: in `detect`, flag an unreferenced video whose same-stem still is held (or the reverse) as that record's missing `livePhoto` half, and have `adopt` attach it as `livePhoto`. Serialise adopts per stem.

**5. `healPrefixes` takes "not in the last listing" to mean dead and re-points to any same-stem object of any kind.** CONFIRMED logic, PLAUSIBLE trigger
`upload/name_migration.dart:52-88`; called right after a refresh whose result is ignored, `viewer/library_screen.dart:856-863`
- Anything uploaded during or after the listing is "unseen". `formats.single` then re-points the key to the one listed same-stem object, without checking video-ness or version.
- (a) The motion `.mov` lands after the listing passes it, the `.HEIC` is listed, and the `livePhoto` key is re-pointed at the still. `_healKinds` only repairs `original` (`photos/record_fixer.dart:574`), so this is never undone. The real `.mov` then hits #4.
- (b) An edit is re-uploaded as `X.jpg` while the listing still has the superseded `X.HEIC`. The record is re-pointed to the old version. Drain sees it held and drops the delete. `X.jpg` becomes `oldCopy` via `heldSibling`, and Fix All deletes the newer version.
- Fix: run only when `refresh()` returned true. Re-point only after a live HEAD says the recorded key is 404, and only to the same kind (video vs not).

**6. Background backup can starve. Sync Now queues change checks ahead of new photos.** CONFIRMED
`upload/sync_queue.dart:106,123`; `upload/sync_engine.dart:238-245`; `upload/background_sync.dart:146-150`
- `capacity` (100) counts every unfinished kind. The background engine only drains upload kinds.
- If the app dies with ≥100 pending `checkChanges` or `analyzePhoto` jobs, every background enqueue is refused, `queued == 0`, and nothing goes up overnight until the app drains them.
- In the foreground, `_syncEverything` runs `_enqueueChangeChecks()` (fills all 100 slots) before `_backUpRecords`, so new photos aren't queued until 100 hashes finish. It always re-checks the same newest 100.
- Fix: count capacity per kind set (`countWhere(..., kinds)`), queue uploads before change checks, and stop `enqueueChangeChecks` on the first refusal.

**7. Whole originals downloaded into memory through Dart `http`, against the native-transfer rule.** CONFIRMED (crash PLAUSIBLE)
`upload/backup_verifier.dart:307-340` (`testRestore`, videos not excluded); `upload/original_restore.dart:32,126-136`; `upload/bucket_flagged.dart:738`
- A restore drill that picks a 2 GB video, or opening a cloud-only video, holds the whole body as `bodyBytes`, risking OOM or jetpam. There is no timeout and it doesn't survive backgrounding.
- Fix: use `S3Downloader` (already there) to a temp file. Hash the file for the drill.

**8. Bucket browser deletes any key with a generic confirm.** CONFIRMED (cross-ref step 08)
`settings/bucket_browser_screen.dart:281-287`
- There is no check that a record references the key (a cloud-only original is the only copy) or that it is a carrier. `bucket_object` isn't updated either. This breaks the safe-by-default rule.
- Fix: before deleting, look up `keyHeldByOthers` and carrier names. Refuse, or show a specific warning ("N are the only copy of photos in your library"). Then `forgetBucketObject`.

**9. The "never send a shrunken copy over the original" guard trusts the cached listing.** PLAUSIBLE
`upload/backup_coordinator.dart:206-214` (`isListed`)
- For a `localOptimized` record, `_keptOriginal` only holds when the original is in `bucket_object`.
- Scenario: a stale listing, a target never listed, or a newly added target. The record is re-queued (change check after a swap, or `getFromPhotos`).
  - Same extension: the PUT overwrites the full-quality original.
  - Different extension: the row moves to the small copy, and the full original becomes `oldCopy` via `heldSibling`, which Fix All deletes.
- Fix: decide with a live HEAD (`sizeOf`). Treat "unknown" as kept.

## P2

**10. `removeOldCopy` re-checks only that the kept copy exists.** CONFIRMED
`upload/bucket_flagged.dart:939-959`
- At fix time it doesn't re-check that `f` is still unreferenced or not pending, or that the kept copy still has the same size/ETag.
- Scenario: the scan is old, the kept key was overwritten by Optimize in bucket (same extension), and the full-quality duplicate is deleted.
- Fix: re-check `keyHeldByOthers(f)`, and match size+ETag of both just before the delete.

**11. `liveOriginal` with zero targets reads as "lost".** PLAUSIBLE
`upload/bucket_flagged.dart:910-924` → `photos/record_fixer.dart:539-555`, `:671-688`
- `loadAll()` returns `[]` on a keychain read failure, so the loop finds nothing, `_confirmLost` returns true, and Remove from Library purges the record (albums, people, metadata). The bucket is untouched.
- Fix: throw when there are no targets.

**12. `replaceRemoteOriginal` deletes per target before all targets succeed.** PLAUSIBLE
`upload/bucket_flagged.dart:842-896`
- Target 1 is replaced (old deleted, row renamed). Target 2 fails, the function returns, and `destinationKey` is not updated.
- On retry, `downloadOriginal` may fetch target 1's already-shrunk copy and re-encode it again for target 2 (generation loss). `oldKey` is deleted without `keyHeldByOthers`, and the delete result is ignored (`:859`).
- Fix: upload and verify on every target first, then delete the old keys and update the record once.

**13. O(library) and N+1 work.** CONFIRMED
- `healPrefixes`: `targetsHolding` per record per kind, about 4×N queries on every launch listing (`name_migration.dart:52-58`). Use `groupUploads(uploadRows())`.
- `referencedKeys()` (full `listAll` + table) per item in `removeOldCopy` / `replaceRemoteOriginal` (`bucket_flagged.dart:854,955`). A 500-item Fix All does 500 full-library passes on the UI isolate.
- `enqueueChangeChecks` keeps calling `enqueue` (count query) for every uploaded record after the queue is full (`sync_engine.dart:238`).

**14. `BackupVerifier._proveAt` HEAD has no timeout.** CONFIRMED
`upload/backup_verifier.dart:263-276`
- A stalled connection hangs `proveOriginal` (the delete gate), spot checks and the sync that awaits them.
- Fix: add `.timeout(20s)`, and treat a timeout as unreachable.

**15. Foreground `resume()` requeues the background engine's running jobs.** PLAUSIBLE
`upload/sync_queue.dart:98`, `upload/sync_job_store.dart:306-317`
- The background run takes up to 15 s to notice the heartbeat, and in-flight jobs finish anyway. The same file is uploaded twice at once, with double hashing and double `recordUpload`.
- Fix: stamp running rows with an owner or engine id, or only requeue rows older than N minutes.

**16. Sibling and superseded deletes can drop a byte-exact original for a lossy conversion.** PLAUSIBLE
`upload/backup_coordinator.dart:243-252`, `:384-397`, `:612-620`
- Scenario: after a reinstall (same localId, so the same base name) with BackupFormat = optimized, `X.heif` goes up. `_leftovers` queues the old install's byte-exact `X.JPG`.
- Fix: don't retire a sibling when the new upload is a conversion (`.heif` from non-HEIC) unless the source hash changed.

**17. The drain checks, then deletes.** PLAUSIBLE
`upload/pending_deletes.dart:230-238`
- An upload landing under the same key between `_heldNow` and the DELETE (un-hide re-upload) is deleted. Reconcile requeues it only if a local copy exists.
- Fix: re-check `_heldNow` after the delete and requeue the upload if it now holds the key, or serialise drain with the uploads of that `localId`.

## P3

18. The README and the `s3_object_delete.dart:11` doc say only `PendingDeletes` deletes. In fact BucketFixer (5 paths), NameMigration and the bucket browser call DELETE directly, with no `keyHeldByOthers` check. Route all of them through one guarded helper, or fix the doc.
19. `_queueOrphanedKey` (`sync_engine.dart:421-439`) only queues keys the record still holds, with no `localId`. They are dropped as "held" at best, and become a landmine if the row later changes. The device DB has 82 such tasks, all dormant for removed target `8e8b…`. Delete the function, since the coordinator already supersedes.
20. `sizeOf` returns null for 404, 403, timeouts and offline alike (`bucket_ops.dart:110-120`):
    - `inspect` forgets listing rows when offline (`bucket_flagged.dart:538`).
    - `adopt` and `rename` return `removed` when offline (`:601-603`, `:689-691`), so FixQueue marks the item resolved although nothing happened.

    Make it tri-state.
21. The look/ETag cache is keyed by `target|key|size` only (`bucket_flagged.dart:479`). A same-size overwrite keeps stale carrier and ETag answers. Add `lastModified`.
22. `OriginalRestore` sets `localOptimized=false`, reasoning that the bucket "only ever held the original" (`original_restore.dart:143-146`). That's false after Optimize in bucket.
23. `pendingAndFailed` skips `passcodeHash` but not `isHidden`, while change checks skip both (`sync_engine.dart:93-99` vs `:234`). Make them agree.
24. `SyncQueue.enqueue` re-reads the whole job table and notifies on every enqueue (`sync_queue.dart:131`). Refresh once per batch.
25. `removeOldCopy` deletes the same-stem thumbnail if no row names it. For a `heldSibling` copy that is the kept photo's own thumbnail (`bucket_flagged.dart:954-957`).
26. `filePathFor` does `existsSync` on the UI isolate, once per job (`sync_engine.dart:516`). It's bounded, but add a call-site note or make it async.
27. Device evidence for step 04: record `photo:…C9B3…/L0/001` has `createdAt` 2026-10-06 and its own base `20261006162802_30d6…`, but its `original` row is another id's key, `20250616032353_1237….jpg`. Its live row is a new `.MOV` under its own base, and the 2025 `.mov` is unreferenced (#4). Something re-keyed the record (swap or copy takeover?), dropped the `livePhoto` row and rewrote `createdAt`.

## Improvement suggestions

- **One guarded delete.** `BucketOps.deleteGuarded(target, key, keep:)` should refuse if any record or pending upload holds the key, if `keep` doesn't answer HEAD with a matching size/ETag, or if any read in the decision failed. Make every path use it.
- **Tri-state bucket answers** (`present` / `absent` / `unknown`) for `sizeOf` and probes, as `CopyProof` already is. "Unknown" never deletes, never imports and never re-points.
- **Live checks for every cached-listing decision that changes data:** `_keptOriginal`, `healPrefixes`, orphan and duplicate fixes.
- **Heuristic deletes** (videoTwin, size-only) should be list-only or one at a time with a preview. Only content-identical (ETag) or name-proven copies should be batchable.
- **Per-target state for remote optimize:** upload everywhere, then retire the old keys.
- **Queue capacity per kind**, with uploads ahead of change checks.

## Checked and fine

- `deleteObject`: 200/204/404 count as gone; 403 and errors do not.
- `PendingDeletes`: the lock re-reads before writing; dormant tasks for removed targets are never dropped silently; `keyHeldByOthers` protects shared keys, including null-`localId` tasks.
- `DeferredDeletes`: carriers are released only after `isFullyBackedUp`; keys the photo now holds are dropped.
- `deletionTasksFor` / `remoteKeyFor`: a per-target key is rebuilt under that target's prefix, and wildcards wait for a target.
- `BucketIndexer`: staged listing, committed only when both folders are fully listed; concurrent refreshes serialised; removed targets forgotten only on a non-empty target list.
- `reconcile` / `repair` / `spotCheck`: full live listing with token check; 0-byte counts as missing; they only requeue or mark failed and delete nothing.
- `removeOrphan`: lists `originals/<stem>.` live and refuses on no answer.
- `removeFromLibrary` → `purge`: the record only; bucket untouched.
- `NameMigration._migrate`: copy, size check, row rename, then delete.
- `S3Uploader` / `S3Downloader` use `background_downloader`. `deleteObject`, `copy` and HEAD/range reads carry no bodies.
- Hidden records are never queued (`passcodeHash` checked at queue time and in `processJob`); `canUpload` blocks plain uploads while the album is locked.
- `dequeueNextPending` claims a job in one transaction, so two workers never take the same job.
