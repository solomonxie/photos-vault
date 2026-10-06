# Cloud + Backup Queue redesign

Replaces the Cloud Settings and Backup Queue layouts in `cloud.md` and
`queue.md` (`SettingsScreen`, `BackupQueuePanel`). Add-bucket and the bucket
browser are unchanged.

## Why

Today: two flat headings, ~9 pill buttons, a footer line, a hint paragraph
per section, and a queue crammed into a half-height popup with its own pill
wall. No answer to "am I safe?" without reading three places.

## Stories

| # | As a user I want… | so that… |
|---|---|---|
| 1 | one glance that says if my library is backed up | I don't read settings to find out |
| 2 | Sync Now and see it move | I know it's working |
| 3 | to see, add and open my buckets | I control where copies go |
| 4 | schedule / quality / order, rarely touched, out of the way | the page stays calm |
| 5 | albums, people, tags copied to iCloud and my bucket, plus file export/restore | a reinstall loses nothing |
| 6 | a queue page where failures stand out and I can retry, pause, clear | stuck uploads get fixed |
| 7 | to be told about files added to the bucket outside the app | I can import them |

## Principles

- **Status first, settings last.** The top card answers story 1 and 2.
- **Inset grouped lists** (iOS Settings idiom): rows in rounded cards,
  `title … value ›`. No pills. One primary button on the page: Sync Now.
- **Value on the row, choice in a sheet.** Schedule, quality, order show
  their current value and open the existing action sheets.
- **Explanations behind ⓘ**, one sentence at most inline.
- Queue is a **page**, not a popup. Failures first.

## Cloud page

```
 ‹ More                 Cloud

 ╭────────────────────────────────────────────────╮
 │ ◉ All backed up                                │ ← status card
 │ 184 of 210 photos · 2 buckets                  │
 │ ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓░░░░  88%                    │
 │ Last synced today, 3:04 PM                     │
 │ [[ ⟳ Sync Now ]]               Queue · 26  ›   │
 ╰────────────────────────────────────────────────╯

 BUCKETS
 ╭────────────────────────────────────────────────╮
 │ ☁ my-photos                                  › │
 │   s3://my-photos/photos-vault/ · ca-central-1  │
 ├────────────────────────────────────────────────┤
 │ ☁ cold-storage                               › │
 │   cos://cold-storage-12…/vault/ · ap-guangzhou │
 ├────────────────────────────────────────────────┤
 │ ⊕ Add a Bucket                                 │ ← accent text
 ╰────────────────────────────────────────────────╯

 UPLOADS
 ╭────────────────────────────────────────────────╮
 │ Sync                              Manual     › │ ← sheet: frequency
 │ Upload Quality                    Original   › │ ← sheet: format
 │ Fill Order                  Photo by Photo   › │ ← only with 2+ buckets
 │ Find New Files in Buckets   3 new files      › │ ← runs the scan/import
 ╰────────────────────────────────────────────────╯

 APP DATA ⓘ
 ╭────────────────────────────────────────────────╮
 │ iCloud Drive                              ─●   │
 │   Last copy 2 hours ago                        │
 ├────────────────────────────────────────────────┤
 │ Your Buckets                              ─●   │
 │   Last copy today, 9:02 AM                     │
 ├────────────────────────────────────────────────┤
 │ Export to File                             ⇧   │
 │ Restore from File                          ⇩   │
 ╰────────────────────────────────────────────────╯
 Also kept on this iPhone for 7 days.
```

### Status card states

```
 no bucket   ◌ Not backed up yet          [[ Add a Bucket ]]
 syncing     ⟳ Backing up… 26 left        [[ ⟳ Syncing… ]]·   ▓▓▓░░ 
 paused      ⏸ Paused · 26 waiting        [[ Resume ]]
 failed      ⚠ 3 uploads failed           [[ ⟳ Sync Now ]]  Queue · 3 ›   ← orange
 lost        ⚠ 2 photos missing from the bucket        Safety ›          ← red
 waiting     ◔ 26 photos waiting          [[ ⟳ Sync Now ]]
 all done    ◉ All backed up              [[ ⟳ Sync Now ]]   ← green dot
 loading     ⟳                                              ← page spinner
```

Priority when several apply: lost > failed > paused > syncing > waiting >
all done.

### Other states

```
 empty buckets      BUCKETS card holds only  ⊕ Add a Bucket
                    UPLOADS rows dimmed·, App data bucket row: "Add a bucket first"
 iCloud blocked     row subtitle replaced by the reason; fix line in accent
                    "Settings → your name → iCloud → Drive → turn on"
 busy toggle        switch replaced by ⟳ while the copy is written
 one bucket         Fill Order row hidden (not dimmed — it can't matter)
```

### ⓘ copy

```
 APP DATA ⓘ → "Albums, people, tags, captions and places — everything that
               isn't the photo itself. Copied once a day, on days something
               changed, and pulled back automatically after a reinstall."
 Sync value → existing frequency sheet message (mentions iOS background runs)
```

## Backup Queue page

Pushed from the status card's `Queue · 26 ›`. Not a popup.

```
 ‹ Cloud           Backup Queue            ⏸   ⋯

 ╭────────────────────────────────────────────────╮
 │ ⟳ Backing up…                                  │ ← summary card
 │ 12 waiting · 1 failed · 2 at a time            │
 │ Last synced today, 3:04 PM                     │
 ╰────────────────────────────────────────────────╯

 NEEDS ATTENTION · 1                    ( Retry All )
 ╭────────────────────────────────────────────────╮
 │ IMG_4870.HEIC                                ↻ │
 │ Checking for changes                           │
 │ 403 SignatureDoesNotMatch                      │ ← orange
 ╰────────────────────────────────────────────────╯

 UP NEXT · 12
 ╭────────────────────────────────────────────────╮
 │ IMG_4934.HEIC                                ⟳ │
 │ Backing up original                            │
 ├────────────────────────────────────────────────┤
 │ IMG_5001.MOV                           Waiting │
 │ Backing up thumbnail                           │
 ├────────────────────────────────────────────────┤
 │ Hidden photo                           Waiting │ ← never named
 │ Backing up original                            │
 ╰────────────────────────────────────────────────╯

 DONE · 4                                ( Clear )
 ╭────────────────────────────────────────────────╮
 │ IMG_4801.HEIC                                ✓ │
 ╰────────────────────────────────────────────────╯
```

```
 ⋯ menu (action sheet)
 ┌──────────────────────────────┐
 │ Speed: 2 at a time      − + │  ← stepper row
 │ Sync Now                     │
 │ Clear Finished               │
 │ Empty Queue                ! │
 └──────────────────────────────┘
```

### Queue states

```
 empty      ◉ Nothing in the queue — everything's backed up.   [ Sync Now ]
 paused     ⏸ Paused                              ⏸ becomes ▶ in the bar
 full       summary line: "Queue is full — the rest follows as it drains"
 draining   summary ⟳, running rows show ⟳
 long list  each section capped at 50 rows; "Show 312 more" row at the end
```

### Interactions

| Target | Action | Result |
|---|---|---|
| status card Sync Now | tap | runs a sync; card turns to syncing |
| `Queue · N ›` | tap | pushes Backup Queue |
| bucket row | tap | bucket browser |
| Sync / Upload Quality / Fill Order | tap | existing sheet, value updates on the row |
| Find New Files | tap | scan + import, result dialog |
| queue row | tap | opens that photo |
| ↻ | tap | retries that job |
| ⏸ / ▶ | tap | pauses / resumes the queue |

## Copy keys (new)

| Key | String |
|---|---|
| status.allDone | All backed up |
| status.progress | {done} of {total} photos · {n} buckets |
| status.syncing | Backing up… {n} left |
| status.paused | Paused · {n} waiting |
| status.failed | {n} uploads failed |
| status.waiting | {n} photos waiting |
| status.none | Not backed up yet |
| queue.attention | Needs attention |
| queue.upNext | Up next |
| queue.done | Done |
| queue.retryAll | Retry All |

## Notes

- Cupertino only, no Material. Colours from `settings_section.dart` tokens;
  green `#30D158` / orange / red match the grid underline.
- Dropped from the page: the pill wall, the standalone footer stats line, the
  "Import from Bucket" duplicate in the queue, the hint paragraphs.
