# Optimize Storage

`lib/viewer/storage_optimization_screen.dart` — Utilities → Optimize
Storage. Where the space went, and one fix per photo.

A page, not a sheet: the list is long, it's re-read after every change, and
each row leads somewhere.

```
 ‹ Library            Optimize Storage            ( Select )
 ─────────────────────────────────────────────────────────
 Free up to 6.2 GB                        ← the answer, in bold
 174 items, using 8.1 GB on this device   ← what's there now
 Back up first. Shrinking or removing a copy leaves the
 bucket holding the only full-quality one.
 Scanned 19 Sep 2026, 12:16              [ ⟳ Rescan ]

 ( All 174 ) ( On device 140 ) ( Large file 18 )     ← chips wrap
 ( High resolution 4 ) ( Optimizable format 2 )               selected = accent
 ─────────────────────────────────────────────────────────
 ┌───────────────────────────────────────────────────┐
 │ ┌───┐  IMG_4934.HEIC                              │
 │ │▣  │  14 Feb 2026 · 62.4 MB · 8064 × 6048        │
 │ └───┘                                             │
 │  On device   Large file   High resolution          │  grey tags
 │                        [[ 🗑 Remove from Device ]] │  filled pill
 └───────────────────────────────────────────────────┘
 ┌───────────────────────────────────────────────────┐
 │ ┌───┐  scan-0043.png                              │
 │ │▣  │  11 Feb 2026 · 41.0 MB · 6000 × 4000        │
 │ └───┘                                             │
 │  On device  Large file  High resolution  Optim…    │
 │                        [[ ⤡ Reduce Resolution ]]  │
 └───────────────────────────────────────────────────┘
 empty  Nothing to optimize. Everything is backed up, and no
        local copy is bigger than it needs to be.
```

"Free up to X" rather than "about X to reclaim": *reclaim* is a word about
the app's bookkeeping, and the reader's question is "how much space do I
get back?". **Up to**, because the two re-encodes can't know what the
encoder will produce until it runs — a removal is exact, so the figure
reported *afterwards* drops the hedge and says "Freed 1.4 GB".

The second line is what makes the first mean anything: 6.2 GB out of 8.1
is a different page from 6.2 out of 6.3.

**Biggest file first.** The page is about where the space went, and the
answer to that is the size on disk — not how much of it a particular fix
happens to give back. Tapping a card opens the photo; the obvious question
about a row is "which one is that?".

The action is a filled pill sized to its words, at the end of the card. It
was a full-width bordered box, which read as an empty text field rather
than something to press.

## Select mode

`Select` in the nav bar, or a hold on any card. Cards become checkboxes,
the fix button goes (the bar drives it now), `All` appears beside `Done`.

```
 ‹ Library            Optimize Storage      ( All ) ( Done )
 ...
 ┌───────────────────────────────────────────────────┐
 │ ┌───┐  IMG_4934.HEIC                         ◉    │  accent ring
 ...
 ─────────────────────────────────────────────────────────
  23 selected · frees up to 1.4 GB          [[ Optimize ]]
```

Every item still applies **its own** fix. A mixed selection does the right
thing per photo rather than the same blunt thing to all of them — which is
also why there's no per-chip "fix all of these" button: the chip is a
filter, `All` + `Optimize` is the bulk action.

## The four problems, and what each offers

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
