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

Only what can actually come back is listed here. A photo deleted before it
was ever backed up has nothing behind it — no cloud copy, no thumbnail, no
file — so it is dropped on the spot instead of sitting in the bin as an
empty tile. (iOS keeps its own copy in Photos' Recently Deleted for 30
days; restoring it there brings the photo back as a new one, without the
tags and people this app had on it.)

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

 ── scrolled to the bottom, under the grid ──────────────
 BACKUP
 This album is backed up with the rest of your library.
 Hiding a photo takes it out of Photos, so this app holds
 the only copy of it on this device.
 Backed up, it goes to your buckets like every other photo:
 same folders, and its filename is replaced by an id, so
 nothing up there marks it as hidden. The photo itself is
 not encrypted — anyone who can read your bucket can open it.
 A lost, broken or wiped phone does not take these photos
 with it.
 Keep this album on this device only          ← text link
```

Hiding is two halves, always together: tag the record with the passcode hash
**and** take it out of the OS photo library. Tagging alone leaves the photo
sitting in Photos, which is the one outcome a hidden album must not produce.

The **Hidden row in Utilities carries no count** (`library.md`). A number
there answers "is there a hidden album, and how big is it" for anyone
holding the phone, before a digit of the passcode is typed — which is the
one question the gate exists not to answer.

### Backup is per album, on unless turned off

The footer is on the screen the photos are on, not in Settings, because
that is where somebody decides whether these particular photos leave the
phone. Per album — an "album" is a passcode hash and nothing else, so one
group can stay local while another is backed up
(`lib/storage/private_album_sync.dart`).

**On by default.** Hiding took the photo out of Photos, so with backup off
the app container is the only copy in the world; defaulting to off would
make the hidden album the least safe place in the library. Off is a
deliberate choice with the cost written directly above the link that makes
it. Neither direction is confirmed with a dialog: nothing is destroyed
either way, and the copy has already said what happens.

Turning it off stops the *next* upload. Whatever already reached the bucket
stays there — the app only ever deletes from a bucket when Recently Deleted
is emptied (`lib/upload/README.md`), and the footer copy says so.

The switch is enforced in `LibraryScreen._backUpRecords`, not at each call
site: a photo reaches that method from a scan, an import, a retry, a
change-check re-upload and the queue refill, and "this album never leaves
the device" has to hold on all five.

The preference is device-local (an `app_state` row, not in the app-data
snapshot), so a restored install backs the album up again until someone
turns it off a second time. That is the deliberate direction to fail in:
the other one silently stops backing up photos the phone holds the only
copy of.

**The copy describes what the app does today, including "not encrypted".**
If at-rest encryption for hidden photos ships, `privateAlbumBackupExplainer`
is the string to rewrite — it is the only place that makes a claim about
what the bucket copy is.

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

