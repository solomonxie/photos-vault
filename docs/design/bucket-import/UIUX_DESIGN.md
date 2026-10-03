# Bucket import: UI/UX

## Cloud Settings
Row under Your Cloud Bucket: **Import from Bucket**. Tap scans, imports, fetches thumbnails, then reports ("Imported N items", "Nothing new in the bucket", "Couldn't reach the bucket"). Spinner while running; disabled with no bucket. Shipped in `lib/settings/settings_screen.dart`.

## Utility menu: Flagged Items
Optimize Storage becomes **Flagged Items**, same place in the menu. Chips: All, Storage, Bucket. Badge on the entry counts both.

```
 ‹ Library              Flagged Items
 ( All 12 ) ( Storage 4 ) ( Bucket 8 )

 ┌─────────────────────────────────────────────┐
 │ ┌───┐  IMG_0012.mp4                         │
 │ │ ▶ │  Name doesn't follow the app's scheme │
 │ └───┘  12 MB · 3 Oct 2026                   │
 │                       [[ Rename ]]          │
 └─────────────────────────────────────────────┘
 ┌─────────────────────────────────────────────┐
 │ ┌───┐  scan-0043.png                        │
 │ │▣  │  Name doesn't follow the app's scheme │
 │ └───┘  41 MB · 3 Oct 2026                   │
 │              [ Rename ]  [[ Re-format ]]    │
 └─────────────────────────────────────────────┘
```

- One job per button. **Rename** has no warning beyond the first-use note ("Changes the file's name in your bucket"). **Re-format** confirms first: "Downloads 41 MB, uploads about 9 MB" plus the format choice.
- Re-format appears only on files known to be ordinary stills; never on videos or unverified files.
- Select mode applies one fix to many rows; the confirm sums the transfer.
- Result line after each fix ("Renamed", "Imported", or the failure reason); a failed fix leaves the row and the original object.
- Rows never reveal why a name matters to a hidden album, and suspected carriers look like any other row.

## Private album screen
**Find hidden photos in bucket** in the album menu, only while unlocked. Local check against `bucket_object`, "Found N" then adds them.

## Hiding a cloud-only photo
Today it is refused with the generic "hide failed" dialog. New: a confirm "Downloads 12 MB to hide this photo", then the normal hide flow.

## Copy rules
One calm sentence. "Carrier", "locator", "nonce", "tag" never appear.
