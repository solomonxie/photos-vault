# Upload

[ Upload ] → file picker; files dropped on the page go in too, with no
overlay. A tray docks bottom-right.

```
                                   ┌───────────────────────────────────────┐
                                   │ Uploading 4 of 13        ⏸   ⌄   ✕   │
                                   ├───────────────────────────────────────┤
                                   │ IMG_2201.JPG     [████████░░] 80%     │
                                   │ IMG_2202.HEIC    [██░░░░░░░░] 20%     │
                                   │ clip.mov           Waiting            │
                                   │ IMG_2190.JPG     ↻ Retry              │
                                   │   403 SignatureDoesNotMatch           │
                                   │ IMG_2189.JPG                 ✓        │
                                   └───────────────────────────────────────┘
```

- Two at a time. Large files go up multipart (8 MB parts), resumable after
  the tab closes: parts done are kept in IndexedDB with the file handle.
- Duplicates: the file's SHA-256 is matched against `content_hash`. A
  duplicate is skipped with "Already in your library" and a link to the photo.
- Taken date comes from EXIF `DateTimeOriginal`, else the file's modified
  time. GPS comes from EXIF.
- Order per file: original PUT → thumbnail PUT (JPEG/PNG/WebP/GIF via
  `createImageBitmap`; video poster via a `<video>` frame) → HEAD both →
  `asset.add` op → the tile appears.

## States
```
running   Uploading 4 of 13
paused    Paused · 9 left                          ▶
offline   Waiting for connection · 9 left
done      ✓ 13 uploaded              ( View )  ✕  ← auto-collapses after 5 s
partial   12 uploaded · 1 failed     ( Retry )
closed mid-upload, reopened   Resume 9 uploads?   [[ Resume ]] ( Discard )
                              ← a file handle the browser no longer grants → row says "Pick again"
```
