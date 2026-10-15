# 04 Library sync & storage fixes — findings

Scope: `lib/photos/` photo_library_service, photo_library_change, library_scanner, library_custody, asset_removal, storage_optimizer, storage_advice, fix_queue, fix_rates, record_fixer, smaller_export, derived_asset, library_metadata. Callers read where they decide behaviour (`viewer/library_screen.dart`, `viewer/asset_grid.dart`, `viewer/flagged_items_screen.dart`, `viewer/private_album_screen.dart`).
Lines refer to the working tree, including the uncommitted `getByLibraryIds` and `_scanRecentThenAll` change. Device evidence comes from a copy of `/tmp/pv_pull2/photos_vault.db` in `/tmp/pv_review04/`.

## Lead from 02 (#27): what happened to `photo:EA10C64A…`

The Optimize swap did **not** do this. It was hide followed by unhide. Step 03 owns the rest.

- **The date is real.** `created_at` is 2026-10-06 23:28:02. A sibling Live Photo `B518D38D…` was taken 8 s earlier, and both were added at 23:28:19 by one scan. Neither has been touched by Optimize: `local_optimized=0`, 3024×4032.
- **The record was hidden and later unhidden.** `library_id` (22C75B11…) is not the id in its `local_id`, and it has an app-held `source_path`. That is the `LibraryCustody.takeOut` → `putBack` signature (`library_custody.dart:366`).
- **Its original was uploaded under a carrier's stem.**
  - The original key is `20250616032353_1237….jpg`. Bucket LastModified is 2026-10-11 16:07:19, the same millisecond as its `derivative_target.uploaded_at`.
  - The same stem's `.mov` landed 20 s later, and `bucket_looks` marks it `"c":true`, a hidden carrier.
  - No current or deleted `local_id` hashes to `1237…`, which fits a `hiddenBaseName` (decoy date + nonce/locator).
  - `BackupCoordinator.safeFileName` reuses `previousKey`'s stem (`backup_coordinator.dart:78-80`). So at upload time the record's original `destinationKey` still named the carrier.
  - The motion had no previous key, so it went up under the record's own stem (`20261006162802_30d6….MOV`). That split the halves.
- **Likely window:** `_removeManyFromAlbum` clears `passcodeHash` *before* `resetBackupAfterUnhide` (`private_album_screen.dart:589-596`). A hidden-backup job still in flight can write the carrier key back after the reset. Either way, a plain sync can upload the plaintext over `<carrier>.jpg`. **→ Step 03:** check that the still carrier was overwritten by plaintext, and that the `.mov` carrier is now an orphan.

## P1

### 1. A record whose photo is back in Photos stays in the app's bin, and 30 days later the bin purge deletes its bucket copies — CONFIRMED
- `photo_library_service.dart:255-261` (and `:302-306`) only undo `localDeleted`. A row that `_markGone` soft-deleted (`:467`), or that `deleteEverywhere` binned, has `deletedAt` set and `localDeleted=false`. When the asset reappears (restored from Apple's Recently Deleted, or after a false "gone" from #2), nothing un-bins it.
- `expireBin` (`asset_removal.dart:255-264`) then purges it with `_discard`, which queues bucket deletes for its keys and drops the row (albums, people, captions). The next scan re-inserts it as a new, un-backed-up record.
- Device: 63 camera-roll rows are binned with `local_deleted=0`. Whether their assets still exist can't be checked offline.
- Fix: in `_applyPage`/`applyChange`, when an existing record is listed and `isDeleted`, `restore()` it, unless the bin entry was the user's own delete. To tell the two apart, record why it was binned (`binned_by=library|user`).

### 2. "Missing" from one failed lookup marks photos gone, and with no backup the row is deleted outright — CONFIRMED (path), PLAUSIBLE (trigger)
- A tile whose thumbnail fails asks `AssetEntity.fromId` (`asset_grid.dart:933-943`). On `null` it reports missing (`:1068-1078`). `_reconcileMissing` (`library_screen.dart:1086-1112`) then calls `applyChange(deleted:)` → `_markGone`, with no second check and no access check.
- Under **Selected Photos (limited)** access, `fromId` is null for every asset outside the selection. The scan's reconcile is gated on full access (`library_screen.dart:913,946`), but this path isn't. Scrolling the grid after downgrading access marks every visible unselected photo gone:
  - backed up → `localDeleted` (self-heals when full access returns);
  - not backed up, with a key → binned, then #1;
  - **no key → `store.remove`** (`photo_library_service.dart:460-465`): row, albums, people and captions gone with no bin.
- The same applies to any asset `fromId` won't resolve under default fetch options (e.g. hidden in Apple Photos). That's PLAUSIBLE; it depends on photo_manager's fetch options.
- `_markGone`'s `remove` branch contradicts its own doc (`:321-326`, "never by deleting the row … can come back out of the OS's Recently Deleted"). `hasNothingLeft` (`asset_record.dart:226-231`) also ignores the cached thumbnail that README `photos` says it checks.
  - With **no bucket configured**, every photo deleted in Photos loses its metadata immediately.
- Also `_stillInLibrary` treats an exception as "gone" (`photo_library_service.dart:371-377`). That's the opposite of `AssetRemoval._goneFromLibrary` and `_missingFromLibrary`.
- Fix:
  - `_reconcileMissing` only with `PhotoLibraryAccess.granted`.
  - `_markGone` always soft-deletes (bin) instead of `remove`.
  - A failed lookup means "still there".

### 3. Finish Optimize reports "fixed" when the swap is only filed; the outcome is reported under another id — CONFIRMED
- `RecordFixer.finishOptimize` returns `FixOutcome.removed` right after `fileCopies` (`record_fixer.dart:521-531`), so `_runOnRecord` resolves `leftoverCopy:<id>` / `extraCopies:<id>` (`fix_queue.dart:872-873`).
- `_finishSwaps` reports by `storageFlagId(localId)` = `asset:<id>` (`fix_queue.dart:654`). No job has that id, so `_resolve` and `_fail` are no-ops (`:887-888`, `:900`).
- Declining the iOS prompt leaves both copies in Photos, and the page still says the items were fixed. "Freed" counts only the storage-flag swaps.
- Fix: return a `filed` outcome that keeps the job `running`, and have `finishSwaps` report the **flag id** stored in the swap entry (`'flag': flag.id`).

### 4. Concurrent Finish Optimize jobs lose each other's swaps — CONFIRMED
- Record jobs run 4 at a time (`fix_queue.dart:572,606,625`). Each `fileFoundCopies` → `_addSwaps` is read-modify-write on `pending_swaps_v1` (`storage_optimizer.dart:490-493`, `:582-602`).
- Two jobs both read `[]` and each writes its own one-element list, so up to 3 of 4 swaps vanish. All 4 report fixed (#3), and the vanished ones come back on the next scan, which is the "re-offer" seen.
- Fix: serialise `_addSwaps` with a lock (one `Future` chain), or keep swaps in a table with one row per swap.

### 5. A queue resumed with filed swaps stops, and its jobs never run — CONFIRMED
- `FixQueue.resume` calls `unawaited(_pump())` when swaps are pending (`fix_queue.dart:455`). `_pump` finds no jobs yet, leaves its loop and awaits `_finishSwaps`, which is the iOS prompt at launch.
- Meanwhile `resume` goes on to `enqueue` the persisted jobs (`:530`). `_pump()` returns because `_pumping` is set, and after the prompt `_pump` exits without looping back. The restored jobs stay `waiting` until the user enqueues something else.
- Resumed `finishOptimize`/`removeExtraCopies` jobs then fail "rescan first", because `_copies` is per-process (`record_fixer.dart:79,524-526`).
- Fix: in `_pump`, loop `while (batch non-empty || new jobs)` after `_finishSwaps`, or call `_pump()` again in `finally` if anything is waiting. Persist the pair (original, copy asset) in the job row, not in `_copies`.

### 6. A kill during `finishSwaps` re-prompts to delete the **copies** — CONFIRMED (logic), PLAUSIBLE (timing)
- `finishSwaps` deletes whatever each record's `libraryId` is *now* (`storage_optimizer.dart:504-516`). It re-points records one by one (`:542-549`) and clears the file only at the end (`:555`).
- If the app is killed in that loop, the next launch's prompt targets the records already re-pointed, i.e. the smaller copies, now the only local version. If accepted, `_dropCopyRecord` finds the keeper itself, and the record ends up pointing at a deleted asset → `_markGone` → cloud-only.
- Fix: store the original's asset id in the swap entry and delete by that id. Remove each swap entry as it's applied, in the same transaction as `setLibraryId`.

### 7. Two records for one Photos asset, and "Remove extra copies" then deletes the keeper's own asset — CONFIRMED (logic), PLAUSIBLE (trigger)
- **How duplicates arise:** an asset this app creates is re-pointed only after the save returns: `putBack` (`library_custody.dart:356-366`), Optimize (`storage_optimizer.dart:543`). The OS change notification (`applyChange`, `photo_library_service.dart:293-296`) or a scan page can insert `photo:<newId>` first.
  - The new batch lookup widens the window: `known` is read once per 200-entity page (`:245`), and `_insert` → `upsert` checks only `local_id` (`asset_record_store.dart:1056`), never `library_id`. A swap re-pointing X to asset C mid-page gets `photo:C` inserted after `_dropCopyRecord` ran.
  - `putBack` has no `_dropCopyRecord` equivalent at all.
- **Then:** `_leftoverCopies` puts the stray row in X's group: same `createdAt`, `isCopy`, print distance 0, because it is the same picture. It's filed as an extra copy of X. `finishSwaps` deletes `photo:C`'s `libraryId` = C = **X's only local asset** (`storage_optimizer.dart:511`, `:538-540`).
- Device today: 0 duplicate `library_id`s, 195 re-pointed records.
- Fix:
  - `_insert` → `INSERT … WHERE NOT EXISTS (SELECT 1 FROM asset_record WHERE library_id = ?)`.
  - Re-check `getByLibraryId(entity.id)` just before the insert.
  - In `_leftoverCopies`/`finishSwaps`, never file an entry whose `libraryId` equals a keeper's or another swap's asset.
  - Give `putBack` the same drop-the-stray step.

### 8. Swaps delete originals from Photos on an old or cached proof of backup — PLAUSIBLE
- Optimize swaps are verified once, at `apply` (`_unconfirmed`, `storage_optimizer.dart:222-259`). The prompt comes at the end of the run, or at a later launch.
- Found copies (`fileFoundCopies`) are never verified live. `_leftoverCopies` checks only `listed.containsKey(key)` from the cached listing (`record_fixer.dart:430-433`, `:485-487`).
- After a bucket loss like Oct 13's, the full-quality original leaves Photos and only the 2560-px copy remains.
- Fix: `verifier.proveOriginal` for every swap right before `deleteManyFromLibrary` in `finishSwaps`. Drop the unproven ones and report them as `unverified`.

### 9. Remove Duplicate never checks that the kept copy still exists — PLAUSIBLE
- `duplicates()` groups by `backedUpHash` and keeps the favourite or oldest (`storage_advice.dart:370-398`). The kept copy may be cloud-only, and its bucket original may be lost.
- `apply` leaves `removeDuplicate` out of `_unconfirmed` (`storage_optimizer.dart:226-231`).
- The duplicate's asset leaves Photos. 30 days later `expireBin` deletes its bucket objects under its own keys, which `keyHeldByOthers` doesn't protect.
- Fix: require the kept copy to have a local original or a live `proveOriginal` before offering or applying. Never auto-expire a duplicate whose kept copy is `localDeleted` without a proof.

### 10. A restore onto a new phone duplicates the whole library — PLAUSIBLE (cross-ref 03)
- `app_snapshot.dart:325` restores `libraryId` as-is. PhotoKit `localIdentifier`s are per device.
- On a new phone the full scan inserts every asset as a new `photo:<id>` (`_insert`). `_reconcileDeletions` then marks every restored row gone: cloud-only if backed up, binned or removed if not.
- Result: two of every photo, with the captions, albums and people on the cloud-only twin.
- Fix: on a fresh restore, match by `createdAt` + pixel size (+ print) before inserting, or adopt by `cloudIdentifier` where available.

## P2

11. **Re-encoding an app-held Live Photo orphans its motion.** CONFIRMED.
    - `_rewrite` (`storage_optimizer.dart:262-304`) moves `sourcePath` to `$hash.webp`. The `.live.mov` stays keyed to the old path (`PhotoLibraryService.heldLiveVideoPath`).
    - The viewer then falls back to a bucket download. Hiding it later goes silent (`_holdMotion`), and the old `.mov` leaks on disk.
    - Fix: rename the held `.mov` with the still, or skip `isLivePhoto` the way `isHeifCandidate` does.
12. **`createdAt` is never re-read from Photos.** CONFIRMED.
    - `_applyPage` / `applyChange` fill only coordinates and size (`photo_library_service.dart:404-424`). A date fixed in Apple Photos never reaches the record.
    - A Live Photo saved with `saveLivePhoto` and then `updateCreationDate` (`library_custody.dart:86-104`, `storage_optimizer.dart:892-905`) is recorded by `applyChange` with the save-time date if the notification wins.
    - Fix: refresh `createdAt` from the entity when it differs and the user hasn't edited the date here.
13. **`_deleteFromLibrary` treats an exception as "deleted".** CONFIRMED (`asset_removal.dart:390-401`).
    - On a PhotoKit error, `deletePermanently` purges the row and queues bucket deletes while the photo stays in Photos. The next scan re-adds it bare.
    - Fix: an exception means "not deleted".
14. **Lost update in `markSmallestAlready`.** CONFIRMED.
    - It's called `unawaited` per item inside one batch's `onItem` (`fix_queue.dart:771`). Each call re-reads `_smallest` from disk inside `_loadRemoteDone` (`storage_advice.dart:335-347`), so concurrent calls overwrite each other. "Not smaller" photos are re-offered Optimize.
    - Fix: serialise, or add to the in-memory set and write once per batch.
15. **O(bucket)/O(library) per fix item on the UI isolate.** CONFIRMED.
    - `markRemoteOptimized` → `_loadRemoteDone` reads all ~11k `bucket_object` rows on every Optimize-in-bucket item (`storage_advice.dart:360`).
    - `_runOnDevice` re-reads `storage_scan_v1` (220 KB JSON), runs `listAll` and rewrites it per batch (`fix_queue.dart:790`).
    - The flagged page's `_derive` regroups and re-estimates every flag on each queue notify, i.e. per item (`flagged_items_screen.dart:81,238-300`).
    - Fix: load once per run, and debounce `_derive`.
16. **`_leftoverCopies` pairs without pictures.** PLAUSIBLE.
    - With a print missing and one original, the distance defaults to `_sameFrame` (`record_fixer.dart:412-416`).
    - An unrelated 2560-px export, or a 1080p "Save as New Clip" video, with the same capture ms and aspect, arriving more than a day later, is filed as a copy. Finish Optimize then deletes the full original from Photos.
    - Fix: require both prints. For video, also require the same duration.
17. **The pending-swap prompt fires at launch with no context.** CONFIRMED (`fix_queue.dart:455`).
    - A system "delete N photos" sheet appears before any UI explains it. Users decline, which leaves both copies (#3).
    - Fix: ask from the Flagged Items banner instead.

## P3

18. Sync file I/O on the UI isolate without call-site notes: `existsSync` in `_hasThumbnail` / `_localPathOf` (`storage_optimizer.dart:845,855`, per item up to 100) and `AssetRemoval.localPathOf` (`asset_removal.dart:408`).
19. `_dropCopyRecord` discards the copy record's own tags, albums and people with no merge (`storage_optimizer.dart:563-578`).
20. `LibraryScanner.running` is set but never read (`library_scanner.dart:36`). `_syncingRecent` / `_syncingLibrary` duplicate the scanner's own single-flight.
21. `PhotoLibraryService` doc drift:
    - `entityFor`'s doc is glued onto `durationOf` (`:472-478`).
    - `_reconcileDeletions` says "never by deleting the row" (see #2).
    - README `photos` describes `hasNothingLeft` as checking the thumbnail; it doesn't.
22. The uncommitted change is fine as written. `_scanRecentThenAll` serialises the lanes, `getByLibraryIds` keeps the old `getByLibraryId` semantics, and the index is idempotent. But it widens #7's window, and `if (out.containsKey(id)) continue` silently picks one of several rows for the same id.

## Improvement suggestions

**Flagged Items as one scan, where "fixed" means the detector no longer fires.**
- **One detector.** `FlagScan.run()` produces one `List<Flag>` from storage, duplicates, cloud-only, records and bucket. It runs in one isolate hop over one snapshot (`listAll` + `listBucketObjects` + `storage_scan_v1` sizes). Persist it in app state with the snapshot's `rev` (see 01 #1), and show the page from it. That ends the flicker of four loaders landing at different times (e.g. storage Optimize rows showing until `_loadRecords` hides them).
- **Fixers change facts, not flags.** Each fixer returns `done | filed | failed(reason)`. `filed` (swaps) keeps the job `running` until `finishSwaps` reports by the flag id stored in the swap.
- **After every run (and after `finishSwaps`), re-run the detector** over the touched ids only. Records are already in memory, and the listing is refreshed once. A flag that's still detected comes back as `failed: still detected`.
- **Drop `_resolved`.** Keep only `_kept` ("Hide from list"), which is a user choice and persisted. Nothing else is remembered, so a relaunch can't re-offer what was fixed, and a declined prompt shows up as the flag still being there.
- **Make job inputs self-contained.** Persist the original and copy asset ids in the job, so a resumed Finish Optimize needs no `_copies`.

**Library sync**
- Make it a rule: absence never deletes.
  - `_markGone` only bins.
  - Reconcile and tile-missing run only with full access, and only after a second positive "not found".
  - The scan un-bins anything it lists that the library put in the bin.
- Make `library_id` unique: a partial unique index, plus `INSERT OR IGNORE` in `_insert`. Then the stray-copy class (#7) can't exist, and `_dropCopyRecord` becomes a safety net.
- Store per-swap state (`old_asset`, `new_asset`, `flag`, `proved_at`) in a table instead of one JSON blob. This fixes #4, #6 and #8 together.

## Checked and fine

- `syncRecent`'s bounded reconcile: `newerThan` plus `_stillInLibrary` covers page shifts and records whose date differs from Photos.
- `syncAll` / `syncRecent` reconcile is gated on `PhotoLibraryAccess.granted` at both call sites.
- Hidden rows (`libraryId == null && sourcePath != null`) are skipped in reconcile; `_markGone` skips app-held files.
- `LibraryCustody.takeOutMany` copies and verifies (non-zero, motion too) before the delete, and a declined prompt keeps the copy and the library id.
- `AssetRemoval.removeFromDevice` uses a live HEAD for the original, the motion half and the thumbnail before deleting, and a declined prompt doesn't set `localDeleted`. The lock is honoured on every path.
- `isRecoverable` / `_goneFromLibrary`: an unreadable library counts as present.
- `StorageOptimizer._replaceInLibrary` (non-deferred): a declined prompt deletes only the new copies.
- `finishSwaps`: copies with `keep: true` survive a decline, and a swap filed twice orphans only the second copy.
- `_rewrite`/`_compressOwned` write the new file before deleting the old, and only for backed-up records (`_fixesFor` gate) with a `reconcile` check.
- `adviseOn` / `worthMeasuring` exclude hidden, locked, binned and cloud-only records; Live Photos need both halves backed up.
- `StorageAdvisor.cached()` re-advises from the live record, so a stale size never offers a fix already done.
- `FixRates`: per-kind tallies, learned rates only after 3 samples.
- `PhotoLibraryChange.parse` is defensive and returns null on a malformed payload.
- `derived_asset` / `smaller_export`: edits land as new records, encoding is native file-to-file, and nothing is decoded on the UI isolate.
- `library_metadata`: local write first, library write best-effort.
- Repo rules in scope: no `img.decodeImage`, no `material.dart`. `RecordFixer` prints and stat checks run in `Isolate.run`. No Dart HTTP bodies.
