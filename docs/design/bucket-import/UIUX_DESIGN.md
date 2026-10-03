# Bucket import: UI/UX

## Cloud Settings
New row under Your Cloud Bucket: **Import from Bucket**.
- Tap: scan, import, fetch thumbnails, then a result dialog ("Imported N items", "Nothing new in the bucket", "Couldn't reach the bucket").
- Spinner in the row while running; disabled with no bucket.
- Shipped: `lib/settings/settings_screen.dart`.

## Utility menu: Flagged items
Optimize Storage becomes **Flagged items** (entry in the same place). Two sections:
1. Storage: the existing "free up space" list, unchanged.
2. Bucket: objects needing attention.

```
 ‹ Library              Flagged Items
 ( All 12 ) ( Storage 4 ) ( Bucket 8 )

 ┌─────────────────────────────────────────────┐
 │ ┌───┐  IMG_0012.mp4                         │
 │ │ ▶ │  Name doesn't follow the app's scheme │
 │ └───┘  12 MB · 3 Oct 2026                   │
 │              [[ Rename and import ]]        │
 └─────────────────────────────────────────────┘
 ┌─────────────────────────────────────────────┐
 │ ┌───┐  Possible hidden item                 │
 │ │ ? │  Looks like a private photo           │
 │ └───┘  Unlock an album to restore it        │
 │           [[ Restore to hidden album ]]     │
 └─────────────────────────────────────────────┘
```

- Each row: thumbnail (placeholder for suspected carriers), why it is flagged, one primary fix.
- Select mode bulk-applies one fix to many rows, like the storage page.
- Restore to hidden album asks for the passphrase and PIN first; a code that opens no matching album says "No match" and changes nothing.
- Result line after each fix: "Renamed", "Added to <album>", or the failure reason; a failed fix leaves the row.
- The badge count on the menu entry covers both sections.

## Private album screen
**Find hidden photos in bucket**, in the album's menu, only while unlocked. Local check against `bucket_object`; shows "Found N" before adopting, then adds them to this album.

## Copy rules
Calm, one sentence, no jargon ("carrier", "tag", "nonce" never appear).
