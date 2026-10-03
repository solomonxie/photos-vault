# Bucket import and hidden-name protocol

## Problem
- Big batches arrive in the bucket from other sources (`scripts/import-to-bucket.sh`) and must appear in the app.
- Hidden photos already in the bucket but unknown to this phone (restore, second phone, lost index) must be recoverable.
- Nothing in a listing may tell a hidden carrier from an ordinary file.

## Decisions

### 1. Object naming
`originals/<YYYYMMDDHHMMSS>_<16 hex>.<ext>`, thumbnails beside it as `.jpg`.
- Sorts by date; no iOS-specific `_L0_001` suffix; same on Android.
- Ordinary: hex is random.
- Hidden: date is the **decoy's**, hex is `nonce(4B) | tag(4B)`, `tag = HMAC(nameKey, date|nonce)[0:4]`.
  A fresh nonce per file, so no two names share anything.
- `nameKey = HKDF(albumKey, "pv-name-v1")`. `albumKey` already mixes passphrase (PBKDF2) and the 4-digit PIN, so only an unlocked album can recognise its names.
- Live Photo halves share base name, differ by extension.
- Old names (`photo_<UUID>_L0_001.*`) stay valid when a record or index entry points at them. Only new uploads use the new scheme.
- Keys are read from the stored record / index entry, never recomputed from the record id.
- Filing a photo into a hidden album writes a new carrier under a new name (no S3 rename exists; filing already creates the object). Un-hiding deletes the carrier; the plain photo keeps its own name.

### 2. Carrier v2
The real taken date, width, height and video flag go **inside** the encrypted thumbnail section, so one ranged GET of the first 64 KB gives everything needed to adopt a carrier. v1 carriers stay readable; v1 has no date, so adopt falls back to the decoy date in the name.

### 3. One listing, kept in the db
- The normal cloud sync lists `originals/` and `thumbnails/` once (incremental after the first pass) and stores `key, size, lastModified, claimedByRecord` in a `bucket_object` table.
- The table never records "hidden". It holds names the bucket already shows to anyone who can list it.
- Listing runs off the UI isolate and is skipped when nothing changed.
- A hidden album scan is then local: for each unclaimed name, recompute the tag with `nameKey`. A match costs one ranged GET (carrier v2 header) and is added to the album index. No bucket traffic on unlock.

### 4. Plain import
- Unknown objects in `bucket_object` with a non-hidden-looking name are imported as cloud-only records (date from name, else `lastModified`), thumbnails fetched by the existing library restore.
- Names that fit the protocol shape (`date_16hex`) are **not** shown or imported: they may be hidden carriers and only an album can say. They are never listed in Flagged.

### 5. Flagged items
Objects whose names do not fit the protocol are not skipped; each becomes a flagged item with a suggested fix.

| Found | Suggested fix |
|---|---|
| Plain media, name off-protocol | **Rename and import**: server-side copy to a protocol name, delete the old, add the record |
| Looks like a carrier (JPEG APP7 payload in the first 64 KB), name off-protocol | **Restore to hidden album**: unlock; test the in-file locator against the album key; on a match copy to a tag name, add to the index; no match: stays flagged "Unknown hidden item" |
| Legacy `photo_*` name, no record pointing at it | **Import**, or restore to a hidden album if it is a carrier |
| Thumbnail with no original, or original with no thumbnail | **Remove orphan**, or **Regenerate thumbnail** |

- A suspected carrier is shown with a placeholder, never its decoy pixels.
- MP4 carriers carry the payload at the end of the file, so they cannot be sniffed from the prefix. They are detected only during Restore to hidden album, when the user unlocks and agrees to download.
- Every fix is a copy then delete, and verified (HEAD) before the old key is removed. Failure leaves the original in place.

## Rejected
- Metadata or tags on the object: needs a HEAD per object, and cannot be added to existing objects without a rewrite.
- A constant per-album string in the name: repetition groups the album.
- Plaintext real date in a hidden name: leaks when the photo was taken; decoys are picked by size, not time, for the same reason.
- Skipping unknown `photo_*` objects silently: hides lost data from the user.

## Risks
- Touches the format of real hidden photos and the code that deletes carriers. v1 read and delete paths stay untouched; v2 sits beside them.
- 32-bit tag: about 1 in 4 billion chance match per unknown name. The carrier's own locator check settles it before anything is added.
- Mixed naming in one bucket until old objects are renamed.
