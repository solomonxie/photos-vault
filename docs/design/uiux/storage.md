# Flagged Items

`lib/viewer/flagged_items_screen.dart` — More → Flagged Items. One list of
everything worth a look: space this phone could give back, and bucket
objects the app doesn't understand. "Not enough space" is just another flag.

Was two pages (Flagged Items with an Optimize Storage sub-page, which had
its own select mode). Merged: a sub-page for one kind of flag, and checkboxes
to pick what the chip had already picked, were two steps nobody needed.

## Stories

- I want to free space without picking photos one by one → a chip narrows
  to a problem, one button fixes every listed item it applies to.
- I want to fix one thing → its row's own button.
- I want to see it working, and leave → the list drains as items are
  fixed; the run keeps going on other screens and after a kill.

## The page

```
 ‹ Library              Flagged Items                ( Rescan )
 ─────────────────────────────────────────────────────────────
 23 items to fix                             ← count, bold
 Frees up to 6.2 GB on this phone            ← only if any
 Scanned 19 Sep 2026, 12:16
 ( ALL 23 ) ( On device 14 ) ( Large file 6 ) ( Off-scheme… ▸   ← scrolls
                                                   sideways
 [[ 🗑 Remove from Device · 14 ]]  [ ⤒ Back Up First · 3 ]
 [ ✎ Rename · 4 ]  [ ⦸ Remove · 2 ]           ← one per solution, for
                                                 what the chip shows;
                                                 first filled
 ─────────────────────────────────────────────────────────────
 ▣  IMG_4934.HEIC                          [ Remove from Device ]
    62.4 MB · 14 Feb 2026
    On device · Large file
 ▤  holiday.jpg                                    [ Rename ] ⋯   ← ⋯ = other
    3.1 MB · 2 Mar 2019                                         fixes, sheet
    Name doesn't follow the app's scheme
 empty   Nothing flagged
 loading Looking for problems…    /   Measuring 400 of 3,812…
```

A solution button counts only what's listed under the current chip and not
already queued. Destructive ones confirm once for the batch (`Remove from
Device: 14 items?`); Back Up, Import and Ignore don't ask.

Kept out of the buttons, one at a time only: **Import anyway** on a likely
old copy, and **Rename** on a file the same size as one already here — both
are guesses a person should look at. A likely duplicate gets **Ignore** as
its batchable fix instead.

## Running: the list is the queue

```
 ╭─────────────────────────────────────────────────────────╮
 │ ⟳ Fixing 12 of 40…                              ( Stop )│
 │ [██████████░░░░░░░░░░░░░░░░░]                           │
 │ Keeps going while you use the rest of the app.          │
 ╰─────────────────────────────────────────────────────────╯
 ▣  IMG_4934.HEIC                                       ⟳    ← running
 ▣  IMG_4935.HEIC                                 Waiting
 ▣  IMG_4936.HEIC                                [ Retry ]
    Couldn't finish. Nothing was changed.                    ← stays, red
```

```
 done
 ╭─────────────────────────────────────────────────────────╮
 │ ✓ Done                                            ( OK )│
 │ [███████████████████████████]                           │
 │ Freed 1.4 GB. 2 could not be fixed and are still listed.│
 ╰─────────────────────────────────────────────────────────╯
```

- A fixed row folds away (height + fade, ~0.3 s), so the list visibly
  shrinks rather than jumping. A failed one stays with its reason and a
  Retry.
- Stop ends the run after the item in flight; what hadn't started is
  dropped and stays listed.
- More → Flagged Items shows `⟳ 28` while a run is going, from anywhere.

**Where it runs.** `FixQueue` (`lib/photos/fix_queue.dart`) is owned by the
library screen, not the page: leaving the page changes nothing. Waiting
jobs are filed in app state, so a kill or a crash resumes them on the next
launch (bucket jobs after a fresh listing, so a rename that landed just
before the kill isn't done twice). While iOS has the app suspended nothing
runs; it carries on when the app comes back.

Batches: a removal goes 100 at a time — one iOS confirmation and one bucket
check per hundred, not per photo. Re-encodes go 10 at a time, so the list
moves. Bucket fixes go one by one.

## On this phone: the four problems, and the fix each gets

| Tag | Raised when | Fix |
|---|---|---|
| On device | backed up, local copy still here | Remove from Device |
| Large file | photo ≥ 10 MB, video ≥ 100 MB | (whichever of the others applies) |
| High resolution | longest edge > 4000 px | Reduce Resolution — 2560 px, WebP |
| Optimizable format | PNG / BMP / TIFF | Convert to WebP |

Two size thresholds because one would be wrong for both: 10 MB is a fat
photo and an unremarkable video.

**"Not backed up" is not one of them.** It's a backup problem, answered by
the sync queue, and a page about reclaiming space that listed every
un-uploaded photo would be a second, worse copy of it. It shows up here
only as the **Back Up First** button: every fix on this page either
replaces the local copy or deletes it, so all of them wait on the bucket
holding the original. A photo with a real problem and no backup gets that
button; a photo with nothing wrong with it isn't listed at all.

Gentlest fix wins after that: shrink it in place if this app owns the file,
and only drop the local copy when there's nothing smaller to make of it.
"Large file" never picks a fix on its own — it's a lens on the others, so a
3 GB video that can't be shrunk *or* removed isn't listed. Something with
nothing to offer is just a complaint.

The tags describe the **file**, not only the button: a camera-roll photo
says "High resolution" even though PhotoKit owns its bytes and the only fix
is a removal. That's what explains the size.

## What is and isn't touched

Rewriting only ever touches a file this app wrote itself (imported, or an
original pulled back down), and only once the bucket has the original: what
gets replaced has to stay recoverable. A camera-roll photo's bytes belong
to PhotoKit, so the honest fix there is Remove from Device — the bucket
keeps it, the grid draws the cached thumbnail, the viewer offers to
re-download.

**Videos are removable.** They get their poster frame from the photo
library itself (`ThumbnailCache`'s fallback), so the grid has something to
draw once the movie is gone — the only thing that ever ruled them out. The
whole movie is never exported to make that picture. The one exception is a
video imported by hand with no library entry and nothing cached: there's
no frame to be had, so it isn't listed.

Hidden and binned photos are never measured or listed, same rule as the
queues.

## Scanning: resumable, and mostly already done

The findings are **filed in app state**, so opening the page shows last
time's answer immediately instead of walking the library again.

The pass is **resumable and saved as it goes**. Walking a ten-year library
is a channel call per photo; a pass that only wrote its answer at the end
meant leaving the page halfway threw the whole thing away and the next
visit started at zero. Every 50 photos the running total goes to disk,
along with which ids have been measured, so stopping costs at most that
many and coming back picks up mid-library.

Two speeds, by where the user is:

| | when | how much |
|---|---|---|
| Background sweep | the idle trickle, once nothing else wants the phone | 50 photos a round |
| On the page | the moment it opens, if the pass isn't finished | flat out |

Being *on* the page is the one time somebody is waiting for the answer.
Off it, this is the app keeping its own answer fresh and it has all day —
so in practice the page is usually already answered when it opens.

`Rescan` is the only thing that throws the measurements away and walks the
library again. A photo added since is picked up without one: it simply
isn't in the measured set. Applying a fix re-measures just the photos it
touched.

Only the measured *size* comes back from the cache. Backed up or not,
still on the device, binned since — all of that is re-read off the record
on open, because it's free and a stale answer would offer to fix something
already fixed.

The count line is the progress line while a scan runs — `Measuring 400 of
3,812…`.

Sizes for camera-roll assets come from `PHAssetResource.fileSize`:
metadata, not a download. A ten-year library can be sized without pulling a
single photo back from iCloud, which is the only reason this page can exist
at all.

A batch removal is **one** iOS confirmation, not one per photo
(`deleteManyFromLibrary`), capped at 100 — past a hundred thumbnails that
sheet stops being something anyone reads, and a confirmation nobody can
check is not a confirmation.
