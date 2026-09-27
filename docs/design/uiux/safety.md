# Where Your Photos Are  `lib/viewer/safety_screen.dart`

The trust page. Reached from More's first row and from the tail of the
privacy note at the bottom of the library.

Everything else the app says about safety answers *who else can see this*.
This page answers the question people actually hesitate on before handing a
photo library to a piece of software: **will it still be here, and can I get
it out again.** Three sections, in that order — the copies that exist, the
work that isn't a photo, and how to recover with none of this software
involved.

```
 ‹                Where Your Photos Are

 Copies                                        ← 20 · 700
 Every photo this app knows about lives in one     hint: 11 muted
 or more of these. The bucket is the copy that
 outlives this phone — and the only one this
 app has no permission to delete from.

 ┌────┐  This iPhone
 │ 📱 │  12,481 photos
 └────┘  Deleted with the app, so never leave it as the only copy.
   ──────────────────────────────────────────────
 ┌────┐  slmx-archives2
 │ 🗄 │  12,480 of 12,481 originals backed up
 └────┘  1 still waiting to upload.
   ──────────────────────────────────────────────
 ┌────┐  iCloud Drive
 │ ☁ │  App data copied today at 4:26 PM.
 └────┘  Files → iCloud Drive → Photos Vault

 Last checked with your bucket today at 4:31 PM.   ← the status line: never
 [⟳ Check Now]  [↓ Test Restore]                     blank, see below

 ──────────────────────────────────────────────────

 ALBUMS, PEOPLE, CAPTIONS                       ← 12 · uppercase · muted
 The work you did on top of the photos. …

 In your bucket        Copied today at 4:26 PM.
 In iCloud Drive       Copied today at 4:26 PM.
 Refill the grid from your bucket             ›  ← only when something is owed
   312 photos have no picture on this phone yet.

 ──────────────────────────────────────────────────

 IF THIS APP IS GONE
 Your photos are ordinary files in a bucket you own. Nothing
 below needs this app, an account, or us.

 1. Sign in to your cloud provider's console and open your bucket.
 2. Download photos/app-data/index.csv and open it in any spreadsheet app.
 3. Sort by taken_at — that's your library, in order, with every album,
    person, caption and place.
 4. The file column is the object's name under photos/originals/.
```

## Rules this page exists to enforce

- **A count this app computed is a claim; a bucket's answer is a fact.** The
  numbers in the rows come from the local database, which is what every
  other screen shows. The line under them says when a real bucket last
  confirmed any of it, and that line is *never blank* — "never checked"
  is the answer this page came to give, so it says so in full.
- **Check Now fixes as well as reports.** Anything the bucket hasn't got
  goes back in the sync queue, and the row count moves. A screen that only
  counted would hand somebody a number and no way to act on it.
- **Test Restore is the whole point.** Three photos, chosen across the
  library rather than from one end, downloaded in full and hash-checked
  where the format allows it. One line that says *the backup is real* beats
  every paragraph of reassurance on this page, because the user watched it
  happen.
- **Two buttons, disabled with no bucket.** With nothing to ask, they are
  not controls, and the copies list already leads with the warning row that
  says so and pushes to Cloud Settings.
- **Hidden photos are counted nowhere here.** A number that moved when
  something was hidden answers the question the private album exists not to
  answer.
- **The iCloud rows are absent, not greyed, on a build that can't offer
  iCloud.** "Unavailable, and there's nothing you can do" is doubt with no
  action attached.
- **The recovery steps name the user's own prefix**, not a placeholder, so
  they can be followed rather than translated.

## Not on this page

Turning the app-data copies on and off stays in Cloud Settings, with the
buckets they're written to. This page reports; it isn't a second settings
screen for the same switches.
