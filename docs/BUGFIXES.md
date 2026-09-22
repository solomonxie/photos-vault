# Bugs worth remembering

Newest first. Only the ones whose *cause* was surprising — a log of
mistakes to not make twice, not a changelog.

## 2026-09-22 — The app froze for three seconds after dismissing a photo

**Symptom.** Drag a photo down to dismiss; the dismissal drags out for
seconds and taps on the grid do nothing afterwards — unless you scroll a
little, which fixes it instantly.

Two unrelated bugs wearing one symptom.

### The freeze: work nobody asked for, on the isolate that draws

Popping the viewer resolves the `await` on `Navigator.push`, so
`LibraryScreen.reload()` runs. It called `findUnnamedFaces`, which folds
every unnamed face against every other — a 128-number distance per
comparison. Seconds of solid computation on the UI isolate, triggered by
closing a photo, which changes neither the library nor the people.

- `reload()` skips the people/strangers work unless the library or the
  people list actually changed (`faces: true` forces it, for callers that
  know the analysis database moved).
- The fold runs in `Isolate.run` past 150 faces — below that the copy
  costs more than the work.
- One fold at a time: a camera-roll scan reloads once a second and would
  otherwise stack them.

### The dead taps: an orphaned scroll drag

`ScrollStopGuard` arms when a scroll view starts a drag, so the touch that
stops a moving list only stops it. Claiming the pull swapped the page's
physics to `NeverScrollableScrollPhysics`, which **replaces the scroll
position mid-gesture** — the drag it had started never ended and never
sent `ScrollEndNotification`. The guard stayed armed, swallowing taps,
until its stale-motion watchdog fired. The watchdog was 3 seconds; that
was the 3 seconds. A scroll disarmed it because it produced a fresh
start/end pair.

Fixed at the root — the page ends the scroll activity itself
(`position.jumpTo(position.pixels)`) so the end notification fires — and
the watchdog cut to 350 ms, since a list that is really moving notifies
every frame.

### Why the frame trace said everything was fine

`addTimingsCallback` only reports frames that happen. A blocked UI isolate
produces none, so a three-second freeze shows up as *silence*, not as a
slow frame. Clean frame timings next to a visible freeze is itself the
finding: the cost is between frames, not in painting.

## 2026-09-22 — The library got slower the longer it ran

Several causes, all of them work proportional to library size in places
that repeat (see CLAUDE.md's standing rules — each of these broke one).

- **`File.existsSync()` per record inside every `listAll()`**, repairing
  stale paths. Now one filtered query per launch (`_rehomePaths`).
- **A full 20k-row read over the platform channel per reload**, and
  `reload()` runs on every camera-roll page, every change iOS reports and
  every background round. `listAll()` is incremental now: rows carry
  `updated_at`, deletes go through `remove()`, and **nothing changed hands
  back the same list instance** — which is what lets `reload()` and the
  grid skip their own work on `identical`.
- **Six filter+sort passes over the library per `build()`** (`_active`,
  `_filtered`, Places, Events, videos, favourites). Computed once per
  reload into fields.
- **The whole grid geometry rebuilt per `build()`** — two `DateTime`
  allocations per record. Memoised on the record list's identity.
- **Album membership walked the library once per album.** One pass for
  all albums.
- **Unbounded thumbnail byte caches** — one JPEG per tile ever scrolled
  past, hundreds of MB, which iOS answers by squeezing the app. LRU-capped
  and dropped on `didHaveMemoryPressure`.
- **Missing assets re-probed on every rebuild** — two platform round trips
  per deleted photo per appearance. Remembered instead.
- **Full-resolution decode for a 95-point tile.** `cacheWidth` on the
  grid's `Image.file`.

## 2026-09-22 — Cloud-only photos drew as grey squares

`thumbnail_path` and `source_path` are absolute paths into the app
container, and iOS gives the container a new UUID on every reinstall — the
bundle-ID rebrand did it too. Every path stored before it pointed at
nothing, so backed-up photos read as "no longer available" with the bytes
sitting right there under the new UUID.

`_rehomePaths` rewrites them at launch, keeping the tail after
`/Application Support/` so a cached thumbnail lands back in `thumbnails/`
rather than loose at the top. The viewer also stopped saying "no longer
available" for a cloud-only photo, which is the one thing it isn't.

## 2026-09-22 — Every build failed to sign

`DEVELOPMENT_TEAM` in `project.pbxproj` is the placeholder
`REPLACE_WITH_YOUR_TEAM_ID` on purpose (no account identifiers in git),
which means no profile matches and nothing builds for a device.

The project now reads `$(LOCAL_DEVELOPMENT_TEAM)`, set in
`ios/Flutter/Signing.xcconfig` — gitignored, and pulled in with
`#include?` so a clone without it still opens.
