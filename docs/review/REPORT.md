# Code Review Report — Oct 2026

Synthesis of `findings/01`–`09`. Source refs are `NN#k` (step NN, finding k). C = CONFIRMED, P = PLAUSIBLE.

## 1. Totals

As filed per step (before dedupe):

| Step | P0 | P1 | P2 | P3 | Total |
|---|---|---|---|---|---|
| 01 Storage | 0 | 2 | 9 | 8 | 19 |
| 02 Upload & bucket | 2 | 7 | 8 | 10 | 27 |
| 03 Vault & backup | 4 | 6 | 6 | 6 | 22 |
| 04 Library sync & fixes | 0 | 10 | 7 | 5 | 22 |
| 05 Analysis, faces | 2 | 8 | 10 | 9 | 29 |
| 06 Home & grid | 0 | 5 | 8 | 11 | 24 |
| 07 Other screens | 4 | 8 | 12 | 11 | 35 |
| 08 Settings, shell | 1 | 4 | 2 | 10 | 17 |
| 09 Cross-cutting | 0 | 1 | 3 | 5 | 9 |
| **Total** | **13** | **51** | **65** | **75** | **204** |

After dedupe: **12 unique P0** (03#3 = 07#1), **50 unique P1** (07#11 = 05#2 + 05#3). Known P2/P3 dupes: 07#20 = 05#16, 07#32 ≈ 05#17, 03#13 ≈ 02#7, 07#27 folds into P0-1.

## 2. P0 (deduplicated)

| # | What goes wrong | Status | Main site | Sources |
|---|---|---|---|---|
| P0-1 | Hidden/binned photos open outside the gate from Favorites, person pages, avatars; People counts leak hidden count | C | `viewer/favorites_screen.dart:35-40`, `person_page_screen.dart:63-67`, `person_avatar.dart:58-60` | 03#3, 07#1, 07#27 |
| P0-2 | "Who else looks like this?" lists hidden/binned/purged faces preselected; Save links them to a person (face rows never deleted on hide/purge) | C (path) | `photos/face_grouping.dart:86-99,138-143`, `viewer/face_group_screen.dart:103-124,190-222` | 05#2, 07#11 |
| P0-3 | Every app-data copy (Files-visible zip, raw `.db` copies, public iCloud folder, bucket `app-data/`) holds hidden rows, reversible unsalted `sha256(4 digits)` codes, carrier keys, face vectors; change log keeps them after delete; free pages keep wiped rows | C | `backup/app_snapshot.dart:217-218,259-303`, `storage/passcode_hash.dart:8`, `ios/Runner/Info.plist:45,55,98` | 03#1, 05#29, 01#7 |
| P0-4 | Plaintext hidden originals and old thumbnails sit in AppSupport root (iOS-backed-up, telling names); 8/127 hidden rows still have a thumbnail | C | `photos/library_custody.dart:300-322`, `vault/filed_photos.dart:235-242`, `vault/store.dart:101-109` | 03#2 |
| P0-5 | Nothing writes `index.bin` since 9d98f57; new phone mints a new salt, old passphrase opens nothing → hidden photos unrecoverable from bucket | C (path) | `vault/keys.dart:115`, `vault/bucket.dart:134-136`, `private_album_screen.dart:1349-1357` | 03#4 |
| P0-6 | Re-format treats a failed header read as "not a carrier" → re-encodes a hidden carrier and deletes the original | P (path C) | `upload/bucket_flagged.dart:629-638,725-793` | 02#1 |
| P0-7 | Video "old copy" decided by same capture second + size; Fix All deletes another phone's only clip | P (path C) | `upload/bucket_flagged.dart:171-195,939-959`, `photos/fix_queue.dart:134` | 02#2 |
| P0-8 | "Ask AI about this photo" sends photo + date/place/caption to a vendor; contradicts store listing; not gated for China or hidden photos | C | `viewer/detail_screen.dart:1949-1977`, `viewer/ask_ai_screen.dart:78-82` | 05#1 (+05#9, 08#4) |
| P0-9 | Safety "Check Now" counts hidden rows → reveals hidden-photo count | C | `upload/backup_verifier.dart:384-387`, `viewer/safety_screen.dart:253-261` | 07#2 |
| P0-10 | Edits inside a sealed person set are written to the open set in plaintext | C | `photos/person_store.dart:740,829,962`, `viewer/person_profile_screen.dart:256-280,422-466,556-563`, `person_history_detail_screen.dart:52-55` | 07#3 |
| P0-11 | Deleting a person orphans their hidden folder forever (code is `person:<id>:<digits>`) | C (path) | `viewer/person_profile_screen.dart:722-748`, `private_album_gate.dart:288` | 07#4 |
| P0-12 | "Remove All App Data" with a failing DB read keeps nothing → deletes every never-backed-up import/edit/hidden plaintext | C (logic), P (trigger) | `settings/app_data_removal.dart:183-198,276-290` | 08#1 |

## 3. P1 (deduplicated, by theme)

**Data loss in bucket**
- Rename/Import treats unreadable header as "not a carrier" → hidden photo imported as decoy, later deleted. P. 02#3
- `healPrefixes` re-points keys on stale listing; Live `.mov` → still; newer edit becomes `oldCopy` and Fix All deletes it. C/P. 02#5
- Bucket browser deletes any key with generic confirm, no holder/carrier check. C. 02#8
- "Never send shrunken copy over original" trusts cached listing → overwrite or `oldCopy` delete. P. 02#9
- HiddenMigration deletes old names on every target even where copy was skipped (HEAD timeout) → motion lost. C/P. 03#5
- Torn `index.bin` write pushed to every bucket → all album listings/passphrase entries wiped. P. 03#7
- Un-hide uploads plain photo over its own carrier key; `.mov` orphaned (device-proven on `photo:EA10C64A…`). C. 03#9b, 04 lead, 02#27, part of 02#4
- Hide deletes plain bucket copy before carrier is up. C (spot-checked `private_album_gate.dart:669-677`). 07#5
- Optimize in bucket / Re-format overwrite originals with no permanent-action confirm, all rows ticked, cloud-only included. C. 07#7 (+02#12)
- Photo back in Photos stays binned; 30-day purge deletes its bucket copies and metadata. C. 04#1
- Remove Duplicate never checks kept copy exists; expiry then deletes duplicate's bucket objects. P. 04#9

**Data loss on phone / Photos**
- One failed `fromId` (limited access) marks gone; no-key rows `store.remove`d outright; `_stillInLibrary` exception = gone. C/P. 04#2 (+07#17)
- Kill during `finishSwaps` → next prompt deletes the copies (now only local version). C/P. 04#6
- Two records for one asset (insert races re-point; widened by uncommitted batch lookup) → "Remove extra copies" deletes keeper's own asset. C/P. 04#7, 04#22
- Swaps delete originals from Photos on an old/cached backup proof. P. 04#8
- Manual add can point a record at a half-copied file. C/P. 05#10
- "Move to Library" iterates live selection set → partial un-hide, double `putBack`. C. 07#6

**Hidden / privacy leaks**
- Remove All App Data (keep hidden) orphans un-backed-up hidden photos in plaintext. C. 03#9
- Adopted filed photo keeps its index entry → deleted/un-hidden photo comes back; second carrier left in bucket. C. 03#6
- Derived copy (resize/edit) of a hidden photo briefly an ordinary record (grid, plain upload). P. 07#12
- Dormant pending deletes never run after re-adding same bucket (new UUID) → hidden plaintext copies stay. C. 08#3
- In-app privacy/hidden-album/AI text contradicts code. C. 08#4
- Release with `.env.demo` ships demo S3 secret + AI key; any user can enter demo mode on a shared bucket. P. 08#5

**Flagged Items correctness**
- Live Photo halves: detector vs `adopt` disagree → second half offered forever; concurrent adopt of both halves. C. 02#4
- Finish Optimize reports "fixed" when only filed; outcome reported under wrong id. C. 04#3
- Concurrent Finish Optimize jobs lose each other's swaps (RMW on `pending_swaps_v1`). C. 04#4
- Resumed queue with filed swaps stops; restored jobs never run; `_copies` per-process. C. 04#5
- Queued fix acts on page-load record → locked file re-encoded; hidden row binned. C/P. 07#8
- Page never refreshes while open (stale "waiting for N backups"). C. 07#9

**Sync / library correctness**
- `listAll` misses rows with back-dated `updated_at` → fresh install shows ~200 photos until relaunch. C. 01#1
- Staged bucket listing resurrects forgotten/moved objects (breaks fce0053 invariant). C/P. 01#2
- Two overlapping `reload()`s draw an older library. C. 06#1

**Faces / analysis**
- "Find more of Alice" seeds from everyone's faces, files result as Alice. C. 05#3 (07#11)
- Re-describing a stale face erases its name (`replace` nulls `person_id`). C. 05#4
- SFace load failure → pipeline 3 always stale → endless re-match. C/P. 05#5
- Analyze pass stalls when newest 60 jobs can't complete. C/P. 05#6
- Face boxes from un-rotated buffer; crops/avatars wrong on portrait shots. P. 05#7
- One failed geocode marks a 5 km cell empty forever; fill stalls. C. 05#8
- Ask AI sends WebP/HEIC labelled `image/jpeg` (moot if P0-8 removes it). C/P. 05#9

**Backup / restore**
- Background backup starves (capacity counts all kinds); Sync Now queues change checks before new photos. C. 02#6
- Whole originals/carriers downloaded via Dart `http` into memory, no timeout. C. 02#7 (+03#13)
- Fresh-install restore >10 s races the scan; add-only import drops captions/tags/favourites/upload state. P. 03#8
- New phone: restored `libraryId`s don't match → whole library duplicated. P. 04#10
- Keychain `WhenUnlocked` → background pass skips while phone locked (overnight). C/P. 08#2
- iCloud restore reads a not-yet-downloaded file / `.icloud` placeholder → nothing restored. P. 09#1

**UX bugs**
- (Uncommitted) search results drawn above the screen when resting on Albums; header under search field. C. 06#2
- Search matches PhotoKit UUIDs, not captions/tags/places. C. 06#3
- Rotation loses scroll position. C. 06#4
- `markedId` never reaches the tile. C. 06#5
- Safety page shows the same "N of M" under every bucket. C. 07#10

## 4. Systemic causes

| # | Cause | Structural fix | Closes |
|---|---|---|---|
| S1 | No single visibility predicate | `libraryVisible()` / `hidden(hash)` / `binned()` on the store, one SQL `WHERE`; `listAll` private to store/sync/backup; grep check for `listAll(` under `lib/viewer/` | P0-1, P0-2, P0-9, 02#23, 07#27, 07#29 |
| S2 | Cached/remembered answer trusted for a destructive act | `BucketOps.deleteGuarded(target,key,keep:)` (live HEAD of keeper, size/ETag, refuse if held); `LibraryCustody.deleteOriginals` re-proves live; sole DELETE paths | 02#5,#8,#9,#10,#16,#17,#18; 03#5,#12; 04#8,#9; 07#6,#8,#18 |
| S3 | "Unknown" collapses to absent/empty/false | Tri-state `Probe<T>` (present/absent/unknown, like `CopyProof`); unknown never deletes/imports/marks gone | P0-6, P0-12, 02#3,#11,#20; 03#14,#21; 04#2,#13; 05#8; 07#25 |
| S4 | Detector and fixer are separate code | One flag-kind object: `detect`, `fix`, live `stillApplies`; "done" = detector silent after fix; one `FlagScan` | 02#4; 04#3,#5,#15; 07#9,#13,#14,#15,#25 |
| S5 | Multi-step work in memory / non-atomic | Durable step journal (sqlite) for swaps, hide/unhide, migrations, restore; `writeAtomic`; one `SingleFlight`/coalescing helper | 03#7,#8; 04#4,#5,#6; 05#6,#10; 06#1; 07#15; 01#3 |
| S6 | Hidden lifecycle has no single owner | One `HiddenTransition` (hide/unhide/derive/remove) that sets state first, resets keys in one transaction, holds plain-copy deletes until carrier confirmed, drops face/thumbnail data | 03#2,#6,#9,#9b; 07#5,#12,#24; 05#2; 06#23 |
| S7 | Identity keys not stable/unique | Monotonic `rev` instead of wall-clock marks; unique `library_id`; target id derived from `(provider,bucket,prefix)`; cross-device match on restore | 01#1,#19; 04#7,#10; 08#3,#12 |
| S8 | Library recomputed on the UI isolate per screen | `LibraryIndex` built once per change in `Isolate.run`; screens never call `listAll` | 01#4; 02#13; 05#12,#17; 06#6,#7,#11; 07#14,#29,#32; 09#2 |
| S9 | Bodies over Dart `http`, no timeout | One `BucketReader` → `S3Downloader` to file; small reads via one `http` wrapper with mandatory timeout | 02#7,#14; 03#13; 09#2 |
| S10 | In-app claims drift from code | Claims list next to code (privacy page, hidden bullets, AI notes, listing), reviewed per PR | P0-8, 08#4, 03#20, 05#29 |
| S11 | Real SQL untested; delete tests run on a fake | Store contract suite on fake + real (ffi); schema upgrade matrix | 09#4, 01#10,#16 |

## 5. Fix order (work packages)

**WP0 — Gate the uncommitted Albums-home change** (before committing the working tree: `asset_record_store`, `photo_library_service`, `asset_grid_view`, `library_screen`)
- Closes: 06#2, 06#6, 06#23, 06#20, 06#14 (re-anchor only when target moved), 04#22 / narrows 04#7 (re-check `getByLibraryId` right before `_insert`).
- Effort S · Risk low.
- Tests: search while resting shows results on screen; `restInset` includes search bar; `backUpRecords` re-reads records (hidden row not queued); batch page with a concurrently re-pointed asset inserts no duplicate.

**WP1 — P0 one-liners (stop the bleeding)**
- Closes: P0-6 (`ok = !failed() && probe == null`, honour `known['c']`), P0-7 (videoTwin list-only/one-at-a-time), P0-8 (remove photo Ask AI; or gate `aiOffered && passcodeHash == null`), P0-9 (skip hidden in `reconcile`), P0-12 (`_onlyCopies` → null, skip delete), 07#7 (Optimize in bucket/Re-format permanent), 08#5 (no demo defines in release).
- Files: `bucket_flagged.dart`, `flagged_copy.dart`, `detail_screen.dart`, `backup_verifier.dart`, `app_data_removal.dart`, `scripts/release-ios.sh`, `Makefile`.
- Effort S · Risk low.
- Tests: probe-fail → no reformat; AppDataRemoval with throwing `listAll` deletes nothing; reconcile counts exclude hidden.

**WP2 — Visibility predicate + face data lifecycle**
- Closes: P0-1, P0-2, 05#3, 07#11, 07#21, 07#27, 07#29, 02#23, 05#16, 05#23.
- Files: `asset_record_store.dart`, `favorites_screen`, `person_page_screen`, `person_avatar*`, `people_screen`, `face_group_screen`, `face_grouping`, `ai_analysis_store`, `private_album_gate`.
- Effort M · Risk low-medium (filters could hide legit rows).
- Tests: seeded hidden favourite/face per entry point; `confirmedFacesFor(personId)`.

**WP3 — Bucket delete gateway + tri-state probes**
- Closes: 02#3,#5,#8,#9,#10,#11,#12,#14,#16,#17,#18,#20,#21; 03#5,#12,#14,#21; 07#24 (part).
- Files: `upload/bucket_ops.dart`, `bucket_flagged.dart`, `name_migration.dart`, `pending_deletes.dart`, `backup_coordinator.dart`, `vault/hidden_migration.dart`, `vault/gallery.dart`, `settings/bucket_browser_screen.dart`.
- Effort L · Risk medium (over-refusal leaves items offered; acceptable).
- Tests: contract suite on real SQL; HiddenMigration per-target skip; flag parity, unknown → no fix.

**WP4 — Hidden transitions (hide/unhide/derive journal)**
- Closes: 03#9b, 07#5, 07#6, 07#12, 07#24, 03#6, 03#9, 06#23.
- Files: `private_album_gate.dart`, `private_album_screen.dart`, `backup_coordinator.dart` (`safeFileName` never reuses hidden stem), `derived_asset.dart`, `filed_photos.dart`, `hidden_removal.dart`, `pending_deletes`, `app_data_removal.dart`.
- Plus one-time repair for rows keyed under a carrier stem (device `photo:EA10C64A…`) and the 4 adopted `manual:vault-*` rows.
- Effort L · Risk high (touches carriers; repair must list, not delete).
- Tests: hide/unhide journal resume; delete/un-hide of adopted row unlists all entries.

**WP5 — Hidden data at rest**
- Closes: P0-3, P0-4, 03#10, 01#7, 01#11, 05#29, 08#4 (text after code).
- Changes: hidden rows out of `export()`/change log or sealed; passcode tag → HMAC under keychain key (migrate on unlock); plaintext under `vault/plain/`; thumbnail sweep; `VACUUM INTO` for copies; `secure_delete`; rewrite privacy strings (en + zh).
- Files: `app_snapshot.dart`, `change_log.dart`, `local_vault.dart`, `passcode_hash.dart`, `library_custody.dart`, `filed_photos.dart`, `thumbnail_cache.dart`, `asset_record_store.dart`, `app_*.arb`.
- Effort L · Risk high (hash migration can lock users out; ship with dual-check period).
- Tests: export has no hidden row/hash/key; hidden files land under backup-excluded dir; un-hide moves them back.

**WP6 — Vault & person recoverability**
- Closes: P0-5, P0-10, P0-11, 03#7, 03#11, 03#17, 03#18, 07#19.
- Changes: publish `index.bin` on `VaultKeys.add` + first bucket contact; setup tries known entries before minting salt; atomic index write + length check; `PersonScope` required on every profile write; block person delete if a hidden folder exists; PBKDF2 in isolate.
- Files: `vault/keys.dart`, `bucket.dart`, `store.dart`, `album_index.dart`, `passphrase_sheet.dart`, `person_store.dart`, `person_profile_screen.dart`, `person_history_detail_screen.dart`.
- Effort M · Risk medium.
- Tests: index on empty install opens with passphrase; torn index refused; sealed edit stays sealed.

**WP7 — Absence never deletes (phone side)**
- Closes: 04#1, 04#2, 04#9, 04#13, 07#17, 07#18, 08#1 follow-up.
- Changes: `_reconcileMissing` only with full access + second check; `_markGone` only bins; scan un-bins library-binned rows (`binned_by`); exception = present / not deleted; Recently Deleted read-only, purge only shown ids.
- Files: `photo_library_service.dart`, `library_screen.dart`, `asset_grid.dart`, `asset_removal.dart`, `recently_deleted_screen.dart`, `storage_advice.dart`.
- Effort M · Risk low.
- Tests: limited access / lookup failure never marks gone; restored-in-Photos row is un-binned.

**WP8 — Optimize swap journal + unique `library_id`**
- Closes: 04#3,#4,#5,#6,#7,#8,#14,#16,#17,#19; 07#8, 07#13.
- Changes: `pending_swap` table (old_asset, new_asset, flag, proved_at), per-row delete in same txn as `setLibraryId`; live `proveOriginal` before PhotoKit delete; partial unique index on `library_id` + `INSERT OR IGNORE`; jobs re-read record (lock/hidden/binned); prompt from banner, not launch.
- Files: `storage_optimizer.dart`, `fix_queue.dart`, `record_fixer.dart`, `library_custody.dart`, `asset_record_store.dart`, `flagged_action_screen.dart`.
- Effort L · Risk medium (migration on existing swap JSON).
- Tests: kill mid-swap resumes correctly; concurrent filings all kept; duplicate-`library_id` insert refused.

**WP9 — Backup & restore reliability**
- Closes: 02#6, 02#7, 02#15, 03#8, 03#13, 03#15, 04#10, 08#2, 08#3, 08#12, 09#1, 09#2.
- Changes: keychain `first_unlock` + one-time migrate; per-kind capacity, uploads first; downloads to file via `S3Downloader`; restore blocks scan or merges; newest `exportedAt` across destinations; stable target id; iCloud `NSFileCoordinator`/`NSMetadataQuery`; one export per pause in isolate + background task.
- Files: `secure_store.dart`, `sync_queue.dart`, `sync_engine.dart`, `backup_verifier.dart`, `original_restore.dart`, `vault/bucket.dart`, `app_snapshot.dart`, `icloud_backup.dart`, `bucket_backup.dart`, `ICloudDriveChannel.swift`, `backup_targets_store.dart`, `library_screen.dart`.
- Effort L · Risk medium.
- Tests: restore + concurrent scan, no dupes, metadata kept; queue capacity per kind; re-added bucket runs dormant deletes.

**WP10 — Store revisions + reload pipeline**
- Closes: 01#1,#2,#3,#4,#5,#6,#8,#9,#10,#12,#19; 06#1,#7,#8,#11,#15; 05#12,#17.
- Changes: `rev` column; tombstones for forget/move vs staged scan; `ON CONFLICT DO NOTHING`; per-row cache, `removeMany`; stop persisting rehome; log only user columns; indexes; fix v16 migration; coalesced reload with status-only fast path; `LibraryIndex` in isolate.
- Files: `asset_record_store.dart`, `album_store.dart`, `person_store.dart`, `change_log.dart`, `library_screen.dart`, `asset_grid_view.dart`, `photo_grid_layout.dart`, `analyze_queue.dart`.
- Effort L · Risk medium (schema migration).
- Tests: upgrade matrix; `listAll` with back-dated and future `createdAt`; forget during staged scan.

**WP11 — Flagged Items single scan**
- Closes: 02#4, 02#13, 04#15, 07#9, 07#14, 07#15, 07#16, 07#25, 07#28.
- Files: new `FlagScan`, `flagged_items_screen.dart`, `fix_queue.dart`, `record_fixer.dart`, `storage_advice.dart`, `bucket_flagged.dart`.
- Effort L · Risk medium. Depends on WP3, WP8, WP10.
- Tests: fix then detect is empty for every kind.

Faces (05#4–#8, #13–#15) are a separate M package after WP11; do 05#4/#5 as quick wins now.

## 6. Quick wins (< ~30 lines each)

- 02#1 `canReformat` failed-read guard (P0-6).
- 08#1 `_onlyCopies` returns null on failure (P0-12).
- 07#2 `reconcile` skips hidden (P0-9).
- 05#1 remove photo option from Ask AI (P0-8).
- 04#2 `_reconcileMissing` gated on `PhotoLibraryAccess.granted`; `_stillInLibrary` exception = present.
- 04#13 `_deleteFromLibrary` exception = not deleted.
- 02#11 throw on zero targets in `liveOriginal`; 03#14 wildcard tasks on empty targets.
- 02#14 `.timeout(20s)` on `_proveAt` HEAD.
- 05#4 keep `person_id` on re-describe; 05#5 pipeline 3 live when model absent.
- 05#8 cache null only for a successful empty geocode.
- 07#6 `_selectedIds.toList()` + busy flag.
- 07#13 `enqueue` skips resolved flags.
- 01#10 fix `_adoptExistingUploads` column names (+ backfill).
- 01#11 / 08#15 clear bucket tables in `clearAll` / on target remove.
- 01#8 prune album/person change logs.
- 06#4 width change triggers restores; 06#5 wire `marked:`.
- 06#12, 08#6 `cacheWidth` caps on zoom and bucket preview.
- 06#16 remove `_onReviewCountChanged`; 06#18 YearWheel owns its controller.
- 03#18 PBKDF2 in `Isolate.run`.
- 05#14 `FaceEmbedder` model `static let`.
- 08#9 never interpolate Gemini URI (API key on screen); key in header.
- 09#6 Makefile `date` once; 08#16 gate screenshot hook on `kDebugMode`.
- 02#19 delete `_queueOrphanedKey`.

## 7. Verify on the physical phone

Read-only checks unless stated. Never test destructive triggers on the real library before the fix.

- 03#9b: header of `originals/20250616032353_1237….jpg`: plain JPEG (carrier overwritten) or carrier? Its `.mov` unreferenced?
- 03#1: Files → Photos Vault → daily zip → `library.json` contains hidden rows/hashes.
- 03#2: count plaintext `hidden_*` / `<localId>-*` in AppSupport; the 8 hidden rows with thumbnails.
- 04#1: do the 63 binned rows with `local_deleted=0` still exist in Photos? (read-only `fromId`).
- 04#2: limited-access trigger; verify only after WP7, on a test library.
- 04#7: after an Optimize batch or `putBack`, query for duplicate `library_id`.
- 04#6, 04#4: kill during Finish Optimize / run 4 jobs; check `pending_swaps_v1` (after WP8, or test library).
- 05#5: `faceModelStatus`; count pipeline-3 descriptors in `ai_analysis.db`.
- 05#7: Find Faces on a portrait photo; compare crops.
- 05#13: size of photo_manager cache (`*_exif.jpg`) in Caches after an analyze run.
- 05#14, 06#12, 07#23, 08#6: memory at pace 4; zoom a 48 MP photo; open crop screen; preview a large bucket original.
- 06#2, 06#4, 06#14: search while resting; rotate; drag right after a scan tick.
- 06#9, 06#13: thumbnail latency after a scrubber drag; swiping past an iCloud-only 4K video starts a download.
- 08#2: background run log after a locked overnight charge.
- 09#1, 03#8, 04#10, 01#1: fresh-install restore and first-scan grid count. Needs a second device (reinstall on the main phone wipes the container).
- 07#5: hide offline; plain bucket copy still there until the carrier lands (after WP4).
- 02#15: background and foreground engines uploading the same file.
- 02#1, 02#3: count `offProtocol` carriers in the bucket listing (exposure to failed-probe paths).

## Conflicts resolved

- 03 "checked and fine: hiding retracts plain copies" vs 07#5: 07 is right about ordering (`private_album_gate.dart:419-446,669-677`: deletes queued right after custody; carrier upload only `unawaited(hiddenBackup?.run())`).
- 05 "never writes a plaintext thumbnail for a private record" vs 03#2: both right; 05 covers new writes, 03 covers thumbnails left from before hiding.
- 04#22 "uncommitted change is fine" vs 06#2/#6: different parts of the diff. 04's part (batch lookup, index, scan lanes) is fine apart from widening 04#7; 06's part (rest on Albums, `_showThenBackUp`) has the bugs.
- 05#29 asked whether the snapshot is encrypted: 03#1 shows it is not (plain zip), so face vectors leak too; merged into P0-3.
- 02#27 open lead: resolved by 04 lead + 03#9b; hide then un-hide, not Optimize.
