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


# Moving pictures: Live Photos and GIFs

Both are a still that moves, and both answer to one control rather than
two — the question "how should these behave?" is the same question, and
answering it twice means learning it twice.

```
 ┌─────────────────────────────────────────────┐
 │ ⦿ LIVE                        [✋][↻][⏸]    │  ← badge · mode bar
 │                                             │
 │              the picture                    │
 │                                             │
 └─────────────────────────────────────────────┘
      ✋  hold to play      (Photos' own behaviour, the default)
      ↻   play on a loop    (runs while it's on screen)
      ⏸   don't play        (frozen on the first frame)
```

Icons, not a menu: the whole set fits in the space one menu button would
take, and the current answer is visible without opening anything — which
matters for a control whose effect is only obvious while you watch the
picture behind it.

The badge lights up while it's actually moving, so it doubles as the
answer to "is this playing?".

The mode is a preference about *you*, not about any one picture: it's kept
in app state, shared by every page in the pager, and survives a relaunch.
Swiping from one Live Photo to the next must not change how they play.

## GIFs

Flutter's `Image` plays a GIF and gives you no way to stop it, so the two
states are two different widgets (`gif_view.dart`): a decoded first frame
while it's still, the real `Image` while it's running. Swapping between
them is the pause button GIFs don't otherwise have — and releasing a hold
drops the cached frames, so the next play starts at frame one rather than
mid-loop.

A GIF is **not** `isVideo`: that flag answers "does this need the video
player?", and a GIF handed to `video_player` is a black rectangle. It is
`isGif`, and `countsAsVideo` is what the Videos album and the grid badge
read — it moves, so that's where somebody goes looking for it. Crop,
rotate and Export As are off for the same reason they're off for video:
all three re-encode, and re-encoding a GIF throws the animation away.

The flag is set once, from the filename — `.gif`. On iOS that's the only
thing that says so: PhotoKit calls the asset an image and `mimeType` is
null, so the camera-roll scan asks for `needTitle`.


## What a Live Photo *is*, and what gets backed up

Not a format. On iOS a Live Photo is one `PHAsset` with **two resources**:
a still (HEIC or JPEG) and a paired QuickTime `.mov` of roughly three
seconds — which is where the motion *and the audio* live. They're tied
together by a shared identifier in metadata: `kCGImagePropertyMakerApple`
key 17 on the still, `com.apple.quicktime.content.identifier` on the movie,
plus a still-image-time marker naming the key frame.

So there is no single file to convert, and **"optimize the format" does
not apply**. Re-encoding the still to WebP throws away the Apple maker
note; re-encoding the movie through an image encoder is nonsense and
through a video encoder drops the content identifier. Either one leaves
two files that no longer know they're one photo — a still, and a short
silent clip beside it. `BackupFormat.optimized` therefore skips the
`livePhoto` derivative outright, and the storage page's Convert/Reduce
fixes never touch one.

Both halves go up under the **same `originals/` prefix**, sharing a base
name and differing only by extension:

```
 originals/photo_ABC123.HEIC   the still
 originals/photo_ABC123.mov    the motion and the sound
```

One folder, because they are one photo; a bucket listing shows them as the
pair they are.

`AssetRecord.isFullyBackedUp` is what everything asks before dropping a
local copy — Remove from Device, the storage page, the "gone from the
library" reconcile. For a Live Photo it means *both*: a still-only backup
is a silent still, and offering to free the space on the strength of it
would be the exact loss the option claims not to be. Restoring pulls both
down, and the viewer plays the restored `.mov` when the photo library no
longer has the asset.
