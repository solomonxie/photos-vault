# Queues

Two of them, and deliberately not one. Uploads are *owed* to a bucket and
want to finish; analysis is enrichment that can take all week. A single
list mixing them can't answer "is my library backed up?" without the reader
doing arithmetic on rows about faces.

| | opened from | what it does | costs |
|---|---|---|---|
| Sync queue | Cloud Settings | uploads, thumbnails, change checks | bandwidth |
| Analyze queue | Utilities | finds faces, (optionally) asks an AI | battery, and money only if asked |

Neither runs on its own until a frequency is set — "Manual" is the default
for both and it is a promise. `Sync Now` and the queue's own Resume are
how work starts otherwise.

Re-reading the camera roll is **neither** of them. It has its own pass
(`lib/photos/library_scanner.dart`), invisible and not configurable:
nobody chose it, nobody pays for it, and a pause switch that could stop
new photos arriving is a pause switch that breaks the app. One pass at a
time, at most one every five minutes, forced when coming back from
Photos.

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
 [ ⏸ Pause ] [ 🕐 Manual ] [ − 1 at a time + ]
 ─────────────────────────────────────────────
 Tags, events and captions                  ○─  ← off; the only paid half
 Costs one call to your AI vendor per photo.
 Faces and scanning stay free either way.
 ─────────────────────────────────────────────
 IMG_4934.HEIC                        Waiting
 Looking for faces
 empty  Nothing left to look at. New photos join the queue as they arrive.
```

No tabs. A queue is a list of work with controls above it; a second thing
behind a segment is a second screen wearing the first one's clothes.

The camera-roll scan used to be the first job in this pass. It isn't any
more: it is the one piece of work here nobody opted into, and a row that
can be paused alongside "ask an AI about this photo" invites stopping the
thing that makes new photos appear at all. It runs on its own, out of
sight. "Manual" stops this queue *looking at* photos; the library still
fills.
