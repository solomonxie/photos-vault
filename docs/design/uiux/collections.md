# Albums, groups and the utility screens

Every screen here is the same day-grouped grid with a different title and a
different long-press action set — never a new tier to learn.

## Album  `lib/viewer/album_screen.dart`

```
 ‹              Nature                            ＋   → Add Photos
 Add a note about this album                          ← inline, editable
 Tags   ( hiking ⊗ ) ( 2026 ⊗ )                   ⊕
 ┌──────┬──────┬──────┐
 │      │      │      │
 └──────┴──────┴──────┘
 empty   No photos in this album.
 hold ▸  ♥ Favorite · ▤ Use as Album Cover · ▤− Remove from Album ·
         👁⃠ Hide · 🗑 Delete !
 delete album (from the library card's long-press)
 ⇒ Delete this album?  The photos and videos inside stay in your library.
```

## Favorites · group (place/event) · Recently Deleted

```
 ‹            Favorites                  hold ▸ ♡ Unfavorite · 🗑 Delete !
 empty  No favorites yet.

 ‹              Kyoto                    hold ▸ ♥ · 👁⃠ Hide · 🗑 Delete !
        ↑ the place or event name; 12 photos

 ‹        Recently Deleted               hold ▸ ↩ Recover
 empty  No recently deleted items.              🗑 Delete Permanently !
 ⇒ Delete Permanently?  This can't be undone.
```

## Hidden — passcode first  `lib/viewer/private_album_gate.dart`

The group of photos sharing a passcode hash **is** the album: there is
nothing to distinguish "enter" from "create", so the popup never asks.

```
 ┌──────────────────────────────────┐
 │  Private Album                ✕  │
 │  Enter a 4-digit passcode.       │
 │        ●  ●  ○  ○                │ ← four dots fill left to right
 │      ⓵   ⓶   ⓷                   │
 │      ⓸   ⓹   ⓺                   │   round keys, sized off the sheet
 │      ⓻   ⓼   ⓽                   │   width — a passcode is typed
 │           ⓪   ⌫                  │   without looking
 └──────────────────────────────────┘
 the 4th digit submits — no Enter, no Create, no Cancel button
```

```
 ‹   Private Album                              ⋯ / Cancel
 3 items · 42.1 MB
 ┌──────┬──────┬──────┐
 │      │      │      │
 └──────┴──────┴──────┘
 empty   Nothing here yet.
 ⋯ ▸ Add                              → picker over the whole library
     Select                           → selection mode
     Delete Private Album  !          ⇒ Delete this private album?
                                        Moved photos return to your library.
                                        Nothing is deleted.
 hold ▸ ♥ · 👁 Remove from Private Album · 🗑 Delete !
 selected ▸ [ Recover 2 to Library ]
 ⚠ One photo could not be put back into Photos. It is still here.
```

Hiding is two halves, always together: tag the record with the passcode hash
**and** take it out of the OS photo library. Tagging alone leaves the photo
sitting in Photos, which is the one outcome a hidden album must not produce.

## Smart collections  `lib/viewer/smart_collection_screen.dart`

AI-guessed groupings, opt-in, spends the user's own credit.

```
 ‹              People                    ← or Events
 [[ Analyze 42 Photos ]]      ⟳ Analyzing… 12 of 42
 ┌────────┐ ┌────────┐ ┌────────┐
 │ cover  │ │ cover  │ │  ⊞     │
 └────────┘ └────────┘ └────────┘
 2 People    1 Person    Tap to Analyze     ← the not-yet-analyzed card
 No People   Uncategorized
 empty  No photos to analyze yet.
```

## Photo picker  `lib/viewer/asset_picker_screen.dart`

```
 ‹          Add Photos                        Add 3
 ┌──────┬──────┬──────┐
 │  ✓   │      │  ✓   │     tap toggles; the title counts
 └──────┴──────┴──────┘
 empty  No photos available to add.
```

## Demo data  `lib/viewer/demo_data_screen.dart`

```
 ‹            Demo Data
 A handful of sample photos, albums and people bundled with the app, so
 there's something to explore before your own library is set up. They're
 ordinary items once added — backed up like anything else.
 [ Add Demo Data ]        ⟳ Working…
 Adds the sample photos, the Nature/City/Videos albums, a private album
 and a few people. Anything already there is left as it is.
 [ Delete All Demo Data ]!
 Removes every sample photo, album and person this app added. Your own
 photos and albums aren't touched.
 ⇒ Delete all demo data?  The sample photos, albums and people go.
   Anything you added yourself stays.
```
