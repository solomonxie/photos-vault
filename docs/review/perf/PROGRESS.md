# Perf Fix Progress

| PW | Goal | Status | Commit |
|---|---|---|---|
| PW1 | First photo fast on cold start | done | c919b28 |
| PW2 | Cheap resume | done | 257a92c |
| PW3 | No re-renders for thumbnails, Vision, hashing | done | a354f05 |
| PW3b | Upload true originals (+ edited render) | done | 9191d15 |
| PW4 | Faces without full descriptor reads | done | 3622041 |
| PW5 | Smaller database | done | abe50f7 |
| PW6 | Less periodic waste | done | (this commit) |
| PW7 | Cheaper grid paint | todo | |
| PW8 | Cheaper reload and search | todo | |
| PW9 | The rest | todo | |

## PW3 notes

- BG-4: cache and bucket thumbnails from PhotoKit (fitted 320, JPEG q70, as `encodeThumbnail`); the full-size render only when PhotoKit has none.
- BG-10: Vision takes `photokit:<id>` sources, rendered natively at 2048 (`VisionAnalysisChannel.swift`). `facesWithPrints` detects and describes in one render; matching then reads stored descriptors. Files stay for held/hidden/manual and for pre-upright (legacy) boxes.
- BG-5: `hashFile` in an isolate; the pre-upload hash is reused after the put; optimizer hash off the UI isolate.
- BG-6: `change_check` table (schema v26): `seen` stamped by scans and the change history, `checked` set by an upload or a matching hash. Checks only where they differ. One-time cost: every backed-up photo is hashed once after upgrade (newest first, 100 per sync).
- Tmp: `TempRenders` holds renders in use; uploads, checks and thumbnail fallbacks delete their own after the transfer is terminal; a sweep on queue drain removes unheld renders older than 1 h. `clearFileCache` not used: it also empties `.video`, which playback and video uploads read.


## PW3b notes

- Decision: true original plus the current render when edited.
- Keys: `originals/<base>.<ext>` from `originFile` / `getBaseFile` (HEIC as stored); edit at `edited/<same base>.<ext>` (`DerivativeKind.edited`, `uploadEdited` job). Own folder, so `originals/` readers never see it as a photo or stray.
- Schema v27: `edited_status/key/hash`, `has_edit`, `original_source` (NULL = legacy JPEG-render hash, 'resource' = PhotoKit bytes). Upgrade adds columns only.
- No re-send on upgrade: legacy rows keep their objects and compare render to render. Re-baseline without render: checked when the date equals `checked`, or when it is >= 24 h before the latest per-bucket upload row (`target_id` != '') of the recorded hash. Adopted rows never count.
- Genuinely edited legacy photo: new HEIC original + edit; old `.jpg` queued with keeper (new key) and `untilWhole`, so it goes only after both are up and the keeper answers live.
- Restore prefers the edit; falls back to the original only on a 404 everywhere. Import attaches `edited/` siblings. Flag scan ignores `edited/`. Verifier proves and reconciles edits.
- Tmp: `TempRenders` covers `tmp/.image`; the sweep skips files `background_downloader` still holds, and skips everything if it can't tell.
- HEIC input: thumbnails fall back to ImageIO; Vision and face crops are native; optimizer still reads the JPEG render.


## PW4 notes

- UI-2 / DB-2: `findUnnamedFaces` reads per-photo face counts (SQL, no box decode; cached until the next analysis write), picks the newest photos covering `scanLimit` faces, then reads boxes, guesses and unnamed descriptors for those only (`facesOf`, `suggestionsOf`, `unnamedDescriptorsOf`). Fold gets typed data only (`Float32List` vectors, `Int32List` offsets/revisions/photos), in an isolate above 150 faces.
- Faces older than the window are counted in `found` but no longer fold into newer circles.
- Gate: memo per `limit`, keyed on store instance, `AiAnalysisStore.revision` (static write counter, bumped after every face/descriptor/guess write by any instance), the window ids, names and `scanLimit`. Hide/bin/delete of a photo outside the window is a hit; naming changes the window or bumps the revision.
- DB-10: analysis v8 adds partial indexes `face_descriptor(person_id, confirmed_at)` and `face_suggestion(person_id)`; people v10 adds `person_asset(local_id)`. `confirmedFaces` orders `rowid, person_id` on the covering index (small temp sort, no blobs), caps per person, then reads vectors by rowid in one transaction. Plans checked with EXPLAIN QUERY PLAN (test in the migration suite).
- UI-9: file-backed covers and avatars decode at the drawn size (`fileDecodeSize`; `cacheHeight` for landscape under `cover`). Face crops: PhotoKit fitted render at the needed width (was the default square thumbnail), decode capped at 1536, cropped once to a circle-sized `ui.Image` on the raster thread; the render is evicted. Crops kept in a 64-entry session LRU (`faceCrops`), cleared on memory pressure.
- UI-10: `PersonAvatar(records:)` resolves from `visibleRecordsOf(all)` (memoised per `listAll` instance); the library People row and the people screen pass it, so no query per avatar mount. Other callers keep the query path.
- Not done: `FaceGrouping.like`/`likeAnyOf` still read every descriptor; "who else looks like this" needs the whole set.


## PW5 notes

- Measured on the user's DB copy (read-only, 4,525 records): 289 MB file, 207 MB of it free pages (`auto_vacuum` 0); live 92 MB, of which `change_log` 76 MB (19.4k entries, all at the 20k cap; 19.1k of them `thumbnail_path` re-homes). Rest: `asset_record` 4.0, `derivative_target` + indexes 5.2, `bucket_object` + PK 2.9, `change_log_row` 1.4. Prune + slim + VACUUM on a scratch copy: **15.4 MB**, log 0.5 MB.
- DB-4: update triggers write only changed, non-silent columns (`json_remove` of unchanged ones); inserts and deletes keep the whole row. Cap 5,000 (`changeLogKeep`, what the zip ships). Schema v28 records `change_log_slim_below`; after the first frame, purge, prune, then `slimChangeLog` rewrites older update entries to diffs in 500-row slices (idempotent; changed values kept on both sides, so `_undoRedate`-style reads still work). Mark (`sqlite_sequence`) untouched. People and albums: new entries are diffs; old ones age out under the cap (no migration, 1 MB / 24 rows).
- Prune runs after `waitUntilFirstFrameRasterized` (never in the headless background engine); VACUUM still no earlier than 30 s after open.
- DB-5: one-time VACUUM with `temp_store = FILE` (tmp re-created first), back to MEMORY after. MEMORY only as fallback when live data <= 64 MB.
- DB-7: `secure_delete = FAST` per prune slice, set and restored inside the slice's transaction, asset store only and only once the private purge has run. People and album logs stay zeroed: they log memberships of hidden photos.
- DB-8: backups read the tails as JSON text (`rawChangeLog`); decode and hidden filter run in the zip isolate. Pre-deletion and share exports still decode on the caller (rare).
- DB-9: daily copies (`slim`) cap the log at 5,000 and drop `bucket_object`, `bucket_scan`, `bucket_scan_object`, `bucket_edit`: a zip restore also starts with no listing, and the flag scan re-lists when it finds none. Pre-deletion copies keep everything. Retention unchanged. The 5k tail stays (~0.5-2 MB) so a copy is whole without its zip.
- Not done: prune after bulk passes (diffs make a pass ~100-300 B per row); `auto_vacuum` in `onConfigure` for new files (their first VACUUM is tiny).


## PW6 notes

- BG-7: `sweep` returns the last finished answer while the record revision, record count (deletes), `bucketStamp` and the advisor's own writes are unchanged. `_save` skips a write of identical text (ranking tie-broken by id, so it is stable). `_scan` reads the bucket index only when `bucketStamp` moved, and the cache once per round.
- BG-9: the analyze queue patches its backlog from `listAll` by record identity (unchanged rows keep their instance), at most every 30 s; a full `refresh` at run start and at most every 5 min. Analysis maps may lag other writers: `findFaces` re-reads the photo's row first and skips one analysed meanwhile; learn/match already re-check.
- BG-11: `checkImports` keeps 16x16 grey prints in `Caches/grey_prints_v1.bin`, keyed by id, path, mtime (us) and size, read and written in its isolate. Only prints of current non-hidden, non-binned library photos are written back. Only imports not yet compared are compared (as before).
- BG-12: `libraryDelta(...).flags`: every record field but `updatedAt` and a status between pending and uploading (no detector or the page tells them apart). `refreshIfChanged` compares against the inputs as the session's last scan began reading them (records instance + bucket stamp + app-state digest); before any scan this session, the saved stamp as before. While `syncQueue.draining`, at most every 2 min. The persisted stamp (open) is unchanged.
- UI-11: `isResolved` builds `id#solution` keys only for ids with an entry (`_resolvedIds` count). The page regroups at most every 400 ms while a fix run is going (100 ms otherwise), coalesced.
- UI-18: `ThumbnailTries`: 3 failures in a session and a photo is skipped until the camera roll is re-read or a sync forgets failures; videos with no poster count too. The library reloads only when a thumbnail was made.
- BG-15: schema v29: `change_check.spot_checked`; the old `spot_checked_at` JSON imported in SQL (`json_each`) and removed. `spotCheckOrder` orders in SQL with a looser rule (original up); each pick is confirmed in Dart, paged by 64. A round writes only its rows.
- Not done: `_pendingAndFailed` (UI-18's 3 ms `where` per round); `_markResolved` still rewrites the whole resolved map per fixed item.

