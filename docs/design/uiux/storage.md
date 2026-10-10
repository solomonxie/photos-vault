# Flagged Items

`lib/viewer/flagged_items_screen.dart` — More → Flagged Items. A list of
**actions**, not files: each says what it does, to how many, and what it
saves; tapping one opens its items (`flagged_action_screen.dart`). Shared
wording in `flagged_copy.dart`.

Was a file list with problem chips, per-row buttons and ⋯ menus, and
batch pills keyed by solution. Two taxonomies (problem chips, solution
pills), labels with no explanation, and iPhone photos mixed with bucket
files — every tap a guess. Replaced.

## Stories

- What can I do, and what will it do? → one row per action, with a
  sentence and the count/saving.
- Do it for most, not all → the action's page, everything ticked; untick.
- Leave this alone → Hide from List, on every action's page (iPhone
  photos and bucket files alike; remembered across scans).
- Watch it, or leave → the run card; items drop out as they're done.

## What it offers

- No backup queue: backing up runs on its own. A photo the bucket lost is
  a red line under the heading.
- **On this iPhone** — Optimize (smaller copy; the next sync sends it to
  the bucket too), Delete Duplicates (exact copies by backup hash; one
  kept, rest to Recently Deleted). Never deletes a local copy otherwise:
  that's the person's call, in Photos.
- **In your bucket** — Optimize (smaller copy in the bucket only; the
  phone keeps its original, hash kept so sync doesn't re-send it), Delete
  Duplicates (same size + ETag; a record's copy kept), Delete Old Copies,
  Add to Library, Fix Names, Convert to HEIF, Delete Thumbnails, Add Anyway.

## The page

```
 ‹ Library              Flagged Items                ( Rescan )
 23 items to fix
 Checking 40 of 189 new photos…      ← only while new ones are measured
 ON THIS IPHONE
 │ ⤓ Optimize — … 122 items · saves about 2.1 GB                   › │
 │ ⧉ Delete Duplicates                                              › │
 IN YOUR BUCKET
 │ ⤓ Optimize · ⧉ Delete Duplicates · 🗑 Delete Old Copies · …      › │
```

The last scan's result is the heading at once; a pass over photos added
since is a line under it.

## An action's page

```
 ‹                    Remove from iPhone          Deselect All
 Deletes the full photo from this iPhone to free space. …
 ◉ ▣ p12.jpg   233.9 KB · Jul 12, 2026
 ◉ ▣ p20.jpg   …                               (tap row = tick)
 ───────────────────────────────────────────────────────────
  Hide from List          [[ Remove from iPhone · 14 ]]
```

- The fuller explanation on top, never both short and long.
- Running items show ⟳ / 🕒; failed ones stay ticked-able with their
  reason. The page closes itself when nothing is left.
- Only permanent bucket deletes (thumbnails, old copies) ask again;
  iOS asks for photo removals itself.

## Running

```
 ╭─────────────────────────────────────────────────────────╮
 │ ⟳ Fixing 12 of 40…                              ( Stop )│
 │ [██████████░░░░░░░░░░░░░░░░░]                           │
 │ Keeps going while you use the rest of the app.          │
 ╰─────────────────────────────────────────────────────────╯
```

```
 done
 ╭─────────────────────────────────────────────────────────╮
 │ ✓ Done                                            ( OK )│
 │ [███████████████████████████]                           │
 │ Freed 1.4 GB. 2 could not be fixed and are still listed.│
 ╰─────────────────────────────────────────────────────────╯
```

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

## While it runs

Under "Fixing N of M": what it is doing now — `Optimizing · IMG_3381.MOV ·
512 MB` (Downloading, Uploading, Deleting, Renaming, Adding, Converting,
Waiting for your OK in the iOS prompt).

Originals replaced in Photos (Optimize Space) and library duplicates are
not deleted batch by batch: each is filed in `pending_swaps_v1` as it is
done, and one iOS prompt takes all of them when the run ends. A quit before
that prompt asks on the next launch; declined, the smaller copies are taken
back out.
