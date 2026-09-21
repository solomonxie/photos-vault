# Queues

Two of them, and deliberately not one. Uploads are *owed* to a bucket and
want to finish; analysis is enrichment that can take all week. A single
list mixing them can't answer "is my library backed up?" without the reader
doing arithmetic on rows about faces.

| | opened from | what it does | costs |
|---|---|---|---|
| Backup queue | Utilities | uploads, thumbnails, change checks | bandwidth |
| Analyze queue | Utilities | finds faces, guesses who they are, (optionally) asks an AI | battery, and money only if asked |

Siblings in Utilities, Backup above Analyze. The backup queue used to be a
block of pills on Cloud Settings, which made that page answer two questions
at once — where the copies go, and whether the upload is working. Cloud
Settings is the connections now.

Neither runs on its own until a frequency is set — "Manual" is the default
for both and it is a promise. `Sync Now` and the queue's own Resume are
how work starts otherwise.

Re-reading the camera roll is **neither** of them. It has its own pass
(`lib/photos/library_scanner.dart`), invisible and not configurable:
nobody chose it, nobody pays for it, and a pause switch that could stop
new photos arriving is a pause switch that breaks the app. One pass at a
time, at most one every five minutes, forced when coming back from
Photos.

# Backup queue

`lib/viewer/backup_queue_screen.dart` — a page, and named *backup* rather
than sync: what it does is put photos somewhere safe, and "sync" reads as
two-way.

```
 ‹              Backup Queue                     ⟳   ← ⟳ only while draining
 QUEUE (12)
 ┌───────────────────────────────────────────────┐
 │ [ ⟳ Sync Now ] [ ⏸ Pause ] [ 🕐 Manual Only ] │
 │ [ 🖼 Original ] [ ✓ Clear Done ] [ ⊗ Empty ]  │
 │ [ − 2 at a time + ]                           │
 ├───────────────────────────────────────────────┤
 │ Last synced Sep 19, 3:04 PM                   │
 └───────────────────────────────────────────────┘
 IN THE QUEUE
 IMG_4934.HEIC                                 ⟳
 Backing up original
 IMG_5001.MOV                             Waiting
 Backing up thumbnail
 Hidden photo                                  ✓   ← never named or previewed
 Backing up original
 IMG_4870.HEIC                                 ↻   ← failed keeps its row,
 Checking for changes                                ↻ retries it
 403 SignatureDoesNotMatch
 empty   Nothing in the queue — everything's backed up.
```

```
 paused      Paused            ← replaces the last-synced line
 full        Queue is full     ← why nothing new is going in
 never run   Never synced
```

Loaded before it draws. The paused flag lives in secure storage, and a page
that renders its default instead shows a stopped queue with a Pause button
and a live look — which is how uploads go missing for a week.

`Empty Queue` empties everything: waiting, failed, finished and in-flight.
A file already uploading keeps going — a native transfer can't be called
back — but its row is gone. A button that says Empty and leaves a dozen
green ticks reads as one that didn't work.

## The menus behind the pills

```
 🕐 Manual ▾                       ▣ Original ▾
 ┌─────────────────────────────┐   ┌──────────────────────────────────┐
 │ Sync Frequency              │   │ Backup Format                    │
 │ Runs only while the app is  │   │ Original: Full quality, byte-    │
 │ open — there's no           │   │ identical to your device —       │
 │ background-sync permission  │   │ larger uploads and more storage. │
 │ yet.                        │   │ Optimized (WebP): Re-encodes to  │
 │ ✓ Manual Only               │   │ cut upload and storage size, at  │
 │   Every 15 Minutes          │   │ a small, usually unnoticeable    │
 │   Every Hour                │   │ quality loss.                    │
 │   Every 6 Hours             │   │ Videos always back up at original│
 │   Daily                     │   │ quality…                         │
 │ ( Cancel )                  │   │ ✓ Original    Optimized (WebP)   │
 └─────────────────────────────┘   └──────────────────────────────────┘
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

Newest photo first, both in what gets queued and in what the drain claims
next. A camera roll's backlog is years deep; the picture someone wants safe
is the one they just took, and it shouldn't wait behind 2014.


# Analyze queue

`lib/viewer/analyze_queue_screen.dart` — the slow pass over the library, and
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
 IMG_4870.HEIC                        Waiting
 Matching faces to people
 empty  Nothing left to look at. New photos join the queue as they arrive.
```

Faces first across the whole library, then matching — a guess is only as
good as the faces already named, so the newest confirmations should be in
before the oldest guesses are made.

`Empty Queue` empties the list *and stops*. The outstanding half is derived
from the library, so a clear that kept running would refill in the same
frame and look like a button that does nothing. Resume is what builds it
again. The remaining count keeps counting — emptying a list on screen
doesn't change how much work there is.

Every job gets one attempt per run, whatever the outcome. The list is
derived, so a photo that was skipped (still in iCloud), threw, or had no
faces comes straight back as pending — and without that guard the pass
picks the same photo again, and again, and never reaches the second one.

No tabs. A queue is a list of work with controls above it; a second thing
behind a segment is a second screen wearing the first one's clothes.

The camera-roll scan used to be the first job in this pass. It isn't any
more: it is the one piece of work here nobody opted into, and a row that
can be paused alongside "ask an AI about this photo" invites stopping the
thing that makes new photos appear at all. It runs on its own, out of
sight. "Manual" stops this queue *looking at* photos; the library still
fills.
