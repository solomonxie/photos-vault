# Detail viewer

`lib/viewer/detail_screen.dart` — full-screen, swipe between items, dark
grey (not black). The info panel is **below** the photo, in the same
scroller.

```
 Done                                              Edit
 ┌─────────────────────────────────────────────────────┐
 │                                                     │
 │                  [ photo ]        pinch / double-tap│
 │                  LIVE  ← hold to play the .mov half │
 │                                                     │
 └─────────────────────────────────────────────────────┘
   ⬆     ♡        ⓘ        🗑
 share  favourite info    trash
   │                └── scrolls down exactly one viewport, landing on the
   │                    panel's top rather than anywhere within it
   ▼  drag the photo down ⇒ it comes with the finger, shrinking, and
    goes back to the grid when let go of — or springs back if not
 ─────────────────────────────────────────────────────────
 Sat · Sep 12, 2026 · 4:13 PM                    ← tap = Date & Time editor
 IMG_4934.HEIC
 ╭───────────────────────────────────────────╮
 │ Location                      No Location │  tap → place picker
 ├───────────────────────────────────────────┤
 │ Event                            No Event │
 ├───────────────────────────────────────────┤
 │ Dimensions                      4288×2848 │
 │ Duration                            0:12  │  video only
 │ File Size                          4.2 MB │
 │ Format                               HEIC │
 │ Backup status                     Pending │  Pending · Uploading… ·
 ╰───────────────────────────────────────────╯  Backed up · Failed
 ┌─ ✨ Suggested ────────────────────────────┐  ← only when the analyze
 │ Low sun over the harbour wall.           │    pass has an unanswered
 │ Event: Beach day                         │    suggestion for *this*
 │ ( beach ) ( sunset )                     │    photo
 │ [ Keep ]   ( No thanks )                 │
 └──────────────────────────────────────────┘
 Add a description                          ✨ AI Suggest
 Tags                                             ⊕
 ( sunset ⊗ ) ( kyoto ⊗ )
 People                                           ⊕
 ( ◯ Mei ⊗ ) ( ◯ Sam ⊗ )
 ⊡ Find Faces        Tap a face to say who it is.
 Albums                                           ⊕
 ( Nature ⊗ )
```

One drag, one meaning: the first direction decides. Sideways belongs to the
pager; downward from the top belongs to the photo, which then follows the
finger on both axes, shrinks as it goes, and is either let go of or springs
back. The chrome fades out quickly while the photo is being dragged — it
belongs to the screen, and the screen is on its way out — and the grid comes
up behind, so the photo is being dragged *towards* something.

## Cloud-only original

```
 [ Download Full Resolution ]      ← the local copy was freed
 ⟳ Downloading…
 ⚠ This file is no longer available.
```

## Edit — a menu, three destinations

```
 tap Edit ↓                  (video → "Only photos can be edited.")
 ┌─────────────────────────────┐
 │ Crop                        │ → photo_edit_screen.dart
 │ Rotate                      │ → same screen, dial mode
 │ AI Touch Up                 │ → prompt sheet, see ai.md
 │ ( Cancel )                  │
 └─────────────────────────────┘
 "This isn't in your Photos library, so it can't be edited there."
 ↑ when the asset is not a library item
```

All three land as a **new** library item; the photo being edited and whatever
is already backed up under its key stay as they are — `Saved as a new photo —
the original is untouched.` The viewer then swipes to the new photo, so the
edit is what is on screen.

## Crop / rotate screen  `lib/viewer/photo_edit_screen.dart`

```
 Cancel             Crop                     Save
 ┌─────────────────────────────────────────────┐
 │▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒│ outside the rect dims
 │▒▒┌───────────────────────────────┐▒▒▒▒▒▒▒▒▒▒│ drag a corner  = resize
 │▒▒│                               │▒▒▒▒▒▒▒▒▒▒│ drag inside   = move
 │▒▒└───────────────────────────────┘▒▒▒▒▒▒▒▒▒▒│
 └─────────────────────────────────────────────┘
                 ( Reset )

 Cancel            Rotate                    Save
        ╭───────── 360° dial ─────────╮
        │   spin with a finger        │
        ╰─────────────────────────────╯
                   −12°                ← tap the readout to snap to 0
 ⚠ Couldn't apply this edit.
```

## Share — a menu

```
 ⬆ ↓
 ┌─────────────────────────────┐
 │ Share Original              │ → [OS share sheet], any media type
 │ Export As…                  │ → stills only: re-encode first
 │ ( Cancel )                  │
 └─────────────────────────────┘
        Export As…
 ( JPEG )  ( PNG )  ( WebP )        ← runs off the UI isolate
 ⚠ Couldn't export this photo.
```

## Delete

Two shapes, because two different questions:

```
 backed up ⇒ action sheet          not backed up ⇒ alert
 ┌───────────────────────────────┐  ┌────────────────────────────┐
 │ Delete this item?             │  │ Delete this item?          │
 │ Removing from this device     │  │ It moves to Recently       │
 │ frees up space and keeps the  │  │ Deleted.                   │
 │ backed-up copy — the photo    │  │   ( Cancel )   [ Delete ]! │
 │ stays in your library, and    │  └────────────────────────────┘
 │ you can download the full     │
 │ resolution again any time.    │
 │ [ Remove from Device ]        │
 │ [ Delete Photo ]            ! │
 │ ( Cancel )                    │
 └───────────────────────────────┘
 ⚠ Couldn't remove this from the device.

 in Recently Deleted ⇒ Delete Permanently? · This can't be undone.
                       [ Delete Permanently ]!
```


## Suggestions are answered here, not in an inbox

The analyze pass (`queue.md`) can look at a photo long before anyone opens
it, so its answer has to wait somewhere. It waits on the photo: the card
sits directly above the caption field it offers to fill, under the picture
it's describing. A list of suggestion cards somewhere else would be asking
"is this right?" about a photo you can't see.

Nothing on the card is on the photo yet — that's the difference between a
suggestion and a tag. Keep merges tags and fills a caption or event only
where there isn't one; No thanks marks it answered so it is never offered,
or paid for, twice. Faces work the same way and always have: **Find Faces**
on the People section, one tap to put a name to one.
