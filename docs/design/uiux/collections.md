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
 [ Move from Library ]                    ← where the photos end
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
```

Hiding is two halves, always together: tag the record with the passcode hash
**and** take it out of the OS photo library. Tagging alone leaves the photo
sitting in Photos, which is the one outcome a hidden album must not produce.

The **Hidden row in Utilities carries no count** (`library.md`). A number
there answers "is there a hidden album, and how big is it" for anyone
holding the phone, before a digit of the passcode is typed — which is the
one question the gate exists not to answer.

### One confirmation, and it is the system's

Hiding used to put up two dialogs of our own — "Hide N photos?" before, and
"Still in Photos for 30 days" after — around the OS prompt in the middle,
which iOS raises *per `deleteWithIds` call*, so hiding twenty photos meant
twenty of them in a row.

Now: none of ours, and **one** system prompt for the whole group
(`LibraryCustody.takeOutMany` copies every original out first, then calls
`deleteManyFromLibrary` once). The photos were already selected; asking
again first is asking a question already answered, and two dialogs in a row
saying nearly the same thing is how people learn to tap through both. The OS
sheet lists exactly what is about to go, which is the confirmation that
actually carries information.

The 30-day Recently Deleted caveat still has to be said — it is the largest
hole in the design — but it belongs where it can be read rather than
dismissed: the album footer, and the first line of **How this works**.

### Backup is not a choice any more

Everything hidden is cloud-native: hiding a photo *is* sending it to the
bucket, encrypted, as a carrier (`docs/design/hidden-backup/DESIGN.md`).
A per-album "back up this album" switch contradicted that — turning it off
meant the app container held the only copy, unencrypted, forever. It and
`PrivateAlbumSync` are gone.

The one fork left is whether a bucket exists at all, which is not a
preference but a fact, so the footer states it rather than offering it:

```text
 ── scrolled to the bottom, under the grid ──────────────
 [ Move from Library ]                    ← where the photos end
 BACKUP
 These photos live in your bucket, encrypted.
 Hiding takes a photo out of Photos, and what leaves this
 phone is an ordinary-looking picture with yours encrypted
 inside it. Only your passphrase opens it.
 Nothing about it stays here — no file, no thumbnail, no
 record — so this album needs a connection to show anything.
 Photos keeps what it deletes for 30 days. Hiding isn't
 finished until you empty its Recently Deleted.

 HOW THIS WORKS
 • Every code opens an album. A code nobody has used opens…
 • Hiding takes the photo out of Photos. This app becomes…
 • What goes to your bucket looks like an ordinary photo…
 More                                     ← seven more bullets
```

**Three bullets, then More.** The full list is ten plain sentences about
decisions somebody wants to read once, before trusting this with anything —
no wrong passcode, the decoy, where the key comes from, what stays on the
phone, what an attacker who has read the source can still tell. All ten
unasked-for is a wall on the screen the photos are on; three is enough to
decide whether you want the rest.

**The album's own actions live behind `•••`** — add a passphrase, forget it
on this phone, delete the album. A row of them across the title bar read as
a toolbar of unrelated verbs, with `Delete Private Album` in red one tap
from `Add`. `Add` moved to the end of the grid, where you are when you want
another photo.

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

