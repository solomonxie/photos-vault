# Library — the one page

`lib/viewer/library_screen.dart`. No tabs: a day-grouped grid, then Albums /
People / Places / Events, then Utilities. Opens at the **newest** photo.

```
 ▁▁▁ status bar — tap = jump home ▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁
 Library                                      ＋    🔍
 ↑ the whole header is a tap target back to the newest photo
 Yesterday                                            ← bold day header
 ┌──────┬──────┬──────┐
 │      │      │    ◌ │   3 columns, 8pt gaps, square tiles
 ├──────┼──────┼──────┤   badges, bottom-right:
 │  ♥   │  ☁   │  ▶   │     ♥ favourite · ☁ cloud-only · ▶ video
 └──────┴──────┴──────┘     ◌ not yet backed up (dotted ring)
 Sep 12, 2026
 ┌──────┬──────┐
 │      │      │                                         ┆▮ Sep 2026
 └──────┴──────┘                                         ┆  ↑ date scrubber:
 ─────────────────────────────────────────────           ┆  right edge, fades
 Albums                                        ⊕         ┆  in while moving
 ┌────────┐ ┌────────┐ ┌────────┐
 │ cover  │ │ cover  │ │ cover  │   140×190 cards, horizontal
 └────────┘ └────────┘ └────────┘   Favorites · Videos are built in —
 Favorites   Videos     Nature      always there, nothing to delete
 24 photos   8 photos   61 photos   hold a user album → Delete Album !
 People                                     More ›
 ◯ ◯ ◯ ◯     100pt cards: avatar, name, count
 No people yet. Tap + to add someone.        ← empty
 Places
 📍 Kyoto                               12 ›
 📍 Home                                 4 ›
 Show All (18)                               ← folds past 5 rows
 Set a place on a photo and it shows up here. ← empty
 Events                            AI Suggestions ›
 📅 Graduation                           9 ›
 Set an event on a photo and it shows up here.
 Utilities                                   ← inset-grouped card, here only
 ┌─────────────────────────────────────────┐
 │ ▣ Cloud Settings                     ›  │
 │ ✦ Analyze Queue                    3 ›  │  ← count = answers waiting,
 │ ✨ AI Settings                        ›  │    not work left to do
 │                                         │    (the sync queue lives on
 │                                         │     Cloud Settings now)
 │ ⟳ Demo Data                          ›  │
 │ 👁⃠ Hidden                           3 ›  │
 │ 🗑 Recently Deleted                  5 ›  │
 └─────────────────────────────────────────┘
```

Search and import are **bar buttons, not fields**: the page opens at the
newest photo, so anything parked at the top of the scroll content sits a
decade of scrolling away.

```
 tap 🔍 ↓
 Library                                      ＋   Cancel   ← not a second ✕
 ┌─────────────────────────────────────────────────────┐
 │ 🔍 Search                                        ⊗  │  pinned under the
 └─────────────────────────────────────────────────────┘  bar, not scrolled
```

## States

```
 empty     ┌────────────────────────────────────────┐
           │              ▣  (photo_on_rectangle)   │
           │          No Photos Yet                 │
           │  Grant Photos access to back up your   │
           │  camera roll, or tap + to manually add │
           │  files from the Files app.             │
           │      [[ Try with Demo Photos ]]        │
           │      [ Add Files ]                     │
           └────────────────────────────────────────┘
           ← Albums/People/Places/Events are not drawn; Utilities still is
 busy      the ＋ and Demo Data rows go disabled while a pick is running
 ai edit   ⟳ AI working…            ← thin row under the nav bar
```

## Selection mode

Hold any tile. Tiles swap their badges for a checkmark, and the bar takes
over the bottom.

```
 ┌──────┬──────┬──────┐
 │  ✓   │      │  ✓   │
 └──────┴──────┴──────┘
 ▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔
  2 Selected                          Done
 ┌────────┬────────┬────────┬────────┐
 │   ▤    │   🏷   │   ⋯    │   🗑   │   4 across, 56pt tall
 │ Album  │Add Tag │  More  │ Delete │
 └────────┴────────┴────────┴────────┘
 Hold a photo to select more.        ← hint while exactly one is held
```

**Four buttons, not six.** Six across a phone left each one a 9-point glyph
over a word too small to read, and the two anybody presses — album and
delete — were the same size as the ones nobody does. `More` opens a sheet
with the batch *metadata* edits (Set Place, Set Event, Adjust Date & Time),
which belong together because that is what they are: a list of fields to
set, each opening a picker of its own anyway.

Everything on the bar is additive or a single-field set; `Delete` is the one
exception and it confirms (`Delete 3 photos?`).

## Hold, then sweep

```
 ┌──────┬──────┬──────┐
 │  ✓ ●─┼──●   │      │   hold a tile → selecting, finger still down
 │      │  ✓   │      │   keep going  → every tile it crosses joins
 └──────┴──────┴──────┘
```

One unbroken gesture. The hold has already won the gesture arena, so the
moves after it arrive as long-press updates rather than reaching the scroll
view — which is what makes holding and then sweeping possible at all
without the library scrolling out from under the finger. Once selecting, a
*sideways* drag across tiles does the same thing; up and down still scroll,
because there is a library to get through.

Which tile is under the finger is a hit test (each tile carries its record
in a `MetaData`), never arithmetic on the grid geometry and the scroll
offset — that arithmetic has to be kept in step with the layout, and
silently wouldn't be. Sweeping off a *selected* tile deselects, so a sweep
is undone by sweeping back.

## Per-tile actions (long-press, outside selection)

```
 ♥ Favorite / Unfavorite
 ▤ Add to Album…
 👁⃠ Hide
 🗑 Delete            !
```

Hidden and Recently Deleted supply their own sets (`Unhide`, `Recover`,
`Delete Permanently`).
