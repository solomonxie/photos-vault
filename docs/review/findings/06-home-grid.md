# 06 Home & grid — findings

Scope: `viewer/` library_screen, asset_grid, asset_grid_view, photo_grid_layout, photo_grid_sliver, grid_skeleton, date_scrubber, year_wheel, scroll_stop_guard, select_all, select_sweep, detail_screen, zoom_page_route, live_photo_view, gif_view, motion_playback, video_controls; `photos/thumbnail_cache.dart`. Includes the uncommitted diff: home rests on Albums (`restKey`/`restInset`), `_showThenBackUp`, `_scanRecentThenAll`, and `getByLibraryIds`.

Counts: P0 0 · P1 5 · P2 8 · P3 11

## P1

**1. Two reloads running at once can put an older library on screen. CONFIRMED**
- `library_screen.dart:1164-1281`. `reload()` reads `listAll()` first, then awaits five more stores and maybe `findUnnamedFaces` (seconds). At the end it applies whatever list it read at the start (`:1274`). Nothing orders the reloads.
- Scenario: during a scan, `onPage` fires `unawaited(reload())` once a second (`:950`).
  - Reload A reads list N and starts the face pass.
  - Reload B, a second later, reads N+1. `_findingFaces` makes it skip the face pass, so it finishes first and draws N+1.
  - A then finishes and draws N. The newest page of photos disappears from the grid, and the grid re-anchors.
  - If the final `_showThenBackUp` reload is the one overtaken, the grid stays stale until some later reload.
- Fix: run one reload at a time with a dirty flag: if a reload is running, mark it dirty and re-run once it ends. Or keep a generation counter and drop the result if `gen != _reloadGen`.

**2. (Uncommitted change) Search results are drawn above the screen. CONFIRMED**
- `asset_grid_view.dart:266-278`, `library_screen.dart:2533-2534`.
- Scenario: the app opens resting on Albums. Tap search and type. `filtered` shrinks, so `wasResting && grew` re-anchors on Albums' top. That top now sits right under the few result rows, so the results scroll off above the viewport. You see Albums/People/Places and no results.
  - Before this change, the anchor put the newest result at the bottom of the screen.
- Also: the pinned search field (`:2601-2617`, about 52 pt) sits on top of the scroll view. `restInset` only accounts for the 44 pt nav bar, so the Albums header hides under the field.
- Fix: pass `restKey: null` while `_searching`, so the grid anchors to the newest photo. Or jump to the grid's end when results change. Add the search bar's height to `restInset` while it is open.

**3. Search matches camera-roll photos by their PhotoKit UUID. CONFIRMED**
- `library_screen.dart:1319-1327` matches `(r.sourcePath ?? r.localId).toLowerCase()`. Camera-roll records have no `sourcePath`, so the text searched is `photo:1A2B…-…/L0/001`.
- Scenario: typing "bed", "cafe", "add" or a single "a" returns random photos whose hex id contains those letters. A photo's description, tags, place and people are never searched.
- Fix: search `description`, `tags`, `location` and the file name. Build one lowercase haystack per record once per `reload`, never per keystroke.

**4. Rotating the phone loses the scroll position. CONFIRMED**
- `asset_grid_view.dart:261-283`. When the width changes, the layout is rebuilt, but the rest, pin and past-grid restores all require `grew` (record count changed).
- iPhone allows landscape (`Info.plist:104-109`). Columns are fixed at 3, so tiles get about 2.2× taller and the grid's total height grows with them.
- Scenario: resting on Albums, rotate. The raw pixel offset now lands mid-library. Reading 2019, rotate, and you land years away. The next rebuild sees `isAtNewest == false`, so the position is never corrected.
- Fix: treat a width change like growth: `if (grew || widthChanged)` for all three branches.

**5. `markedId` never reaches the tile, so the face-group "you came from here" ring is never drawn. CONFIRMED**
- `asset_grid.dart:139-160`. `_tileFor` takes `markedId` but builds `AssetTile` without `marked:`.
- `face_group_screen.dart:271` relies on it. The parameter was added in 29c0aa6 and never wired up.
- Fix: `marked: record.localId == markedId`.

## P2

**6. (Uncommitted change) `_showThenBackUp` doubles full reloads per sync event. CONFIRMED**
- `library_screen.dart:1542-1548`. Called at `:604`, `:922`, `:972`.
- With a backup target set, `_backUpRecords` writes job/status rows, so the second `reload()` sees a new `listAll` instance. It then redoes everything on the UI isolate:
  - `_rebuildSorted` over all rows
  - `_activeOf` sort
  - `_applyLibrary`
  - `PhotoGridLayout.of`
  - another `findUnnamedFaces`
- So every iOS change notification (each photo taken) now costs two full passes instead of one.
- Fix: in the second pass, skip faces/people when only upload-status columns moved. Better: have tiles read upload status from a notifier keyed by `localId`, so queueing a backup needs no library reload. Fixing #1 (coalescing reloads) also helps.

**7. Per-reload work on the UI isolate repeats a sort, and the layout allocates per record. CONFIRMED (cost PLAUSIBLE)**
- `_activeOf` (`library_screen.dart:1309-1315`) re-sorts by `createdAt` a list that `listAll` already returns sorted that way (`asset_record_store.dart:1594,1640`). That is a second O(n log n) per reload.
- `PhotoGridLayout.of` (`photo_grid_layout.dart:94-99`) calls `_midnight(dateOf(r))` about twice per record: `toLocal()` plus a new `DateTime` each time, around 200k allocations for 50k photos.
- Both run once a second during a scan (#1) and on every drain/reload.
- Fix: drop the sort in `_activeOf`, since filtering keeps the order. Compute day keys as an int once per record, or move `_activeOf` and the layout into `Isolate.run` alongside step 01's `listAll` fix.

**8. Re-anchor and pin restore run after the frame, so one wrong frame is painted each time the grid grows. CONFIRMED**
- `asset_grid_view.dart:162-170, 217-244`. `_build` swaps `_layout`. The viewport then lays out and paints with the old `pixels`, and only the post-frame `jumpTo` corrects it.
- Scenarios:
  - On a cold start, the first frame shows the oldest photos and starts their PhotoKit requests (wasted, queued ahead of the real ones; see #9).
  - During a scan, the screen jumps once a second while resting or pinned: older pages land above, so Albums/the pinned row shift down for a frame.
- Fix: in `_build`, after the new layout, call `position.correctBy(newLayout.totalExtent - oldLayout.totalExtent)` for the rest and past-grid cases, and the computed delta for a pin. That corrects before layout, with no notification and no extra frame. Alternative: `CustomScrollView(center:)` on the sliver after the grid, so growth above never moves what is below.

**9. Thumbnail requests are never cancelled. CONFIRMED (latency impact PLAUSIBLE)**
- `asset_grid.dart:865-905, 1065-1078`. Every tile that mounts sends a `highQualityFormat` + `ResizeMode.exact` PhotoKit request (`thumbnail_cache.dart:27-32`) with `networkAccessAllowed`, and it runs to completion after the tile is gone.
- A scrubber drag (`date_scrubber.dart:211`, a `jumpTo` per pointer move) or a long fling mounts thousands of tiles. Once the finger stops, the visible tiles wait behind that backlog.
- photo_manager 3.12 accepts a `PMCancelToken` on `thumbnailDataWithOption`.
- Fix:
  - Cancel in `dispose`.
  - Skip requests while the scroll velocity is high (`Scrollable.recommendDeferredLoadingForContext`).
  - Preheat the window around the viewport with `PhotoCachingManager`.
  - Use `opportunistic` delivery for grid tiles.

**10. The thumbnail cache is capped by count, but it also holds the viewer's 1200 px stand-ins. CONFIRMED**
- `_remember` (`asset_grid.dart:978-986`) stores every size in a 2000-entry LRU that was sized for "≈20 KB a tile, ~40 MB". The detail stand-in asks for 1200 px fitted (`detail_screen.dart:1343-1349`), which is about 200–400 KB each. Those bytes go into both `_thumbnailBytes` and `_fittedThumbnails`.
- Scenario: swiping through 300 photos in the viewer adds about 60–120 MB of Dart heap that is never released until memory pressure.
- Fix: cap by bytes, or keep sizes over 400 px only in `_fittedThumbnails`.

**11. While a search is open, every `setState` re-lays out the whole grid. CONFIRMED**
- `_filtered` (`library_screen.dart:1319`) returns a new list on each build when `_query` is non-empty. `AssetGridView` memoises on list identity (`asset_grid_view.dart:261`), so every rebuild runs a full filter pass plus a `PhotoGridLayout.of`.
- Rebuild triggers include every selection toggle, every sweep move (`:1924-1935`), fix-queue ticks and analyze-queue ticks.
- Fix: cache the filtered list keyed on `(_query, _active)`.

**12. A zoomed photo is decoded at full sensor resolution. CONFIRMED (OOM PLAUSIBLE)**
- `detail_screen.dart:1702-1712, 1717-1720`: `cacheWidth: null` once zoomed. A 48 MP photo is about 190 MB of RGBA, and a panorama is more, on top of the screen-sized copy. That risks a jetsam kill on 6 GB phones.
- `maxScale` is 3, so 3× the screen width is the most that is ever visible.
- Fix: `cacheWidth: min(native, 3 × _decodeWidth)`.

**13. Swiping past a video exports the whole file and creates a player for it. PLAUSIBLE**
- `detail_screen.dart:1123-1160` → `PhotoLibraryService.resolveFile` (`photo_library_service.dart:692-697`, `entity.file`), on every page mount, with no cancellation. The export keeps running after the page is disposed (`_resolvePath` only checks `mounted` afterwards).
- Scenario: an iCloud-optimised 4K video gets downloaded and exported just because it was swiped past. Exports collect in the plugin cache, and there is no `clearFileCache` anywhere in `lib/`.
- Fix: resolve and initialize only after the page has settled (debounce `onPageChanged`), use `PMCancelToken`, and clear the plugin file cache periodically.

## P3

**14. Re-anchoring on every rebuild while resting can kill a drag that just started. PLAUSIBLE.** `asset_grid_view.dart:284-288`. Each `LibraryScreen.setState` while within 1 px of the rest schedules `jumpTo`, and `jumpTo` calls `goIdle()`, which disposes an active drag. Only re-anchor when the rest target actually moved (store the last target and compare).

**15. Changes that keep the record count but change the grid's height skip all restores. CONFIRMED.** `asset_grid_view.dart:267`. Examples: a date edit merges two days (one fewer 44 px header), or one photo hidden and one added. Use `totalExtent` changed, not `length` changed.

**16. `_onReviewCountChanged` rebuilds the whole screen for a value nothing reads. CONFIRMED.** `library_screen.dart:743-747, 658`. `build` never reads `_analyzeQueue.remaining`, and each rebuild also re-triggers #14. Remove the listener.

**17. The scrubber builds a new `DateFormat` and label on every scroll frame, even while hidden. CONFIRMED.** `date_scrubber.dart:224-227, 257-272`. Compute the label only while `_dragging`, and keep one `DateFormat` instance.

**18. `YearWheel` creates a `FixedExtentScrollController` in `build` and never disposes it. CONFIRMED.** `year_wheel.dart:31`. Each rebuild leaks a controller and resets the wheel. Make it a StatefulWidget that owns the controller.

**19. The info panel decodes the whole original just to read its pixel size. CONFIRMED.** `detail_screen.dart:2369-2374`. This happens for manual files. Use `ui.ImmutableBuffer` + `ui.ImageDescriptor.encoded`, which reads width and height without decoding.

**20. (Uncommitted change) Docs still describe the old newest-photo anchor. CONFIRMED.**
- `asset_grid_view.dart:14-18, 157-160`; `library_screen.dart:2653-2656` ("the page opens at the *newest* photo"); README `viewer` ("opens scrolled to the *newest* photo").
- `library_screen.dart:2634-2640`: `_jumpHome`'s doc comment ended up on `_albumsKey`.

**21. Cloud-only tile fetches are never dropped. PLAUSIBLE.** `asset_grid.dart:244-268`, `cloud_thumbnails.dart:42,57`.
- Every cloud-only tile ever built stays queued for an S3 GET, even after it scrolls past.
- Each landing copies the whole `fetched` map and rebuilds every mounted cloud tile.
- Fix: drop the request on dispose and notify per id.

**22. Album card `_cover` walks `_videos`/`_favorites` on every build. CONFIRMED.** `library_screen.dart:3067-3075`, whenever a cover is chosen. Resolve it once in `reload`.

**23. (Uncommitted change) Backup is now queued after the reload, which widens a race with Hide. PLAUSIBLE.**
- `library_screen.dart:1542-1547`. A photo is visible, and can be hidden, before `_backUpRecords(added)` runs with its stale copy.
- `sync_engine.dart:147-150` only checks the stale copy's `passcodeHash`, so a queue row naming the hidden photo can appear. The coordinator refuses the upload itself (`backup_coordinator.dart:104`), and `_resumeQueue` cleans the row up next launch.
- Fix: in `backUpRecords`, re-read the records by id before queueing.

**24. Dead code and small leaks. CONFIRMED.**
- `PhotoGridLayout.offsetOfDay` (`photo_grid_layout.dart:300-306`) is unused, and it is linear.
- `DetailScreen._scrollControllers` (`detail_screen.dart:197-201`) holds one controller per visited page until the viewer closes.

## Improvement suggestions

- **Reload pipeline**: one reload at a time with coalescing (#1). Diff `listAll` into "rows changed" vs "only status columns changed", so a status-only change skips faces, albums and layout (#6). Precomputed day keys (#7).
- **Anchoring**: correct offsets inside layout rather than post-frame (#8). Use one trigger, "the extent above the anchor changed", covering growth, width and same-length edits (#4, #15). While searching, rest on the newest result (#2).
- **Grid thumbnails like Photos**: `PhotoCachingManager` preheat, cancel tokens, deferred loading during flings (#9).
  - Tiles are about 120 pt (360 px at 3×), but requests ask for 200 px fitted, so the grid is upscaled 1.8–2.4× and looks soft next to Photos. Ask for `tileExtent × devicePixelRatio` and budget the cache in bytes (#10).
- **Sweep-select**: no auto-scroll when the finger reaches the top or bottom edge, so a range longer than one screen can't be swept (Photos does this).
- **Status-bar tap**: from rest it goes straight to the oldest photo, and no single tap gets you to "newest photos" any more. Consider resting → newest → oldest.

## Checked and fine

- Derived lists (`_active`, `_videos`, `_favorites`, `_recentlyAdded`, `_places`, `_deletedCount`) are computed once per reload in `_applyLibrary`, and `build` reads fields.
- The grid layout is memoised on list identity + width. Row lookups are binary searches. `estimateMaxScrollOffset` is exact, so `jumpTo` is exact.
- In scope, there is no `material.dart`, no `img.decodeImage`, and no `*Sync` file I/O. Export re-encode goes through `compute` / native ImageIO, and `ThumbnailCache._defaultEncode` uses `Isolate.run`.
- Hidden, passcode and binned records are excluded from home (`_activeOf`). The Hidden row shows no count.
- Video, Live Photo and GIF lifecycles: controllers are disposed with their page. `LivePhotoView` disposes a controller that finished loading after unmount, and `_onMotionPlayingChanged` checks `mounted`. `GifView` disposes its first frame.
- `ScrollStopGuard` arms only on user drags (`dragDetails != null`). Programmatic anchor jumps are not braked.
- `SelectSweep` builds its index once per sweep. `selectNextBatch` is capped at 100.
- Anchor edge cases from the diff:
  - Empty library: no anchor, skeleton/empty state, and the Albums sliver is absent, so the fallback is harmless.
  - All photos hidden: the page opens at the top.
  - Few photos, or content below Albums shorter than the screen: the target clamps to `maxScrollExtent`, which is correct.
  - People/Places filling in below Albums does not move an unclamped rest.
- `_scanRecentThenAll`: `runRecent` swallows errors (`_guarded`), so the full pass always follows. `run(force)` joins a pass already in flight.
- `getByLibraryIds` (diff): chunks of 400 ids × 2 params stay under 999. It has the same "first row wins" semantics as `getByLibraryId`. The new `library_id` index covers it.
