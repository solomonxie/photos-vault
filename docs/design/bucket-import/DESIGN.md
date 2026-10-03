# Bucket import and hidden-name protocol

## Problem
- Big batches arrive in the bucket from other sources (`scripts/import-to-bucket.sh`) and must appear in the app.
- Hidden carriers in the bucket but unknown to this phone (restore, lost index) must be recoverable.
- A listing must not tell a hidden carrier from an ordinary file.

## Decisions

### 1. Object naming
`originals/<YYYYMMDDHHMMSS>_<16 hex>.<ext>`, thumbnail beside it as `.jpg`.
- Sorts by date; no iOS `_L0_001` suffix; same on Android.
- Ordinary: hex is random.
- Hidden: date is the **decoy's** (never the real taken date); hex is `nonce(8) | locator(8)`, both copied from the carrier's own header.
- Old names (`photo_<UUID>_L0_001.*`) stay valid while a record or index entry points at them. Only new uploads use the scheme.
- Keys are read from the stored record / index entry, never recomputed from the record id.
- Live Photo halves share a base name, differ by extension.
- Filing writes a new carrier under a new name (S3 cannot rename; filing creates the object anyway). Un-hiding deletes the carrier.

### 2. Carrier v2
- Header gains `nonce` (8 B); `locator = HMAC(macKey, nonce)[0:8]`. `macKey` comes from passphrase (PBKDF2) plus the 4-digit PIN.
- The name tag **is** the in-file locator, by construction. An unlocked album recognises its names by recomputing the HMAC from the nonce in the name: local, no network.
- Real taken date, width, height, video flag go inside the encrypted thumbnail section; one ranged GET of the first 64 KB returns them.
- v1 carriers stay readable and deletable; v1 has no date, so adopt uses the decoy date.
- Format only changes how new carriers are written; v1 paths are untouched.

### 3. Recognising a carrier without downloading it
- JPEG: payload in APP7 segments within the first 64 KB; one ranged GET.
- MP4: payload is a top-level `free` box. Walk the top-level boxes with 8-byte ranged GETs (3 to 5 requests), then read the 69-byte header at the `free` box start.
- Parsing must require a known version byte and lengths that fit the file size, so an ordinary photo with stray APP7/`free` data stays ordinary.
- Foreign carriers: the header carries the passphrase salt; the index header lists the salts of every passphrase this install has seen (plain, not secret). Salt not on the list means another install or a lost generation, so it is treated as an ordinary photo.

### 4. One listing, kept in the db
- The normal cloud sync lists `originals/` and `thumbnails/` into a `bucket_object` table (`key, size, lastModified, claimedByRecord`), incrementally, off the UI isolate, skipped when nothing changed.
- No hidden flag anywhere in the table. It holds names the bucket already shows to anyone who can list it.
- Hidden albums scan this table locally when unlocked: recompute the locator from each name's nonce. A match costs one ranged GET for the v2 header, then goes into the album index. No bucket traffic on unlock.

### 5. Library behaviour
- Names that fit the protocol are neither shown nor imported: they may be hidden carriers and only an album can say.
- Names that do not fit are **flagged**, never silently skipped.

### 6. Flagged items and fixes
Each fix does one job. Fixes are separate actions.

| Fix | Does | Transfer |
|---|---|---|
| **Rename** | Server-side copy to a protocol name, HEAD-verify, delete old | none (reads first bytes only) |
| **Re-format** | Download, convert (existing backup format), upload under a protocol name, verify, delete old | download + upload, warned with sizes |
| **Remove orphan / Regenerate thumbnail** | Delete or rebuild | none / small |

Rename decides the name by what the first bytes say:
- Not a carrier: ordinary protocol name, imported as a cloud-only record.
- v2 carrier with a salt on our list: hidden-format name built from the header's own nonce and locator. **No passcode needed.** The album claims it by name.
- Carrier with an unknown salt, or a header failing checks: ordinary photo (visible).

Re-format is offered only after a positive check that the file is **not** a carrier, since re-encoding destroys a payload. Videos are never transcoded. Unverified files get Rename only.

### 7. Parking a foreign carrier
Filing it as an ordinary photo keeps its foreign payload intact inside our carrier (`CarrierBuilder.build` encrypts the file bytes verbatim). Hiding a cloud-only photo is **refused today** (`private_album_gate.dart`), so this needs a new path: download, build carrier, verify, then retract the plain copy, keeping the cloud copy if any step fails.

### 8. Not needed
- A name-to-path mapping table does not help discovery (unknown files are by definition absent). It remains useful for multiple destinations; separate task.
- Metadata or tags on objects: HEAD per object, and cannot be added to existing objects without a rewrite.
- A per-album constant in the name: repetition groups the album.
- Plaintext real date in a hidden name: leaks when the photo was taken.

## Risks
- Format change touches real hidden photos and the delete path. v1 stays; v2 sits beside it.
- 64-bit locator: chance match is negligible; the carrier MAC settles it before anything is added.
- Un-hiding a parked foreign carrier into Photos may strip the payload; export to Files instead (untested).
- Mixed naming in one bucket until old objects are renamed.
