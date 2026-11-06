# Components (extension)

## Tile
```
┌──────┐ ┌──────┐ ┌──────┐ ┌──────┐ ┌──────┐ ┌──────┐
│      │ │    ♥ │ │ ▶0:14│ │ LIVE │ │ ▢    │ │ ✓    │
└──────┘ └──────┘ └──────┘ └──────┘ └──────┘ └──────┘
 plain    fav      video    live     no thumb selected
```
Square, 6px corners, `object-fit: cover`. The thumbnail is a presigned GET
(`no-store`, URL reused while valid; no media kept on the computer), fading
in over a solid placeholder; no thumbnail shows a faint photo icon. ☁ when
no phone holds it. Hover shows the selection circle
in the top-left.

## Day header
`Tue · Oct 28, 2026 · Lisbon`. The place is the most common one that day,
or omitted.

## Toast
```
⌐ 3 photos moved to Bin     ( Undo ) ¬     bottom-center, 6 s, one action
```

## Chip picker (People / Albums / Tags ＋)
```
┌──────────────────────────┐
│ 🔍 Find or create…▌      │
│ ＋ New album “Lisb”      │ ← create-and-add, first when no exact match
│ ✓ Lisbon 2026            │
│   Kids' drawings         │
└──────────────────────────┘
```

## Empty state
```
            No albums yet.
          [[ New album ]]
```
One line and one action, centered in the content area.
