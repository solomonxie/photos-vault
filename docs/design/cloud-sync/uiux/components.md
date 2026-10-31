# Components (extension)

## Tile
```
┌──────┐ ┌──────┐ ┌──────┐ ┌──────┐ ┌──────┐ ┌──────┐
│      │ │    ♥ │ │ ▶0:14│ │ LIVE │ │ ⌛   │ │ ✓    │
└──────┘ └──────┘ └──────┘ └──────┘ └──────┘ └──────┘
 plain    fav      video    live     no thumb selected
```
Square, `object-fit: cover`. The thumbnail comes from the Cache API, else a
presigned GET (cached on arrival), else ⌛. Hover shows the selection circle
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
