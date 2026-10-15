# 05 Analysis, faces, people — findings

Scope: `lib/photos/` ai_*, analyze_queue, on_device_*, document_text, face_*, unnamed_faces, person*, profile_*, suggestion_review, photo_location, thumbnail_cache, image_pipeline, file_hash, manual_add, photo_editor. Callers read where they decide behaviour: `viewer/detail_screen.dart`, `ask_ai_screen.dart`, `face_group_screen.dart`, `people_screen.dart`, `person_page_screen.dart`, `library_screen.dart`, `ios/Runner/VisionAnalysisChannel.swift`, `FaceEmbedder.swift`, and photo_manager 3.12.0 / image 4.9.2 from the pub cache.
Device evidence comes from a copy of `photos_vault.db` in `/tmp/pv_review05/`: 4514 records, 127 private, `analyze_pace=4`, 188 place cells. The pull has no `ai_analysis.db` or `people.db`, so the face findings are code-only.

## P0

### 1. "Ask AI about this photo" sends the photo to a vendor. The store listing says no photo ever goes to one. It isn't gated for China, and it works on private-album photos — CONFIRMED
- `detail_screen.dart:1949-1977` (and the tile at `:2606-2619`) reads the file and hands it to `AskAiScreen`. `ask_ai_screen.dart:78-82` then sends it with the date, place, caption and tags (`ai_chat.dart:216-226,262-269,300-306`).
- `docs/release/listing.md:304,355` says "No photo is ever sent to an AI service". README `photos` and commit 5224fa5 ("Stop sending photos to AI vendors") say the same. The photo option comes from 9051bca (Sep 25), which landed *before* 5224fa5, and it survived that commit.
- There's no `aiOffered` check on this tile. Only `person_profile_screen.dart:1646` and `library_screen.dart:2848` check it. So the China build shows an AI entry that the release notes (`docs/release/README.md:27`) say is hidden. Tapping it fails with "No AI key configured", because `usableKeys` filters the vendors out.
- `DetailScreen` is also the viewer for `private_album_screen.dart:925`. A hidden photo, with its caption and place, is two taps from a vendor.
- Fix: remove the photo option (this matches the listing and 5224fa5). Or, if it stays:
  - gate it on `aiOffered && record.passcodeHash == null`;
  - correct the listing, privacy policy and App Privacy answers.

### 2. "Who else looks like this?" offers hidden, private, binned and purged photos, preselected, and Save links them to an open-namespace person — CONFIRMED (path)
- `FaceGrouping.like`/`likeAnyOf` (`face_grouping.dart:86-99,138-143`) search every descriptor row. They filter only on `personId != null` and never consult the records.
- `AiAnalysisStore` has no per-asset delete at all. A photo that was described and then hidden, binned or purged keeps its `face_descriptor` rows. This is the normal order: photos are analysed long before anyone hides them.
- `face_group_screen.dart:103-124` keeps every returned face in `_group`/`_keeping`, and its grid draws `getByLocalId` records with `assetImage`.
  - For a hidden record that is `Image.file(record.sourcePath)` (`asset_grid.dart:212-221`). Whether pixels show depends on the carrier file format, so the tile rendering is PLAUSIBLE.
  - The listing and linking are certain. `_save` (`:190-222`) calls `addAssets(person, …)` and `remember(...)` for hidden photos, and for purged ids too (`_keptAssets` reads `_group`, not `_records`).
- `findUnnamedFaces` (`unnamed_faces.dart:56-62`) *does* filter hidden, private and deleted records. The circle is clean; the page it opens is not.
- Fix:
  - pass the set of active, open localIds into `like`/`likeAnyOf` and drop everything else;
  - build `_group` only from faces whose record resolved;
  - on hide and purge, delete the asset's `ai_analysis`, `face_descriptor` and `face_suggestion` rows.

## P1

### 3. "Find more of Alice" searches from *everyone's* confirmed faces and files the result as Alice — CONFIRMED
- `face_group_screen.dart:105-107` calls `likeAnyOf(await analysisStore.confirmedFaces())`. That is the reference set for every person (up to 40 each), not Alice's.
- Every unnamed face near *any* named person comes back preselected. Save links them to Alice and `remember`s them as Alice (`:213-222`), which poisons her reference set for every later match.
- Fix: add `confirmedFacesFor(personId)`, and drop candidates that are nearer to another person's references.

### 4. Re-describing a stale face erases its name — CONFIRMED
- `FaceIdentityService.suggestFor` (`face_identity.dart:153-164`) re-describes a stale descriptor and saves it with no `personId`. `saveDescriptor` uses `ConflictAlgorithm.replace` (`ai_analysis_store.dart:256-263`), so `person_id` becomes NULL.
- `staleDescriptorAssets` (`:360-369`) doesn't filter on `person_id`, so `analyze_queue.dart:302-309` reopens confirmed photos for matching.
- The pipeline 3 → 4 switch (SFace) already took that path for every photo described in pipeline 3:
  - single-face photos get re-learned by `learnFaces`;
  - group shots that were named by tapping a face lose the confirmation, both the reference vector and `faceOfPersonIn`.
- Every future pipeline bump repeats this.
- Fix: on re-describe, update only `vector`, `revision` and `confirmed_at`, keeping `person_id`.

### 5. If SFace doesn't load, face matching never finishes and starts over every run — CONFIRMED (code), PLAUSIBLE (trigger)
- Without the model, Swift returns **pipeline 3** whenever the eyes are found (`VisionAnalysisChannel.swift:86-95`). 3 is not in `livePipelines = {2,4}` (`on_device_vision.dart:64`), so every new descriptor is born stale.
- `suggestFor` re-describes it, `staleDescriptorAssets` reopens it, and the next run redoes the whole library's faces. It also fills the 60-row window (#6).
- The trigger is real enough: `faceModelStatus` exists because the model failed to load once ("sent us looking in the wrong place once already", `FaceEmbedder.swift:29-30`).
- Fix: without the model, return pipeline 2, or treat 3 as live when `faceModel` is false. Never mark an asset outstanding when it can only be re-described into the same stale space.

### 6. The analyze pass stops when the newest 60 jobs can't complete — CONFIRMED (logic), PLAUSIBLE (trigger)
- `_run` picks batches from `jobs.value`, which is `outstanding.take(capacity=60)` (`analyze_queue.dart:235-236,452-461`). A job that "succeeds" without writing anything stays outstanding:
  - `_findFaces` with `path == null` (`:517`);
  - `remember` or `suggestFor` with no path or an empty descriptor.
- Each such job is marked done, is kept out by `attempted`, and still fills a slot. Once 60 of them sit at the top, `batch.isEmpty` ends the run. Every later run does the same, so everything older is never analysed.
- Triggers: offline with iCloud-only newest photos, or #5.
- Fix: pick batches from the full outstanding list minus `attempted`, not from the 60-row display list. Report path-null as `skipped`, not `done`.

### 7. Face boxes come from the un-rotated image; crops and avatars are drawn rotated — PLAUSIBLE
- Swift runs Vision on `UIImage(contentsOfFile:).cgImage` with no orientation (`VisionAnalysisChannel.swift:48-67`). That is the raw sensor buffer, which ignores the EXIF orientation.
- `decodePhoto` → `img.decodeJpg` *bakes* EXIF orientation in (`image-4.9.2 .../_jpeg_quantize_io.dart:214-241`).
- The camera-roll file is photo_manager's `fetchFullSizeImageFile` → `UIImageJPEGRepresentation(image, 1.0)`, which keeps the orientation tag.
- So for a portrait iPhone shot (orientation 6), the boxes are in landscape space and `FaceCrops._cropAll` cuts the wrong region. The descriptor stays self-consistent, because Swift crops the raw buffer too.
- Check on the phone: Find Faces on a portrait photo and compare the crops with the faces.
- Fix: decode upright once with `CGImageSourceCreateThumbnailAtIndex(kCGImageSourceCreateThumbnailWithTransform: true, maxPixelSize: 2048)`. This also fixes #14.

### 8. One failed geocode marks a 5 km cell "nothing there" forever, and can stall the fill — CONFIRMED (code)
- `_lookUp` returns null on *any* exception (rate limit, offline) (`photo_location.dart:100-107`). `fillMissing` caches that null (`:81-84`), and nothing expires it.
- Every photo in that cell is skipped forever. `listAwaitingPlaceName(limit: 500)` keeps returning the same newest 500 rows, so once they all sit in null cells, older photos are never reached.
- Device: 188 cells, none null yet.
- Fix: cache null only for a successful empty answer. On error, stop the run and back off.

### 9. Ask AI sends WebP or HEIC bytes labelled `image/jpeg` — CONFIRMED (mislabel), PLAUSIBLE (vendor rejects)
- `_shrink` → `optimizeStill` → `img.encodeWebP`, which is **lossless VP8L** (`image_pipeline.dart:112`, package `webp_encoder.dart:7`). On failure (HEIC, PNG) it sends the raw bytes.
- All three request shapes hard-code `image/jpeg` (`ai_chat.dart:223,267,303`). Anthropic validates the media type against the bytes. With only an Anthropic key, every photo question fails, and `runWithKeys` burns through every other key first.
- Moot if #1 removes the feature. Otherwise: `encodeJpg(q 80)` inside `Isolate.run`, and pass the real MIME type.

### 10. Manual add can point a record at a half-copied file — CONFIRMED (path), PLAUSIBLE (trigger)
- `manual_add.dart:66-69`: `if (!exists) copy`. A kill mid-copy (a large video) leaves a truncated `$hash.ext`.
- Re-adding the same file sees it exists and upserts a record with the full file's `contentHash` pointing at the truncated bytes. That truncated file is what gets backed up.
- Fix: copy to `.part` and rename. Or verify the size or hash when the file already exists.

## P2

11. **Ask AI decode, resize and encode run on the UI isolate** — CONFIRMED. `ask_ai_screen.dart:99-103` calls `optimizeStill` synchronously on a full-size photo. Wrap it in `Isolate.run`.
12. **Every analyze batch redoes library-wide work on the UI isolate** — CONFIRMED. After every batch (≈0.4 s at pace 4), `refresh` → `_outstanding` (`analyze_queue.dart:286-379,471`):
    - runs `listAll`, filters and sorts every record;
    - decodes every `ai_analysis` row and every face string;
    - runs four more full-table queries;
    - builds a job and calls `displayNameFor` for *every* outstanding photo.
    `_learnFaces` also re-reads all memberships per job (`:531`). Fix: compute the outstanding set once per run, update it in place, and only rebuild the visible 60.
13. **Matching exports the full-size photo it doesn't need, and leaves a full JPEG per photo in Caches** — CONFIRMED.
    - `suggestFor` resolves the path before checking for stored descriptors (`face_identity.dart:150-151`). After the first person is named, `clearAllSuggestions` re-matches every photo with faces.
    - Each match goes through `filePathFor` → `entity.file` (`sync_engine.dart:507-520`). photo_manager allows the network (an iCloud download) and writes `<sha>_exif.jpg` at quality 1.0 into Caches. The app never calls `PhotoManager.clearFileCache()`.
    - Fix:
      - resolve lazily, only when a descriptor is missing;
      - use `localFileFor` (no iCloud) for analysis;
      - clear photo_manager's cache after a run.
14. **Native memory: up to 4 full-size decodes in parallel, one per face, plus a racy model init** — PLAUSIBLE.
    - Each channel call re-decodes the whole photo (`UIImage(contentsOfFile:)`, `VisionAnalysisChannel.swift:50`): once for `faces` and once *per face* for `featurePrint`. 24 MP is about 96 MB a decode, and pace 4 (the device setting) runs four at once on `DispatchQueue.global`.
    - `FaceEmbedder.model` is a Swift `lazy var` (`FaceEmbedder.swift:33`), read from concurrent threads. That is unsynchronised init, so it can load twice or crash.
    - Fix:
      - downsample via CGImageSource (#7);
      - one call per photo that returns all faces and descriptors;
      - make the model a `static let` or use a serial queue.
15. **Face crops decode the whole photo in Dart, and never work for HEIC** — CONFIRMED.
    - `FaceCrops.of` decodes full size for 160 px crops (`face_crops.dart:59-66,78`), about 36 MB of RGB and around a second per 12 MP open.
    - `decodePhoto` returns null for HEIC: manual imports and the `.heic` custody files seen on the device. Find Faces then reports "nothing found" although Vision found faces and saved them (`detail_screen.dart:2034-2042`).
    - Fix: crop natively in the vision channel, which already holds the CGImage.
16. **N+1 queries and UI-isolate math in the face group page** — CONFIRMED.
    - `_load` calls `getByLocalId` per face, up to 500 (`face_group_screen.dart:111-115`).
    - `_save` runs `getByLocalId` + `remember` per kept face (`:213-222`), about 5 queries each, sequentially.
    - `likeAnyOf` compares references × candidates × 128 on the UI isolate (`face_grouping.dart:86-99`). With #3 that is every person's 40 references.
    - Fix: `getByLocalIds`, a batched `rememberMany` in one transaction, and the distance loop in `Isolate.run`.
17. **Unnamed faces recomputed on every scan tick** — CONFIRMED.
    - `library_screen.dart:1231-1258` reruns `findUnnamedFaces` whenever `libraryChanged`, which is once a second during a scan.
    - The fold is in an isolate, but `allDescribedFaces` (every vector copied by `Uint8List.fromList`) and the filter and sort of all records run on the UI isolate (`unnamed_faces.dart:46-92`).
    - Fix: key it on the analysis and people change marks, not the library tick, and decode the rows inside the isolate.
18. **`decodePhoto` has no size guard** — PLAUSIBLE. A panorama (about 64 MP) or a huge PNG decodes to hundreds of MB inside a Dart isolate, and jetsam kills the whole app (`image_pipeline.dart:17-35`). Fix: read the dimensions from the header first, and route oversize images to the native encoder.
19. **`optimizeStill` says "lossy WebP" but is lossless** — CONFIRMED (`image_pipeline.dart:90-113`). Output is often larger than the source. **→ Step 04:** check what the optimizer's Dart fallback path writes.
20. **Vendor model ids are probably retired** — PLAUSIBLE (no network check allowed). `gemini-1.5-flash` and `llama-3.2-11b-vision-preview` are the likeliest; `grok-2-vision-1212` and `pixtral-12b-2409` may be too (`ai_chat.dart:98-167,292`). Every failure falls through `runWithKeys` and bumps counters. Fix: re-verify the ids per vendor and surface the vendor's error body.

## P3

21. **`FaceMatcher.ceiling = 0.30` for every space** (`face_matcher.dart:59`). For SFace that means similarity ≥ 0.70, well above its 0.363 line, so suggestions rarely fire. Use per-pipeline values, as `FaceGrouping` already does.
22. **A circle's count doesn't match what opening it shows.** `_fold` counts over `flat` (untagged, open, ≤ scanLimit), while `like()` searches every descriptor (`unnamed_faces.dart:131-155` vs `face_grouping.dart:138-143`). The comment at `:126-131` claims they reconcile.
23. **The analysis DB is never pruned.**
    - Rows for purged photos stay forever.
    - `forgetFaces` clears boxes but keeps descriptors keyed by the old rects. If Vision returns slightly different boxes, `like()` lists the same face twice.
24. **`PersonStore.remove` isn't atomic.** It is 7 deletes with no transaction (`person_store.dart:521-534`). Descriptor cleanup is separate and null-aware (`people_screen.dart:533`: `faceIdentity?.forget`), so deleting with no identity service leaves the faces named after a deleted id.
25. **AI key store loose ends.**
    - `_bumpRequestCount` is read-modify-write on the whole key list (`ai_settings_store.dart:157-163`). Racing `addKey`/`removeKey`, it can resurrect or drop a key.
    - The Gemini key goes in the URL query (`ai_chat.dart:290-293`); it should use the `x-goog-api-key` header.
    - The vendor error body is discarded.
26. **`ProfileTransfer.read` is N+1.** It runs 5 queries per person, and `write` has no transaction (`profile_transfer.dart:41-63,85-100`).
27. **An iOS update can leave pipeline-2 descriptors stranded.** `isStale` checks only the pipeline (`on_device_vision.dart:74`). When iOS bumps the feature-print revision, old pipeline-2 vectors become incomparable and are never re-described.
28. **Dead residue of the paid tagging pass.** `AiAnalysisStore.save`, `saveSuggestion` and `unreviewed` have no callers, and the `tags`/`description` columns plus the `_SuggestionCard` accept/dismiss only serve legacy rows. Stale comments:
    - "avoids re-billing OpenAI" (`ai_analysis_store.dart:16`);
    - "Only confirmed faces" (`:36-41`), contradicted by v5;
    - "Tagging is left to the vendor models" (`on_device_analysis.dart:12`);
    - "a model … is a download" (`face_crops.dart:14`).
29. **Faces leave the phone in backups, contrary to the design doc.** Face embeddings ride in the app-data backup (`app_snapshot.dart:156-161`), but `docs/design/face-recognition/DESIGN.md` still says "Excluded from … the bucket backup". That covers faces of hidden photos (#2), keyed by PhotoKit ids. **→ Step 03:** confirm the snapshot is encrypted, then fix the doc.

## Improvement suggestions

- **One native call per photo.** Downsample upright to ≤ 2048 px, detect faces, then return the boxes, the 160 px crops and all descriptors together. That replaces 1 + N full decodes in Swift and one more in Dart (#7, #13, #14, #15), and fixes HEIC.
- **Run the analyze queue off a cursor instead of re-deriving it.** Read the outstanding set once per run in SQL, using a `NOT IN` join on `ai_analysis`/`face_suggestion`, then pop from it. Drop the per-batch `refresh` (#6, #12).
- **Treat face data as part of the record's lifecycle.** Hide, purge and rescan should drop or keep `ai_analysis.db` rows explicitly; one `forgetAssets(localIds)` on the store covers it (#2, #23).
- **Gate battery-heavy work.** Pause the analyze pass in Low Power Mode or at thermal state ≥ serious. Pace 4 on a hot phone is the case CLAUDE.md warns about.
- **Thumbnails for camera-roll assets:** prefer PhotoKit's `thumbnailDataWithOption`, or `ImageEncodeChannel`, over the pure-Dart full decode in `ThumbnailCache._defaultEncode`. Keep `image` for manual files only.

## Checked and fine

- `decodePhoto` is the only decode entry. There's no `img.decodeImage` anywhere, and none of these files import `material.dart`.
- Isolates: `photo_editor`, `ThumbnailCache._defaultEncode`, `FaceCrops`, `storage_optimizer._defaultEncode` and `detail_screen._reencode` all decode off the UI isolate. The only exception is #11.
- `AnalyzeQueue._activeRecords` and `findUnnamedFaces` exclude hidden, private, binned and local-deleted records. `needingThumbnails` and `ensureFor` never write a plaintext thumbnail for a private record.
- AI keys live in the Keychain (`flutter_secure_storage`), scoped separately in demo mode, and are not in the app-data snapshot. The profile Ask AI shows the context before sending and is gated by `aiOffered`.
- Grouping thresholds are defined per space, folding is stricter than verification, and cosine distance returns null across revisions or lengths, so spaces never mix.
- `allMemberships`, `peopleFor` and `forgetAssets` are single, chunked queries. `people_screen._reload` has no N+1.
- `FaceRect.encode`/`decode` round-trips exactly, so face keys are stable. `FaceDescriptor.decode` copies before viewing, so it is alignment-safe.
- `docxText` unescapes `&amp;` last, which is correct, and `plainText` rejects binary.
- `hashFile` streams, and `encodeThumbnail` keeps small images' bytes as they are.
