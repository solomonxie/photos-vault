# Perf audit 02: storage and data layer

Scope: `lib/storage/**`, `lib/backup/change_log.dart`, `lib/backup/database_copy.dart`, `lib/photos/person_store.dart`, `lib/photos/ai_analysis_store.dart`, `lib/upload/sync_job_store.dart`, and the reload path in `lib/viewer/library_screen.dart`. This was a read-only review: no build, no tests, no `lib/` edits. `lib/vault/store.dart` is file-based and has no SQL, so nothing in it is listed here.

Assumes **n = 40,000 photos**.

## Method and measurements

- The DB copies named in the brief (`/tmp/pv_preinstall_final2/`, `/tmp/pv_after*/`) **do not exist** on this Mac, so the user's 289 MB file was not opened.
- Instead, a **synthetic model** was built in a scratch dir (`/tmp/claude-501/pvperf/`) with the exact `asset_record` schema, indexes and change-log JSON shape. Value lengths were realistic: UUID ids, 64-hex hashes, protocol object keys, container thumbnail paths, and 3 uploaded derivatives with bucket listing rows. Sizes come from `dbstat`, plans from `EXPLAIN QUERY PLAN`, and timings from the `sqlite3` CLI on an Apple-silicon Mac.
- For the phone, assume about 2–3x the Mac SQL times. Dart-side costs are scaled from the repo's own figure (`asset_record_store.dart:2675`: 20k rows ≈ 0.33 s on the UI isolate).
- Severity: **P0** = freeze or blocks startup, **P1** = measurable, **P2** = minor.

### DB size breakdown (`photos_vault.db`, model)

| Object | 4.5k records, log 7.6k entries | 40k, log un-pruned (68k) | 40k, log at cap (20k) |
|---|---|---|---|
| `change_log` | 21.1 MB | 188.0 MB | 78.3 MB |
| `asset_record` (≈1 KB/row) | 4.4 | 39.2 | 39.2 |
| `derivative_target` + PK autoindex + `derivative_target_key` | 4.9 | 43.5 | 43.5 |
| `bucket_object` + PK autoindex | 2.3 | 20.7 | 20.7 |
| `change_log_row` index | 0.6 | 5.2 | ~1.5 |
| 4 key indexes, `created`, `library_id`, `rev`, `passcode_hash` | 1.8 | ~16 | ~16 |
| **File** | **37 MB** | **331 MB** | **213 MB** |

- A log entry stores the **whole row as JSON twice** (`change_log.dart:94-123`). An update entry is about 3 KB of JSON, which takes about one 4 KB page. An insert entry is about 1.5 KB.
- At the 20k cap the log alone is **about 78 MB, whatever the library size**. A 4.5k library would settle near 14 MB of live data plus 78 MB of log, about **92 MB**.
- **Why the file is 289 MB (inferred, not verified on the file).** The log was never pruned in earlier builds, and every reinstall's `_rehomePaths` rewrote `thumbnail_path` on every row. That is about 4.5k × 4 KB ≈ 18 MB of log per reinstall, so about 11 reinstalls gives roughly 200 MB. The file also keeps its free pages until the one-time `VACUUM` (`asset_record_store.dart:305`).
- It is **not** blobs: face vectors live in `ai_analysis.db`. It is **not** WAL either: no DB enables WAL, so there are no `-wal` files.
- To confirm on a real copy:
  `sqlite3 -readonly photos_vault.db "select name,sum(pgsize) from dbstat group by 1 order by 2 desc; pragma freelist_count; pragma auto_vacuum; select op,count(*),sum(length(before))+sum(length(after)) from change_log group by op;"`

### Hot query plans (40k model)

| Query (file:line) | Plan | Mac time | Verdict |
|---|---|---|---|
| `listAll` first read, `SELECT *` ordered (`asset_record_store.dart:2695`) | index `created` | 138 ms incl. output | SQL is fine; the Dart decode is the cost (DB-1) |
| `listAll` incremental `rev > ?` (`:2714`) | COVERING `asset_record_rev` | <1 ms | good |
| `_lostRows` `COUNT(*)` (`:2832`) | COVERING `rev` | 0.2 ms | good |
| `keyHeldByOthers` (`:1707`) | key index + MULTI-INDEX OR, 4 key indexes | <1 ms | good |
| `getByLibraryId(s)` (`:2278`, `:2299`) | MULTI-INDEX OR `library_id_unique` / PK | <1 ms | good |
| `scannedTwin`, `relinkCandidate` (`:1624`, `:1647`) | `created` / relink PK | <1 ms | good |
| `originalStemHeld` `GLOB '*/stem.*'` (`:1746`) | **SCAN** `derivative_target`, SCAN covering `original_key` | 21 ms | DB-11 |
| `sourcePathShared` (`:2537`) | **SCAN** `asset_record` | 12 ms | DB-12 |
| `plainIdsUnder` (`:2525`) | `passcode_hash` index for `IS NULL`, i.e. about 40k index-then-row lookups | ~scan | DB-12 |
| `_rehomePaths` 2× UPDATE + 1 SELECT (`:445`, `:467`) | **SCAN** ×3 | 22 + 24 ms + scan | DB-3 |
| `allLocations` DISTINCT / `allTags` (`:2402`, `:2415`) | SCAN + temp B-tree | 15 ms | DB-13 |
| `listAwaitingPlaceName` (`:2344`) | backward walk of `created` with row lookups | 1 ms here; full walk when few rows match | DB-13 |
| prune slice (`change_log.dart:218`) | rowid range | 140–170 ms per 2000 rows | DB-7 |
| private-trigger delete `(table_name,row_key)` | COVERING `change_log_row` | <1 ms | good |

## Findings

| ID | Sev @40k | Where | What | Cost at 40k |
|---|---|---|---|---|
| DB-1 | **P0** | `asset_record_store.dart:2695-2712`, `:2743` | First `listAll` is `SELECT *` of every row, mapped to records on the UI isolate, and the raw row maps are kept as well | ~33 MB over the channel, **~0.6–0.8 s UI-isolate stall** before first paint, +40–60 MB heap for `_rows` |
| DB-2 | **P0** | `unnamed_faces.dart:85`, `ai_analysis_store.dart:419` | Strangers row reads **every** descriptor with its vector (`SELECT *`) on the UI isolate, then uses at most the 1,200 newest | ~28k rows ≈ 16–20 MB, **~0.3–0.6 s** per trigger (first load, `reload(faces:true)`, any hide/bin) |
| DB-3 | P1 | `asset_record_store.dart:254-263`, `:437-507`; `change_log.dart:46-180` | Every open does 3 full scans of `asset_record` (`_rehomePaths`) and drops and recreates every change-log trigger before `_db` is set | ~120–200 ms phone before the first query can run; ~70 DDL per launch in `people.db` |
| DB-4 | P1 | `change_log.dart:94-180`, `:218` | Change log stores the full row before **and** after, keeps 20k, and prunes only 30 s after launch | 78 MB steady; a first scan plus geocode session writes **~170–250 MB** before the next prune; drives file size, snapshot size and prune I/O |
| DB-5 | P1 | `asset_record_store.dart:243`, `:305-318` | The one-time `VACUUM` runs with `temp_store = MEMORY` and holds the only connection | Model (330 MB): **peak RSS 444 MB vs 182 MB** with FILE; 2.3 s Mac, ~4–8 s phone, every query queued behind it |
| DB-6 | P1 | `photo_library_service.dart:244-275`, `:465-487`; `asset_record_store.dart:1875-1983`, `:2035`, `:1765` | No WAL, default `synchronous=FULL`, and every row write autocommits. A new photo costs 3 queries and 1–2 commits; each upload costs 2 commits. Each commit fires rev and log triggers | First scan ≈ 40k commits; first backup ≈ 120–160k commits at ~2–5 ms fsync each, so **minutes** of serialized DB time with UI reads queued behind |
| DB-7 | P1 | `asset_record_store.dart:245`, `album_store.dart:91`, `person_store.dart:209` | `secure_delete = ON` zeroes and journals every freed page | Measured: deleting 48k log rows took **0.91 s ON vs 0.54 s OFF / 0.49 s FAST** (≈1.7–1.9x). Per 2000-row slice +10–18%. Phone: ~1–3 s of prune per launch at 40k, 100–300 ms per slice |
| DB-8 | P1 | `change_log.dart:262-292`, `app_snapshot.dart:205` | Each backup runs `changeLogTail` (5,000 rows × 2 JSON per store) through `jsonDecode` on the UI isolate. Only the encode is in `Isolate.run` | ~15 MB JSON per backup, **~100–250 ms** stall (daily, iCloud, bucket) |
| DB-9 | P1 | `database_copy.dart:23-43`, `local_vault.dart:120`, `:201` | Daily raw DB copies (`VACUUM INTO`) carry the full 20k log and the `bucket_object` cache, and 7 are kept | ~200 MB per copy, **~1.4 GB on disk** at 40k; `VACUUM INTO` holds the main connection ~1–3 s |
| DB-10 | P1 | `ai_analysis_store.dart:487`, `:506`, `:538`, `:624`; `person_store.dart:162-169`, `:792` | Missing indexes: `face_descriptor(person_id, confirmed_at)`, `face_suggestion(person_id)`, `person_asset(local_id)` | Full scans of ~18 MB `face_descriptor`, plus a temp B-tree sort **carrying blobs** in `confirmedFaces`: ~30–80 ms phone per call |
| DB-11 | P2 | `asset_record_store.dart:1746-1758` | `originalStemHeld` uses a leading-wildcard GLOB, so it is a full scan per flagged import | 21 ms Mac, ~50 ms phone per item (network dominates) |
| DB-12 | P2 | `asset_record_store.dart:2525-2547`, `plain_files.dart:72`, `:122` | `source_path` has no index; `plainIdsUnder` picks the worst index | ~12 ms Mac, ~30 ms phone per hidden file moved |
| DB-13 | P2 | `asset_record_store.dart:2344`, `:2402`, `:2415` | `allTags` / `allLocations` scan per editor open; `listAwaitingPlaceName` can walk the whole index | ~15–40 ms phone per open |
| DB-14 | P2 | `library_screen.dart:1340-1356`; `asset_record_store.dart:2782-2789` | Every non-status reload re-reads albums and memberships and walks `active` (40k) even when nothing changed; `_apply` re-sorts all 40k records per >256-row batch | ~5–15 ms per reload; ~30 ms per scan tick (see UI-4/UI-5) |
| DB-15 | P2 | `asset_record_store.dart:2958`, `:2966`; tables `:806`, `:1127` | Size: `derivative_target` and `bucket_object` are rowid tables plus a PK autoindex, so the key strings are stored 2–3 times | ~20 MB reclaimable at 40k |
| DB-16 | P2 | `person_store.dart:69`, `ai_analysis_store.dart:70` | `_open` has no single-flight guard (Album and Asset stores do); concurrent first callers open twice | Duplicate trigger install; a leaked connection |

## Details and fixes

**DB-1 (P0) First full read on the UI isolate.**
- Each row arrives as about 42 values (≈830 bytes; hashes and keys are ≈470 bytes of that). It is then decoded and passed through `_fromRow`, which re-sorts 40k records (`:2707`, the SQL already ordered them). `_rows` keeps every raw map next to the records.
- Fix, in order of payoff:
  1. Two-phase load. Read the newest window first with `ORDER BY created_at DESC LIMIT 3000`, paint it, then read the rest in chunks of about 5,000 and yield between chunks. No single frame is longer than ~70 ms.
  2. Drop `_rows`. Compare the fetched row against the held `AssetRecord` fields, or keep only `rev` per id.
  3. Skip `order.sort` when an O(n) check shows the list is already ordered.
  4. Optionally, a slimmer projection for the grid. This touches every `listAll` consumer (`referencedKeys` reads keys from it), so it is the larger refactor.
- Risk: none for data. Callers that rely on `identical()` must still get one published list per change.

**DB-2 (P0) Descriptors read in full.**
- Fix: after building `flat`, take the `localId`s of the first `scanLimit` faces and call the existing `descriptorsOf(ids)` (`ai_analysis_store.dart:333`, which queries the PK prefix in chunks). Do the same in `face_grouping.dart:98`, `:142` where a seed set exists.
- Cost becomes about 1,200 rows (~0.7 MB) instead of 28k.
- Risk: none.

**DB-3 (P1) Per-launch work on open.**
- Fix: store the container id and an "outside paths settled" flag in `app_state`. Run the two `UPDATE`s and the per-row pass only when the container changed.
- Fix: hash the generated trigger SQL, store the hash (for example in `app_state` or `PRAGMA user_version` of a side table), and skip `installChangeLog` when it is unchanged. Keep the transaction.
- Risk: low. A reinstall changes the container, so the repair still runs exactly when it is needed.

**DB-4 (P1) Change-log volume.**
- Fix: log only the columns that changed. Build `json_object` from a `CASE` per column inside the trigger, or keep `before`/`after` for the user-authored columns only (description, tags, location, favorite, dates, bin state).
- Fix: `keep = 5000`, which matches `changeLogTail`.
- Fix: also prune after bulk passes (end of scan, end of geocode batch), not only at launch.
- Expected: about 90% less log, the 20k cap drops from ~78 MB to ~5 MB, and prune and secure-delete I/O shrink with it.
- Risk: recovery reads `before` values (`_undoRedate` reads `$.created_at`). A changed column is still present, so the history stays restorable. The mark (`sqlite_sequence`) is unchanged.

**DB-5 (P1) VACUUM in memory.**
- Fix: new databases set `PRAGMA auto_vacuum = INCREMENTAL` in `onConfigure`, before tables exist, so they never need a full VACUUM.
- Fix: for existing databases, run the full `VACUUM` only when `freelist_count * page_size > 64 MB`, after the prune, with `temp_store = FILE` and a temp directory that is known to work. The comment at `:241` says iOS `tmp` failed; set `SQLITE_TMPDIR` / `temp_store_directory` to the app's `tmp`. Run it when the app goes to the background, not 30 s into a session.
- Risk: none for data. If VACUUM fails, the file just stays large.

**DB-6 (P1) Commit cost.**
- Fix: `PRAGMA journal_mode=WAL` with `synchronous=FULL`. This keeps durability and removes the journal create/delete fsyncs. Use `rawQuery`, because it returns a row.
- Fix: batch writes: one transaction per scan page (insert or update the page's rows in a `Batch`), and `updateDerivative` + `recordUpload` in one transaction.
- Risk: under WAL, zeroed `secure_delete` pages and old frames sit in `-wal` until a checkpoint. Run `PRAGMA wal_checkpoint(TRUNCATE)` after hidden-row deletes and `clearAll`. Do not use `synchronous=NORMAL` on the paths that record remote deletes: a lost last commit on power loss could forget a delete intent.

**DB-7 (P1) secure_delete cost.**
- Fix: shrink the log first (DB-4).
- Fix: in `pruneChangeLog` only, switch to `PRAGMA secure_delete = FAST` for the slice loop and back to `ON` afterwards. Pruned rows are non-private by construction, because private entries are never logged and `_purgePrivateLog` runs first with `ON`. `compact`'s `incremental_vacuum` then truncates the freed pages.
- Keep `ON` for hidden rows and `clearAll`.
- Risk: low. It needs `_purgePrivateLog` to have finished before the first FAST prune, which is already the order at `:269`.

**DB-8 (P1) Tail decode on the main isolate.**
- Fix: return the raw `before`/`after` strings, and decode inside `_encode` in `snapshot_archive.dart:184` (already `Isolate.run`).
- Risk: none.

**DB-9 (P1) Raw copies.**
- Fix: add to the `copyTo` scrub `DELETE FROM change_log WHERE seq <= (SELECT MAX(seq) FROM change_log) - 5000` (the zip carries the tail) and `DELETE FROM bucket_object; DELETE FROM bucket_scan_object` (a listing cache rebuilt on the next scan). Keep `derivative_target`, which the delete guard reads.
- Expected: about 200 MB down to about 120 MB per copy, or about 65 MB once DB-4 lands.
- Risk: confirm that no restore path reads `bucket_object` from a raw copy.

**DB-10 (P1) Indexes.** All are additive and idempotent:
```sql
CREATE INDEX IF NOT EXISTS face_descriptor_person ON face_descriptor (person_id, confirmed_at DESC) WHERE person_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS face_suggestion_person ON face_suggestion (person_id) WHERE person_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS person_asset_local ON person_asset (local_id);
```
- Also select only the columns needed in `confirmedFaces` (it reads `*`).
- Risk: none.

**DB-11 (P2) `originalStemHeld`.**
- Fix: anchor the pattern per target prefix: `destination_key GLOB ? || 'originals/' || ? || '.*'` for each configured prefix, plus `original_key GLOB …`. GLOB with a literal prefix uses the index.
- Risk: a key under an unknown prefix would be missed. Keep the full scan as the fallback when the anchored query finds nothing and a prefix is unknown, because this guard protects deletes.

**DB-12 (P2) `source_path` lookups.**
- Fix: `CREATE INDEX asset_record_source_path ON asset_record(source_path) WHERE source_path IS NOT NULL` (small, because only manual and hidden rows have one).
- Fix: `plainIdsUnder` uses `source_path >= ? AND source_path < ?` (a range on `dir/` to `dir0`) and `+passcode_hash IS NULL`, which stops the planner from using the bad index.
- Risk: none.

**DB-13 (P2) Pickers and geocoder.**
- Fix: memoise `allTags`/`allLocations` on `revision()`.
- Fix: partial index `ON asset_record(created_at) WHERE latitude IS NOT NULL AND (location IS NULL OR location = '') AND deleted_at IS NULL`.

**DB-14 (P2) Reload.**
- Fix: skip the album and membership block when `!libraryChanged` and `albumStore.changeMark()` has not moved.
- Fix: raise the `_apply` batch threshold, or merge the new rows into the sorted list instead of re-sorting.

**DB-15 (P2) Duplicated key strings.**
- Fix: rebuild `bucket_object` and `derivative_target` as `WITHOUT ROWID` tables in a versioned migration (copy, drop, rename, in one transaction).
- Risk: a migration of upload-truth tables. Do it only with a pre-migration `LocalVault.guard`.

**DB-16 (P2) Double open.**
- Fix: copy the `_opening` single-flight from `AlbumStore._open`.

## What is already right

- Change detection is rev-based: a covering index, a counter row rather than `MAX(rev)`, and the same list instance when nothing changed.
- `getByLibraryIds` reads a whole page in chunks. `allMemberships` and `allHoldings` avoid N+1.
- `removeMany`, `forgetAssets` and bucket staging are batched in transactions.
- The prune is sliced with a 50 ms yield.
- No PRAGMAs on `cache_size` or `mmap` were found. Leave both at their defaults. The model shows no I/O-bound hot read once DB-1 and DB-2 are fixed.
- `sync_jobs.db` is capped at 100 open jobs, so its missing indexes do not matter.
