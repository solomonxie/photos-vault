# Albums, People, Places, Bin

Each index is a card grid; opening one shows the same day grid as Library.

## Albums
```
║ Albums                                              [ New album ]        ║
║ ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐                      ║
║ │  cover   │ │  cover   │ │  cover   │ │  cover   │                      ║
║ └──────────┘ └──────────┘ └──────────┘ └──────────┘                      ║
║ Lisbon 2026  Kids' draw…  Recipes     Receipts                           ║ ← names truncate
║ 61           212          34          1,208                              ║   at one line
```
Album page header:
```
║ ‹ Albums   Lisbon 2026  ✎                  ⋯                             ║
║            61 photos · Oct 24 – Oct 30, 2026                             ║
║            Add a description…                                            ║
     ⋯ ┌──────────────────────┐
       │ Add photos…          │  ← picker over Library, toggles in place
       │ Rename               │
       ├──────────────────────┤
       │ Delete album       ! │  ← photos stay; the album is a tombstone (undo toast)
       └──────────────────────┘
```

## People
```
║ People                                                                   ║
║  ( ◯ )     ( ◯ )     ( ◯ )     ( ◯ )        ← avatar from avatar_local_id ║
║  Lisa Wong  Tom      Mum       Unnamed                                    ║
║  88         412      1,031     ← only people named on the phone or here   ║
```
Person page: name ✎, bio card, then the grid. Face detection stays on the
phone; the browser only adds and removes people on photos.

## Places
```
║ Places                                                                   ║
║ Portugal                                                     (203)  ›    ║
║   Lisbon                                                     (142)  ›    ║
║   Cascais                                                     (61)  ›    ║
║ Japan                                                        (1,402) ›   ║
```
A list, the same tree the phone builds. There's no map in v1.

## Bin
```
║ Bin                                                                      ║
║ Photos here can be restored. Deleting them for good is done on your      ║
║ phone, which checks every copy first.                                    ║
║ Binned Oct 29, 2026                                                      ║
║ ┌──────┬──────┐                                                          ║
║ │      │      │       select → ( Restore )                               ║
```

## States
```
empty albums   No albums yet.  [[ New album ]]
empty people   No people yet. People you name on your phone appear here.
empty bin      Bin is empty.
```
