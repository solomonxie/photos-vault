# Queues

Two of them, and deliberately not one. Uploads are *owed* to a bucket and
want to finish; analysis is enrichment that can take all week. A single
list mixing them can't answer "is my library backed up?" without the reader
doing arithmetic on rows about faces.

| | opened from | what it does | costs |
|---|---|---|---|
| Sync queue | Cloud Settings | uploads, thumbnails, change checks | bandwidth |
| Analyze queue | Utilities | re-reads Photos, finds faces, (optionally) asks an AI | battery, and money only if asked |

# Sync queue

`lib/viewer/sync_queue_sheet.dart` — a sheet, never a page: a transient
status list is something you glance at and dismiss.

```
 ▁▁▁▁▁▁▁▁▁▁▁▁ ▬▬▬ drag handle ▬▬▬ ▁▁▁▁▁▁▁▁▁▁▁▁
 Queue (12)                            Paused    ← or "Full"
 ┌──────┬───────────────┬──────────────┐
 │  ⏸   │      ✓        │      ⊗       │
 │Pause │  Clear Done   │ Empty Queue  │   icon over label, 44pt tall
 └──────┴───────────────┴──────────────┘
 ┌───┐ IMG_4934.HEIC                        ⟳
 │▣  │ Backing up original
 └───┘
 ┌───┐ IMG_5001.MOV                    Waiting
 │▣  │ Backing up thumbnail
 └───┘
 ┌───┐ Hidden photo                          ✓   ← a hidden item is never
 │▣  │ Looking at the photo                        named or previewed
 └───┘
 ┌───┐ IMG_4870.HEIC                         ↻   ← failed keeps its row
 │▣  │ Checking for changes
 └───┘   403 SignatureDoesNotMatch
 empty   Nothing in the queue — everything's backed up.
 [ Retry Failed ]
 Checking 42 photos for changes…      ← the whole-library pass
```

Three kinds of work, each said plainly rather than hidden behind one
spinner:

```
 Checking for changes      re-hashes a local file to spot an edit
 Backing up original
 Backing up thumbnail
```

Tapping a row opens that photo in the viewer — the obvious question about a
row, especially a failed one, is "which photo is that?". Without an opener,
rows are simply not tappable rather than tappable and inert.

A drag from the top of the list dismisses the sheet; anywhere else it
scrolls. Speed lives with the settings page, not here — `[ − ] 3 at a
time [ + ]` in `cloud.md`.


# Analyze queue

`lib/viewer/analyze_queue_sheet.dart` — the slow pass over the library, and
only that. What it *finds* is answered on the photo it's about (see
`detail.md`): a photo screen can show the picture the suggestion is about,
and an inbox of little cards can't.

```
 ▁▁▁▁▁▁▁▁▁▁▁▁ ▬▬▬ drag handle ▬▬▬ ▁▁▁▁▁▁▁▁▁▁▁▁
 184 photos to look at              ⟳
 [ ⏸ Pause ] [ 🕐 Every hour ] [ − 1 at a time + ]
 ─────────────────────────────────────────────
 Tags, events and captions                  ○─  ← off; the only paid half
 Costs one call to your AI vendor per photo.
 Faces and scanning stay free either way.
 ─────────────────────────────────────────────
 Photos library                            ⟳
 Re-reading Photos for new and changed items
 IMG_4934.HEIC                        Waiting
 Looking for faces
 empty  Nothing left to look at. New photos join the queue as they arrive.
```

No tabs. A queue is a list of work with controls above it; a second thing
behind a segment is a second screen wearing the first one's clothes.

The camera-roll scan is the first job in the pass, not a loop of its own —
one queue you can see, pause and pace, rather than a background grind with
no face. "Manual Only" stops it *looking at* photos; coming back from
Photos still re-reads the library, because a photo taken while you were
away isn't in it at all until that happens.
