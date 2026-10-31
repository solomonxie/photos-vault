# Library

The home page: every photo, newest first, grouped by day.

```
╔══════════════════════════════════════════════════════════════════════════╗
║ Photos Vault   ┌───────────────────────────────────┐          ✓ Synced   ║ ← status chip, sync.md
║                │ 🔍 Search captions, people, places │                    ║
║                └───────────────────────────────────┘     [ Upload ]      ║
╟───────────┬──────────────────────────────────────────────────────────────╢
║ Photos  ● │ Today                                                        ║
║ Albums    │ ┌──────┬──────┬──────┬──────┬──────┬──────┐                  ║
║ People    │ │      │      │      │ ▶0:14│      │    ♥ │                  ║ ← ♥ favorite, ▶ video
║ Places    │ └──────┴──────┴──────┴──────┴──────┴──────┘                  ║   with duration; no
║ ───────── │ Tue · Oct 28, 2026 · Lisbon                                  ║   other badges
║ Bin       │ ┌──────┬──────┬──────┐                                       ║
║           │ │      │ LIVE │      │                                       ║
║           │ └──────┴──────┴──────┘                                       ║
║ ⚙         │ Sun · Oct 12, 2026                                           ║
║           │ ┌──────┬──────┬──────┬──────┬──────┬──────┐                  ║
║           │ │      │      │      │      │ ⌛   │      │                  ║ ← ⌛ = no thumbnail
╚═══════════╧══════════════════════════════════════════════════════════════╝   yet (HEIC upload)
```

- Virtualized: only rows in view plus one screen above and below exist in
  the DOM. Tiles take 6–10 columns depending on width.
- A scrubber (year/month) appears on the right edge on hover once there
  are more than 500 photos.

Reached from: launch · sidebar Photos · Esc from Viewer

## Selection
```
║ 3 selected        ( Add to album… )  ( Add person… )  ( Favorite )  ( Delete )!  ✕ ║
║ Sun · Oct 12, 2026                                              [x] Select day     ║
║ ┌──────┬──────┬──────┐                                                             ║
║ │ ✓    │ ✓    │      │   ← click a tile's corner circle, or ⇧-click for a range    ║
```

## States
```
first load   ⟳ Loading your library… 12.4 of 31 MB       ← checkpoint download
cached       grid at once from IndexedDB; the chip shows ⟳ until the pull settles
offline      grid from cache · chip "Offline" · thumbnails not cached show ⌛
empty        No photos yet.  Drop photos here or [[ Upload ]]
error        ⚠ Can't reach sol-photos: RequestTimeout    [ Retry ]   (grid stays)
```

## Search
```
║ ┌───────────────────────────────────┐                                    ║
║ │ 🔍 lisbon▌                        │                                    ║
║ ├───────────────────────────────────┤                                    ║
║ │ PLACES   Lisbon, Portugal    (142)│ ← suggestions as you type: places, ║
║ │ PEOPLE   Lisa Wong            (88)│   people, albums, then caption     ║
║ │ ALBUMS   Lisbon 2026          (61)│   matches; Enter = all matches     ║
║ │ CAPTIONS 7 photos mention "lisbon"│                                    ║
║ └───────────────────────────────────┘                                    ║
```
Results are the same day grid, titled `“lisbon” · 203 photos`.
Empty: `Nothing matches “lisbon”.`
Search runs on an in-memory index built once per load, never a pass over
IndexedDB per keystroke.

## Interactions
| Target | Action | Result |
|---|---|---|
| tile | click | → Viewer overlay (`viewer.md`) |
| tile corner | click / ⇧-click | select / range select |
| page | drop files | → upload tray (`upload.md`) |
| ⌫ / Delete | with a selection | bin + toast "3 photos moved to Bin ( Undo )" |
