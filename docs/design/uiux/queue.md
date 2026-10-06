# Queues

Two of them, and deliberately not one. Uploads are *owed* to a bucket and
want to finish; analysis is enrichment that can take all week. A single
list mixing them can't answer "is my library backed up?" without the reader
doing arithmetic on rows about faces.

| | opened from | what it does | costs |
|---|---|---|---|
| Backup queue | More | uploads, thumbnails, change checks | bandwidth |
| Analyze queue | More | finds faces, guesses who they are, (optionally) asks an AI | battery, and money only if asked |

Siblings in More, Backup above Analyze. The backup queue used to be a
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

`lib/settings/backup_queue_screen.dart` — a page, pushed from the status
card's `Queue · N ›` on Cloud Settings. Full mocks: `cloud-redesign.md`.

```
 ‹ Cloud           Backup Queue            ⏸   ⋯
 ╭ ⟳ Backing up… ─────────────────────────────────╮
 │ 12 waiting · 1 failed · 2 at a time            │
 │ Last synced today, 3:04 PM                     │
 ╰────────────────────────────────────────────────╯
 NEEDS ATTENTION · 1                    ( Retry All )
 UP NEXT · 12
 DONE · 4                                ( Clear Done )
```

- Failed rows first, with the error inline and ↻ to retry one.
- Each section shows 50 rows, then `Show N more`; built lazily.
- ⏸/▶ in the bar; ⋯ holds speed, Back Up Now, Clear Finished, Empty Queue.
- `Empty Queue` empties everything, in-flight rows too; a native transfer
  already uploading keeps going.
- Schedule and format live on Cloud Settings (Sync, Upload Quality).
- A row tap opens that photo; hidden photos are never named.
- Newest photo first, in what is queued and in what is claimed next.

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
 Tags and captions                          ○─  ← off; the only paid half
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
