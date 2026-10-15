# 01 Storage — findings

Scope: `lib/storage/`, plus `lib/backup/change_log.dart` (its triggers live in these DBs).
Device evidence: copy of `/tmp/pv_pull2/photos_vault.db` (Oct 14, v19, 4514 records).
Lines refer to the working tree (uncommitted `getByLibraryIds` + `library_id` index included).

## P1

### 1. `listAll` misses rows inserted with a back-dated `updated_at` — CONFIRMED
- `asset_record_store.dart:1072,1087-1088`: `upsert` writes `updated_at = createdAt ?? addedAt`, not now.
- `asset_record_store.dart:1601-1605`: incremental read is `updated_at >= _cachedThrough` (max `updated_at` seen).
- Callers pass old dates: `photo_library_service.dart:389` (`entity.createDateTime`), `manual_add.dart:81`, `filed_photos.dart:100`, `app_snapshot.dart:323`, `demo_seed.dart:92`.
- Failures:
  - Fresh install: `syncAll` pages newest-first (`photo_library_service.dart:104`), `onPage` reloads (`library_screen.dart:947`). Page 1 sets the mark to the newest capture date; pages 2+ are older → never in `_all` → no thumbnails either (`_cacheMissingThumbnails` reads `_all`), so nothing bumps them. Grid shows ~200 photos until relaunch, unless a backup job happens to touch the row.
  - Photo arriving with an older capture date (iCloud from another device, AirDrop, manual import of an old file) after any write: invisible until relaunch.
  - Photo with a future EXIF date: the mark jumps ahead, so no `now`-stamped write (favorite, trash, thumbnail) shows until relaunch.
- Test gap: `asset_record_store_test.dart:482` only upserts with no `createdAt`.
- Fix: `updated_at` always `DateTime.now()` on insert; clamp `_cachedThrough` to `now`. Better still: a monotonic `rev INTEGER` column (`MAX(rev)+1`) instead of wall-clock time.

### 2. A staged bucket listing brings back objects that were just forgotten or moved — CONFIRMED (mechanism), impact PLAUSIBLE
- `forgetBucketObject` / `moveBucketObject` (`:626-652`) touch only `bucket_object`. `commitBucketScan` (`:561-586`) then swaps in `bucket_scan_object` wholesale.
- Scan pages are resumable for 30 min across launches (`:502`, `bucket_import.dart:49-69`).
- Scenario: a refresh stages `originals/` (contains K). User deletes K in Flagged Items → forgotten. Refresh commits → K is listed again. With `moveBucketObject(from→to)`, the commit restores `from` and drops `to`. So the new original looks missing → requeued, and the old key looks unclaimed.
- This breaks the invariant from fce0053 ("a file the bucket no longer has … leaves the listing"). Step 02: check every delete/offer path that reads the listing (`backup_coordinator.dart:231` `_leftovers` uses `listedSiblings`).
- Fix: apply forget/move to `bucket_scan_object` in the same transaction. Or keep a `bucket_tombstone(target,key,at)` and skip tombstones newer than the scan's `started_at` at commit.

## P2

### 3. `upsert` check-then-insert race aborts a scan — PLAUSIBLE
- `:1056` reads, `:1073` inserts with no conflict clause. The recent lane, full lane and `applyChange` run concurrently by design (`library_scanner.dart:51-63`).
- On a fresh install both lanes read the same newest page: both `getByLocalId` return null, so the second insert throws UNIQUE. `syncAll` aborts (swallowed in `_syncPhotoLibrary`) and the full scan restarts on a later round.
- Fix: `INSERT … ON CONFLICT(local_id) DO NOTHING`, then re-read. Or serialise inserts per localId.

### 4. Each change rebuilds the whole library list on the UI isolate — CONFIRMED
- `_rebuildSorted` (`:1638-1642`) re-runs `_fromRow` on every cached row and re-sorts, after any moved row (`:1612`) and after every `remove` (`:1672`).
- One favorite or thumbnail write costs O(library). "Empty Recently Deleted" (`asset_removal.dart:266` → `purge` → `remove` per record) costs O(N × library).
- This breaks the CLAUDE.md rule against work proportional to library size.
- Fix: cache `AssetRecord` per id next to the row and rebuild only the moved ones. Patch the sorted list (binary insert, or re-sort only when `created_at` changed). Add `removeMany` with a single rebuild.

### 5. Change-log churn: container rehome floods the log and defeats the "changed?" gate — CONFIRMED
- `_rehomePaths` (`:321-367`) rewrites `thumbnail_path` for every row on each install (new container UUID). Every update logs the full row twice (~2.7 KB).
- Device: 4 bursts of ~4,390 rows on Oct 14 = 17.5k of the 20k kept entries. The log covers only 18 h (`change_log` 02:47→20:43). 95% of the last 3,000 updates are path-only.
- Consequences:
  - User edits are pruned before the daily snapshot. That breaks the "nothing between snapshots is unrecoverable" goal.
  - The mark (395,941) moves on bookkeeping writes (paths, upload status), so the iCloud/vault/bucket daily copies never skip.
- `rebaseContainerPath` (`_fromRow` `:1755-1756`) already fixes paths at read time, so persisting the rehome is redundant for container moves.
- Fix:
  - Persist only paths that `rebaseContainerPath` can't fix (no container marker), or store container-relative paths.
  - Add a trigger `WHEN` clause, or a column allow-list, so bookkeeping columns (`*_status/_key/_hash`, `thumbnail_path`, `source_path`, `updated_at`, `local_*`) don't log.

### 6. Rehome on open blocks the first grid read after every install — CONFIRMED
- Inside `_openOnce` before `_db` is set: ~4.4k async `File.exists` plus a 4.4k-row update transaction firing 4.4k JSON triggers. Every first `listAll` waits on it.
- Same fix as #5.

### 7. DB file is 2/3 free pages, then copied raw up to 10 times — CONFIRMED (size), PLAUSIBLE (torn copy)
- Device file: 303 MB, 51,065 of 74,041 pages free. `auto_vacuum=0`, and there is no `VACUUM` anywhere in `lib/`.
- `LocalVault` copies the raw file (`local_vault.dart:218-220`): 7 daily + 3 pre-deletion copies ≈ 3 GB in Application Support, which also goes into the iCloud device backup.
- `File.copy` of an open DB in `journal_mode=delete` (device; not WAL) can catch a half-written page.
- After a wipe, deleted rows (paths, captions, hidden rows) stay readable in free pages.
- Fix: `VACUUM INTO '<copy>'` for copies (compact and consistent). A one-time `VACUUM` after the first big prune. `PRAGMA auto_vacuum=INCREMENTAL` (needs one VACUUM) + `incremental_vacuum` after `pruneChangeLog`. `secure_delete` or `VACUUM` in `clearAll`.

### 8. Album and person change logs are never pruned — CONFIRMED
- `pruneChangeLog` is called only from `asset_record_store.dart:213`. `album_store.dart:78` and `person_store.dart:187` (8 tables, face-driven memberships) grow forever and ride every raw copy.
- Fix: same delayed prune in both `_open`s.

### 9. Missing indexes on hot or looped queries — CONFIRMED
- `listAll` incremental `updated_at >= ?` is a full scan on every reload → index `updated_at`.
- `keyHeldByOthers` (`:869-881`): unindexed `derivative_target.destination_key` + 4 OR'd `*_key` columns, called per pending delete (`pending_deletes.dart:231`) and per sibling (`backup_coordinator.dart:234`) → O(N×library) on a bulk delete. Index `derivative_target(destination_key)` and each `asset_record.*_key`, or one batched query.
- `originalStemHeld` GLOB: same tables, same fix.
- Device DB has only autoindexes. The `library_id` index is uncommitted and not yet on the phone.

### 10. Migration v16 `_adoptExistingUploads` is a no-op — CONFIRMED
- `:733,742` read `${prefix}_destination_key` / `${prefix}_backed_up_hash`, but the columns are `${prefix}_key` / `${prefix}_hash` (`_fromRow` `:1735-1736`). Wrong since 45742d1.
- Upgrades from <16 got no legacy rows (device: 0 rows with `target_id=''`). So the `legacy` path (`backup_coordinator.dart:337`) is dead, and a retry re-uploads to targets that already hold the file. Restore falls back to the record key, so nothing is lost.
- Fix: correct the names, plus a one-time backfill keyed in `app_state`. Add an `onUpgrade` test from v15.

### 11. `clearAll` keeps the bucket listing — PLAUSIBLE (privacy-lite)
- `:827-838` leaves `bucket_object`, `bucket_scan`, `bucket_scan_object`. The wipe also forgets targets, and `_forgetRemoved` skips an empty target list (`bucket_import.dart:84`), so 11k object keys (capture stamps + hashes) stay indefinitely.
- Fix: clear all three in `clearAll`.

## P3

12. Unstable sort ties — PLAUSIBLE. `_rebuildSorted` (`:1640`) sorts only on `createdAt`, and Dart's `sort` isn't stable. Burst frames share a capture second and can swap places between reloads. Tie-break on `localId`, and do the same in the SQL `orderBy` (`:1594`).
13. `_undoRedate` (`:263-303`) reverts every `created_at` change on hidden/vault rows, including a deliberate user date edit made before the upgrade. It runs once and has already run on the device (`imports_redate_undone_v1`). Historic; note for step 03.
14. `AlbumStore`:
    - `_open` (`:28`) has no single-flight (unlike `AssetRecordStore._open`).
    - `remove` (`:259-263`) is two non-atomic deletes.
    - `album_asset` has no `local_id` index (`albumIdsContaining`, `forgetAssets`).
15. Doc drift:
    - README: names `private_album.dart` / `private_album_store.dart` (gone) and says `listAll` heals per record (it doesn't).
    - Orphaned doc comments at `:865-866` (belongs to `uploadRows`) and `:1366-1368` (belongs to `getByLibraryId`).
    - `_rehomePaths` says "one indexed query", but `NOT LIKE` is a full scan.
    - `checkpointedFile` assumes WAL; the device DB is `delete`.
16. `onUpgrade` blocks are out of numeric order (`<14`, `<13`, `<11`, …, `<10` last). It's correct today (no block depends on a later one) but fragile, and there are no migration tests at all.
17. The cache is per instance. `background_sync.dart:116` and `demo_seed.dart:38` make their own `AssetRecordStore`, so a `remove` there wouldn't leave the UI store's cache. No such remove exists today; document it or make the store a process singleton.
18. `allTags` (`:1496`) reads and JSON-decodes every row each time the picker opens. Add `WHERE tags != '[]'`.
19. Clock: every write stamps `DateTime.now()`, so a device clock set backwards hides writes from `listAll` until relaunch. Fixed by the `rev` column from #1.

## Improvement suggestions
- One `rev` counter (#1) replaces wall-clock high-water marks, and also gives the snapshot gate a "user-visible change" mark if bookkeeping writes don't bump it.
- Log only user-authored columns (#5). That makes `pruneChangeLog`'s 20k cap meaningful and shrinks the DB about 10×.
- `VACUUM INTO` for every DB copy (#7). It removes the torn-copy risk and roughly 200 MB per copy.
- Batched store APIs where callers loop: `removeMany`, `keysHeldByOthers(Set)`.
- A migration test matrix: open a v1/v10/v15/v18 fixture, upgrade, and compare `PRAGMA table_info` against a fresh `onCreate`.

## Checked and fine
- `onCreate` vs `onUpgrade` column sets agree (diffed against the v1 schema at cf4e625); every table is created on both paths.
- `_open` single-flight and its error retry are correct; `installChangeLog` runs in a transaction.
- The `listAll` cache vs a concurrent `remove`: sqflite's FIFO order keeps the deleted row out of the cache in both interleavings.
- `>=` plus `_sameRow` covers writes in the same millisecond.
- `remove` is atomic (batch = transaction) and records `removed:` for the membership sweep.
- `stageBucketPage` writes page and token in one transaction; `refresh` is serialised process-wide.
- `getByLibraryIds` stays within the parameter limit (400×2); `OR` across the indexed `library_id` / PK is usable.
- `rebaseContainerPath` does no I/O (uses `systemTemp`); `_healed` uses async `exists`.
- `keyHeldByOthers` counts soft-deleted and hidden rows as holders (safe-by-default).
- `pruneChangeLog` works in slices with yields and leaves the max seq (the mark) alone.
- `sweepOrphanMemberships` is guarded by `RestoreGuard` generation, runs once, and skips an empty store.
- `hashPasscode`: unsalted SHA-256. Step 03 should judge it.
- Repo rules: no image decode, no `material.dart`; the only sync I/O is a single `existsSync` in `checkpointedFile`.
