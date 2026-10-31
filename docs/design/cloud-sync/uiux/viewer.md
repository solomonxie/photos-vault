# Viewer

An overlay over the grid that opened it. ← → step through that grid's order.

```
╔══════════════════════════════════════════════════════════════════════════╗
║ ✕                                          ♡   ⓘ   ⇩   🗑                ║ ← favorite, info,
║                                                                          ║   download original,
║  ‹                  ┌──────────────────────────┐                     ›   ║   bin
║                     │                          │                         ║
║                     │        [ photo ]         │                         ║ ← thumbnail at once,
║                     │                          │                         ║   medium/original
║                     └──────────────────────────┘                         ║   swapped in when
║                                                                          ║   loaded (presigned GET)
╚══════════════════════════════════════════════════════════════════════════╝
```

## Info panel (ⓘ or scroll down)
```
║  Sat · Sep 12, 2026 · 4:13 PM                                  ✎         ║ ← edits taken date
║  IMG_4934.HEIC · 4032×3024 · 3.1 MB                                      ║
║  ╭────────────────────────────────────────────╮                          ║
║  │ Add a description…                         │                          ║ ← saves on blur/⌘↵
║  ╰────────────────────────────────────────────╯                          ║
║  ╭────────────────────────────────────────────╮                          ║
║  │ People      Lisa Wong ✕   Tom ✕     ＋     │                          ║
║  ├────────────────────────────────────────────┤                          ║
║  │ Albums      Lisbon 2026 ✕           ＋     │                          ║
║  ├────────────────────────────────────────────┤                          ║
║  │ Tags        beach ✕  family ✕       ＋     │                          ║
║  ├────────────────────────────────────────────┤                          ║
║  │ Location    Lisbon, Portugal          ✎    │                          ║
║  ╰────────────────────────────────────────────╯                          ║
```

＋ opens a picker with "New album…" / "New person…" first (create and add in
one step), then a filtered list. A check toggles in place.

## Conflict card (when this photo has an open conflict)
```
║  ╭────────────────────────────────────────────╮                          ║
║  │ ⚠ Description edited in two places         │                          ║
║  │ Here (Chrome):   Beach, day 2              │                          ║
║  │ iPhone · 2 min ago:   Cascais beach        │                          ║
║  │            ( Keep this )  ( Use iPhone's )  │                          ║
║  ╰────────────────────────────────────────────╯                          ║
```
The winner is already showing. Dismissing keeps it; "Use iPhone's" writes
a new `set`. Nothing is dropped until someone picks.

## States
```
loading full res   thumbnail scaled up + thin ⟳ in the corner
original missing   ⚠ The original isn't in the bucket (404). Thumbnail shown.
video              <video> on a presigned URL; seeking streams, nothing buffered whole
HEIC original      Chrome can't show HEIC: medium/ JPEG if present, else thumbnail
                   + "⇩ Download original"
binned             banner: In Bin · ( Restore )
```

## Interactions
| Target | Action | Result |
|---|---|---|
| ← → | key | previous / next in the opening grid |
| Esc / ✕ | — | back to the grid, same scroll position |
| ♡ | click / `F` | favorite toggle, op queued |
| 🗑 | click / ⌫ | bin, close, toast with Undo |
| ⇩ | click | presigned GET with `response-content-disposition=attachment` |
