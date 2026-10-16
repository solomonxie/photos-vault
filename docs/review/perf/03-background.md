# Perf review 03: background and pipeline work

Scope: `lib/upload/**`, `lib/photos/**` (minus person_store, ai_analysis_store), `lib/vault/**` (minus store.dart), `lib/backup/**`, `ios/Runner/*.swift`. Callers in `lib/viewer/library_screen.dart` and the photo_manager 3.12.0 native source (`~/.pub-cache/.../photo_manager-3.12.0/darwin/.../PMManager.m`) were read where they decide cost. Read-only: nothing built or run.

Costs assume **n = 40,000 photos**, about 4 MB per HEIC original, 12 MP. Figures marked "est." are order-of-magnitude estimates from the code path, not measurements. "RT" means a platform-channel round trip (sqflite or photo_manager). Every sqflite result is decoded on the UI isolate.

## Summary

| ID | Sev | What | Cost at n = 40k |
|---|---|---|---|
| BG-1 | P0 | Full camera-roll re-scan forced on every resume | ~400 photo_manager RT + 200 SQL IN-queries returning 40k rows; est. 20-60 s native CPU per resume |
| BG-2 | P0 | Every "file" is a full-res JPEG re-render (`entity.file`) | ~4-5 renders per photo, est. 0.2-0.5 s each; ~10 MB tmp write each; tmp never cleaned |
| BG-3 | P0 | Launch fan-out: 8+ library-wide jobs start in one tick | All compete with the first frames for the one DB connection and the UI isolate |
| BG-4 | P1 | Thumbnails built by pure-Dart decode of the full-res file | est. 1-3 s CPU per photo; 8 per 20 s means 28 h or more of wall time |
| BG-5 | P1 | SHA-256 on the UI isolate, twice per upload | 2x library bytes hashed on the UI isolate; est. 30-60 min of UI-isolate CPU in total |
| BG-6 | P1 | Change check re-renders and re-hashes the same newest 100 on every sync | est. 30-50 s CPU and ~1 GB tmp writes per sync |
| BG-7 | P1 | Storage sweep every 20 s rewrites a 2-3 MB JSON and reads the bucket index twice | est. 150-400 ms of UI-isolate decode per round; ~0.5 GB/h DB writes |
| BG-8 | P1 | First-scan insert is N+1, with one auto-commit per row | 160-200k sqflite RT and 40k commits |
| BG-9 | P1 | Analyze queue re-reads 6 whole tables every 30 s while the library moves | est. 0.3-1 s of UI-isolate decode per refresh |
| BG-10 | P1 | Faces: two file resolves and two decodes per photo | 2x BG-2 renders plus 2 ImageIO decodes per face photo |
| BG-11 | P1 | `checkImports` decodes every thumbnail in the library, prints never cached | 40k decodes, est. 7-20 min CPU per new import batch |
| BG-12 | P1 | Flagged page re-runs the full flag scan every 15 s during uploads | est. 1-3 s of UI-isolate work every 15 s while the page is open |
| BG-13 | P1 | Whole-file reads into memory (vault carriers, optimizer) | ~3x video size at peak; a 1 GB hidden video risks a jetsam kill |
| BG-14 | P2 | Per-id photo_manager / DB calls in loops | Optimize scan: 120k RT; change bursts: 2 RT per id |
| BG-15 | P2 | `spotCheck` JSON map of every cloud-only id, decoded and re-encoded every 10 min | ~1.5 MB JSON round trip on the UI isolate |
| BG-16 | P2 | `backUpRecords` sorts the whole pending list on every refill | est. 20-50 ms UI-isolate stall per refill |
| BG-17 | P2 | Unbounded `Future.wait` of `fromId` in `deleteManyFromLibrary` | N concurrent RT when the limit is lifted |
| BG-18 | P2 | Sync queue runs batch-barrier workers (one video stalls its batch) | idle upload slots while a long file finishes |

Clean or acceptable:
- **Sync file I/O on the UI isolate:** only `sync_engine.dart:498` (`existsSync`, one per job, documented as a known violation). Every other `*Sync` call runs inside `Isolate.run`.
- **Swift side:**
  - Vision runs on `.utility` (`VisionAnalysisChannel.swift:30`), with decodes capped at 2048 (`:125-146`).
  - SFace is loaded once (`FaceEmbedder.swift:17,36-56`) and predictions are serialized by a lock.
  - iCloud runs on `.utility`. The background task needs power and network (`BackgroundSync.swift:26-30`).
- **Snapshot encode** goes through `Isolate.run` (`snapshot_archive.dart:184`), as do the decoy, carrier and thumbnail encodes.
- **Verifier reconcile** is a listing per 1,000 keys, not a HEAD per photo. `spotCheck` is limited to 4 photos and throttled to once per 10 min.
- **`LibraryRestore` / `BucketImport` / `FlagScan` probes** use bounded pools (6 or 8).

---

## Timers and what runs when

| Trigger | Work started (no staggering unless noted) |
|---|---|
| Cold launch, `library_screen.dart:804-864` | `reload` (first full `listAll`), then all at once: `HiddenRepair.runOnce`, restore/iCloud check, `_resumeQueue` (drain: true, so uploads start now), `fixQueue.resume`, `restoreRing` then `hiddenBackup.run`, `_scanRecentThenAll` (2 pages, then a **full** `syncAll`), `analyzeQueue.startIfDue` (6 table reads, then Vision), `_runScheduledSyncIfDue` (`spotCheck`, `checkImports`, `repairIfDue` = S3 list + reconcile, enqueue uploads + change checks) |
| Resume, `:584-596` | bucket listing (12 h throttle), `_scanRecentThenAll` with `run(force: true)`, so a **full** scan every time; analyze; leftover sweep; scheduled sync; hidden backup; `_startTrickle` |
| Trickle `Timer.periodic(20 s)`, `app.dart:101`, `library_screen.dart:1037-1068` | pending uploads, **or**: `LibraryScanner.run` (5 min interval), `analyze.startIfDue`, 8 thumbnails, `StorageAdvisor.sweep` (BG-7). Started only on resume and never cancelled on pause (harmless once suspended) |
| Flagged page `Timer.periodic(15 s)`, `flagged_items_screen.dart:92` | `refreshIfChanged`, which runs a full flag scan whenever `revision()` moved (BG-12) |
| Background task, `background_sync.dart:221` | 15 s heartbeat; `syncRecent` (no reconcile), deferred deletes, `spotCheck`, up to 50 refill rounds. Fine |
| Pause, `:574-582` | `PauseBackup` (when due, encoded in an isolate) and the bucket listing |

---

## Findings

### BG-1 P0: full re-scan on every resume
- **Where:**
  - `library_screen.dart:591` calls `_scanRecentThenAll`, which calls `_libraryScanner.run(force: true)` (`:602-605`). `force` bypasses the 5 min interval (`library_scanner.dart:78-82`).
  - `photo_library_service.dart:167-175`: 200 pages.
  - `:95-107`: `getAssetPathList` runs **inside the per-page function**, so it runs on every page.
  - `needTitle: true` means `PHAsset.title` goes through `[PHAssetResource assetResourcesForAsset:]` for every asset (`PHAsset+PM_COMMON.m:43-60`).
- **Scales:** O(n) on every app open and every return from Photos. For 40k:
  - 200 x (smart-album fetch + count fetch + sorted `fetchAssetsInAssetCollection` + 200 resource lookups), est. 20-60 s of native CPU.
  - 400 photo_manager RT; ~8,000 entity maps decoded on the UI isolate.
  - 200 `getByLibraryIds` queries returning 40k rows plus `_fromRow`.
  - `reload()` once a second for the whole pass (`:983-996`).
  - `_reconcileDeletions` then loops 40k records in memory (cheap).
- **Fix:**
  - Resume runs only the recent lane. The full pass runs at most daily, or when the delta below says it must.
  - Delta via `PHPhotoLibrary.fetchPersistentChanges(since:)` (iOS 16+). About 60 lines of Swift: return the inserted/updated/deleted ids since a stored token, then reuse `applyChange`.
  - ```dart
    // resume
    await _libraryScanner.runRecent();
    final delta = await PhotoChanges.since(token);      // null = token expired
    delta == null ? await _libraryScanner.run() : await svc.applyChange(delta);
    ```
  - Fetch the `AssetPathEntity` once per pass and pass it to the page loop.
  - Set `needTitle: false`. Read `titleAsync` only for **new** ids (the GIF check in `_insert`).
- **Risk:** deletion reconcile still needs a full pass sometimes. Keep it daily and on token expiry, gated on full access as today. `_markGone` is unchanged and never deletes rows.

### BG-2 P0: `entity.file` re-renders a full-res JPEG on every call
- **Where:**
  - `photo_library_service.dart:622,630,818`. `sync_engine.dart:500` (`filePathFor`) feeds uploadOriginal (`:268`), uploadThumbnail (`:466`), checkChanges (`:376`), analyzePhoto (`:320`), `analyze_queue.dart:634` (`resolvePath`), `face_identity.dart:139,209` and `library_screen.dart:1100`.
  - Native side, photo_manager `PMManager.m:629-632`: with `isOrigin: false`, `fetchFullSizeImageFile` (`:1751-1840`) calls `requestImageForAsset` at `PHImageManagerMaximumSize` (dispatched on the main thread, `:1779`), then `convertToData` as JPEG at quality 1.0, then `writeFullFileWithAssetId` (`:1389-1400`) to `tmp/flutter-images/<sha>_exif.jpg`.
  - No cache check: each call renders again.
  - The app never calls `clearFileCache`.
  - Videos are copied once to tmp and reused (`:868ff`, `fileExistsAtPath`).
- **Scales:** each photo is rendered about 4-5 times over its life (thumbnail, original, findFaces, matchFaces when it has faces, checkChanges each sync, missing-thumbnail sweep).
  - Per render, est.: 0.2-0.5 s CPU for 12 MP (several times that for 48 MP); ~50-200 MB transient decode memory; ~8-12 MB written.
  - 40k photos: est. 10-25 h of CPU and ~1.5-2 TB written to flash across backup plus analysis. The tmp folder grows by one JPEG per photo touched until iOS purges it, which could reach hundreds of GB.
  - Side effect: the "original" in the bucket is that JPEG re-render, not the HEIC bytes. Uploads are 2-3x larger, and the optimized format then re-encodes it again (`backup_coordinator.dart:169-191`).
- **Fix:**
  - **Analysis and thumbnails need no file:**
    - Thumbnails come from the PhotoKit thumbnail (BG-4).
    - Vision gets a native `analyzeAsset(id)` that calls `PHImageManager.requestImage(targetSize: 2048)` and passes the result straight to `VNImageRequestHandler` (BG-10).
  - **Upload:** use `originFile` / `originFileWithSubtype`. This is a PHAssetResourceManager write of the original bytes, cached by id and modification date. After a successful put, delete the plugin temp file, or call `PhotoManager.clearFileCache()` when the queue drains.
- **Risk (data):**
  - `backedUpHash` today is the hash of the re-render. Switching the source makes every checkChanges see "edited", which means a mass re-upload of 40k photos. Ship a one-time re-baseline: on the first check after the switch, store the new hash and do not re-upload.
  - Edited photos: `originFile` is the unedited original. Decide whether to also send the current render (the full-size photo resource) when `hasAdjustments`.
  - Uploads stay on `background_downloader`. Nothing in this fix deletes anything.

### BG-3 P0: launch fan-out competes with the first frame
- **Where:** `library_screen.dart:804-864` (see the timeline above).
- **Scales:** on a 40k library, these all start in the same few hundred ms:
  - the full scan (BG-1);
  - the analyze queue's 6 whole-table reads and its first Vision render;
  - the upload drain, with BG-2 renders and BG-5 hashing;
  - `repairIfDue` (an S3 listing of about 40 pages plus a 40k-record reconcile);
  - `checkImports` (BG-11).

  The only ordering is recent scan before full scan. They all queue on one sqflite connection, and every row comes back through the UI isolate.
- **Fix:** let the first screen settle, then add work in stages:
  ```dart
  await _libraryScanner.runRecent();
  await _idle(const Duration(seconds: 8));   // no scroll / no pointer for 8 s
  unawaited(_resumeQueue());
  await _idle(const Duration(seconds: 8));
  unawaited(_libraryScanner.run());          // full pass, not forced
  unawaited(_analyzeQueue.startIfDue());     // after the scan, not beside it
  unawaited(_runScheduledSyncIfDue());
  ```
  `_idle` can be `ScrollStopGuard`'s signal or `SchedulerBinding.scheduleTask(..., Priority.idle)`.
- **Risk:** none for data. A kill-resumed upload starts a few seconds later.

### BG-4 P1: thumbnails come from a Dart decode of the full-res file
- **Where:**
  - `thumbnail_cache.dart:101-105`: `readAsBytes` on the UI isolate, then `Isolate.run(encodeThumbnail)`, which copies the bytes, then a Dart JPEG decode of 12 MP.
  - Callers: `ensureFor` from `library_screen.dart:1105` (8 per trickle round) and `sync_engine.dart:468` (every uploadThumbnail job).
  - The PhotoKit thumbnail (`_defaultLibraryThumbnail`, `:107-125`) is used only as a fallback, and for videos.
- **Scales:**
  - Per photo: a BG-2 render, ~10 MB on the UI-isolate heap plus a ~10 MB copy, and est. 1-3 s of Dart decode/resize/encode.
  - 40k photos: est. 10-30 h of CPU. The trickle alone needs at least 5,000 rounds x 20 s, about 28 h of foreground time.
- **Fix:**
  ```dart
  var encoded = record.sourceType == AssetSourceType.photoManager
      ? await _libraryThumbnail(record)               // ~10-30 ms, native, no file
      : null;
  encoded ??= originalPath == null ? null
      : await Isolate.run(() => encodeThumbnail(File(originalPath).readAsBytesSync()));
  ```
  Once uploadThumbnail no longer needs an original path, it stops calling `filePathFor` for camera-roll photos.
- **Risk:** the PhotoKit thumbnail shows edits, which is the correct picture for a cloud-only tile. It is already fitted, not cropped.

### BG-5 P1: SHA-256 on the UI isolate
- **Where:**
  - `file_hash.dart:9`: `sha256.bind(openRead())` runs on the caller's isolate.
  - Called twice per upload: `backup_coordinator.dart:545` (before the put) and `:558` (after the put, same file).
  - Also `sync_engine.dart:383,436` (checkChanges, Live `.mov`), `storage_optimizer.dart:952` (video temp) and `filed_photos.dart:95`.
  - Synchronous: `storage_optimizer.dart:293` (`hashBytes` of a whole re-encode, a single blocking call).
  - The verifier already does this correctly (`backup_verifier.dart:346`).
- **Scales:**
  - Pure-Dart SHA at est. 100-200 MB/s, in 64 KB slices on the UI isolate. A 10 MB file is 50-100 ms; a 1 GB video is 5-10 s, done twice.
  - 40k at ~4 MB, or ~10 MB as re-rendered: 2 x 160-400 GB, est. 30-60 min of UI-isolate CPU spread through the backup, with dropped frames whenever it overlaps scrolling.
- **Fix:**
  ```dart
  Future<String> hashFile(String path) =>
      Isolate.run(() async => (await sha256.bind(File(path).openRead()).first).toString());
  ```
  Pass the pre-upload hash into `_hashOnSuccess` instead of reading the file again. In `storage_optimizer.dart`, return the hash from the `optimizeStill` isolate.
- **Risk:** none.

### BG-6 P1: checkChanges rehashes the same newest 100 on every sync
- **Where:** `sync_engine.dart:224-252` (enqueue newest-first; the queue cap of 100 stops the walk) and `:375-420`. Triggered from `library_screen.dart:1810` (`_syncEverything`).
- **Scales:** per sync: 100 x (BG-2 render + BG-5 hash), est. 30-50 s CPU and ~1 GB tmp writes. On `every15Minutes` with the app open, that is ~4 GB/h. The same 100 newest photos are checked every time, so an edit to an older photo is never detected.
- **Fix:** store `modifiedDateSecond` at backup time. Queue a check only when the entity's modification date moved (already in the listing metadata, or in the BG-1 delta's updated set). Hash only those.
- **Risk:** modification date also moves for favourites and metadata changes. That only causes a hash, which is safe. The fix itself queues no uploads and makes no deletes.

### BG-7 P1: storage sweep rewrites its whole cache every 20 s
- **Where:**
  - `library_screen.dart:1067`, then `storage_advice.dart:684` (`sweep`), then `_scan` (`:617-636`).
  - `_scan` calls `_loadRemoteDone()` with no objects, which runs `listBucketObjects()` (`:358-363`, uncached at `asset_record_store.dart:1066`). `cached()` then reads it again (`:514`).
  - When `todo.isEmpty`, it still does `return _save(...)` (`:625-634`), which is a `jsonEncode` of `measured` (all 40k ids) plus items.
- **Scales:** per round, est.:
  - 2 x ~80k bucket rows decoded (100-300 ms each);
  - a jsonDecode and a jsonEncode of 2-3 MB (40-80 ms);
  - one 2-3 MB SQLite write.

  Every 20 s that is about 180 times an hour, ~0.5 GB/h of DB writes, and a periodic frame hitch, forever after the scan is complete.
- **Fix:**
  ```dart
  if (todo.isEmpty) return previous;            // no _save
  await _loadRemoteDone(objects);               // pass the one listing through
  ```
  Keep `measured` in memory, keyed on `store.revision()`, or as a column instead of JSON.
- **Risk:** none.

### BG-8 P1: first scan inserts row by row
- **Where:** `photo_library_service.dart:257` calls `_insert` (`:464-487`), which calls `_adoptRestored` and `relinkCandidate` on every new asset (`:493-500`, `asset_record_store.dart:1617`). `upsert` (`:1875-1960`) then does `getByLocalId`, a holder query and an `insert`, and sometimes `setFavorite`. Each is its own auto-commit.
- **Scales:** fresh install with 40k photos: 160-200k sqflite RT and 40k commits, est. 1-3 min added to the first scan, all of it decoded on the UI isolate.
- **Fix:** read `relinkPendingCount()` once per pass and skip `relinkCandidate` when it is 0. Then insert each page in one transaction:
  ```dart
  await db.transaction((t) async { final b = t.batch();
    for (final e in fresh) b.insert(_table, rowOf(e), conflictAlgorithm: ConflictAlgorithm.ignore);
    await b.commit(noResult: true); });
  final held = await getByLibraryIds(fresh.map((e) => e.id));   // one read back
  ```
- **Risk:** the one-record-per-asset rule still holds through the unique `library_id` index. The relink and adoption path is unchanged when restored rows are waiting.

### BG-9 P1: analyze queue does a full refresh every 30 s while the library moves
- **Where:** `analyze_queue.dart:300-305` (on `libraryDelta(...).shape`) calls `refresh`, which runs `_outstanding` (`:396-440`). That is `analysisStore.listAll`, `facesByAsset`, `matchedAssets`, `staleDescriptorAssets`, `assetsWithDescriptors`, `taggedPeople`, then 40k `_specsFor`.
- **Scales:** "shape" changes continuously during a first scan or an iCloud sync. Each refresh is 6 whole-table decodes on the UI isolate, est. 0.3-1 s.
- **Fix:** patch the backlog from the delta's added and removed ids, as `_advance` already does for its batch. Run a full `refresh` only at run start, or at most every 5 min.
- **Risk:** none. This is a derived list.

### BG-10 P1: faces decode the photo twice
- **Where:** findFaces calls `on_device_analysis.dart:60` (`vision.faces`). matchFaces later calls `face_identity.dart:209-213` (`featurePrints`), which resolves the file again.
- **Native side:** every channel call decodes the image again (`VisionAnalysisChannel.swift:65`).
- **Scales:** per face photo: 2 BG-2 renders + 2 ImageIO decodes + 2 RT.
- **Fix:** one native call, `analyze(id)`. PhotoKit returns a 2048 image, then detect, then landmarks + embeddings for the found faces, all in the same decode. Faces and vectors come back together. matchFaces then never needs a file (its descriptors are stored).
- **Risk:** the descriptor pipeline id is unchanged, provided the 2048 upright input is the same.

### BG-11 P1: `checkImports` decodes the whole library's thumbnails
- **Where:** `record_fixer.dart:309-359`, triggered on every sync (`library_screen.dart:1808`) whenever any bucket import is still unchecked. `others` holds every library thumbnail, and each one gets `greyPrint` (a Dart JPEG decode) every time.
- **Scales:** 40k reads + decodes of 320 px, est. 10-30 ms each, so 7-20 min of CPU in an isolate per new import batch, repeated every time a new import appears.
- **Fix:** persist `greyPrint` (64 bytes) per `localId`, keyed by `thumbnailPath` + mtime, which is about 2.5 MB in total. Compute only the missing ones.
- **Risk:** none. This is advisory only; it never deletes.

### BG-12 P1: Flagged page re-scans every 15 s during uploads
- **Where:**
  - `flag_scan.dart:153-161`: `refreshIfChanged` compares `stamp()`, which includes `store.revision()`, and the revision moves on every record UPDATE (trigger at `asset_record_store.dart:597`), upload status changes included.
  - Each run (`:197-290`): bucket index, `listAll`, `advisor.cached` (2-3 MB JSON), duplicates, cloudOnly, `fixer.scan`, `HiddenRepair.findings`, `BucketFlags.detect` (`referencedKeys`, `allHoldings`), and `_publish` (a 40k map) several times.
- **Scales:** est. 1-3 s of UI-isolate work every 15 s while the page is open and uploads run.
- **Fix:** while `syncQueue.draining`, use `minGap: 2 min`, or build the stamp from a revision that excludes derivative-status-only writes.
- **Risk:** none.

### BG-13 P1: whole files in memory
- **Where:**
  - `carrier_upload.dart:165-180,218-232`: original + ciphertext + carrier, about 3x. This is documented at the call site.
  - `vault/cache.dart:121`: the whole carrier is read and decrypted, about 2x.
  - `gallery.dart:171`.
  - `storage_optimizer.dart:281`: `readAsBytes` on the **UI isolate**, then copied into the isolate.
- **Scales:** a 1 GB hidden video peaks around 3 GB, which risks a jetsam kill on 6-8 GB phones. The optimizer holds 2x a still on the UI heap.
- **Fix:**
  - Stream the carrier with a chunked AES-CTR + HMAC over `RandomAccessFile` (the cipher already has a chunked HMAC, `cipher.dart:68`).
  - In the optimizer, read inside the isolate: `Isolate.run(() => optimizeStill(File(path).readAsBytesSync(), ...))`.
- **Risk:** the carrier format must stay byte-identical. Test it against existing carriers before shipping.

### BG-14 P2: per-id platform and DB calls in loops
- `applyChange` (`photo_library_service.dart:290-297`): `fromId` + `getByLibraryId` per id. An iCloud burst of 5k ids is 10k RT.
- `_markMissing` / `_reconcileDeletions` (`:380-383`, `:444-460`): one `fromId` per unseen record. Bounded by the number unseen.
- `_measureOne` (`storage_advice.dart:778-800`): `fromId` + `fileSize` + `titleAsync`, 3 RT per photo. A full Optimize scan is 120k RT, est. 2-4 min.
- `PhotoLocationService.fillMissing` (`photo_location.dart:70-100`): 3 queries per record, 500 per run.
- **Fix:**
  - A native `assets(ids)` call built on `fetchAssetsWithLocalIdentifiers`, one call per 200 ids.
  - `getByLibraryIds` for the DB side.
  - Read the title only for items shown on the page.
  - Batch the `setLocation` writes.
- **Risk:** deletion checks must stay a live per-id answer. A batched fetch still is one (an id missing from the result means gone; a failed call means "can't say").

### BG-15 P2: `spotCheck` rewrites a growing map
- **Where:** `backup_verifier.dart:694-760`. `_spotCheckedAt` holds every cloud-only id it has checked and is decoded and re-encoded on each run (every 10 min, and every sync).
- **Scales:** 30k cloud-only photos is ~1.5 MB of JSON, est. 30-50 ms on the UI isolate per run.
- **Fix:** add a `spot_checked_at` column and pick with `ORDER BY spot_checked_at LIMIT 4`.

### BG-16 P2: `backUpRecords` sorts everything on every refill
- **Where:** `sync_engine.dart:93-112` (the `pendingAndFailed` and `thumbnailsOwed` getters each make a full pass) and `:193-195` (`newestFirst` sorts all of it). Called on every drain refill and on every change notification (`library_screen.dart:1730-1738`).
- **Scales:** fresh install with 40k pending: est. 20-50 ms UI-isolate stall per call.
- **Fix:** `records()` is `listAll`, already oldest-first. Walk it in reverse and stop at queue capacity; no sort.

### BG-17 P2: unbounded parallel `fromId`
- **Where:** `photo_library_service.dart:679-682` (`Future.wait` over every undeleted id). An Optimize run lifts `limit`, so this can be thousands of concurrent RT.
- **Fix:** run it in chunks of 8.
- **Risk:** the semantics are unchanged: each id still gets a live check, and a failed lookup still does not count as deleted.

### BG-18 P2: sync queue concurrency is batch-barrier
- **Where:** `sync_queue.dart:233-246`. A batch of `concurrency` jobs (default 2) all wait for the slowest one, so one large video leaves the other slot idle.
- **Fix:** run N workers, each looping on `dequeueNextPending`. This is a documented trade-off, so it is low priority.
- **Risk:** keep "in-flight jobs finish on pause".

---

## Suggested order
1. **BG-2 + BG-4 + BG-10:** stop materializing files for thumbnails and analysis. This is the largest CPU, flash and battery win. Then BG-2's upload switch, with the hash re-baseline.
2. **BG-1 + BG-3:** resume does only the recent lane plus a change-token delta, and launch work starts in stages.
3. **BG-5, BG-6, BG-7:** one-line to small fixes with large steady-state wins.
4. **BG-8, BG-9, BG-11, BG-12:** first-run and page-open costs.
5. **P2s** as touched.
