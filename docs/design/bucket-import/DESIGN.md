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
- Hidden: hex is `nonce(8 B) | locator(8 B)`, both in the carrier's own header. The date is **keyed and arbitrary** (2012 to 2026, from `HMAC(nameKey, seed)`), never the real taken date. It is not the decoy's date: the decoy is picked at build time and cannot be recomputed when the name is needed again, and the name must be derivable from the record and the album keys alone.
- The hex is 32 characters for both kinds (`ordinary: first 16 bytes of SHA-256(localId)`).
- Old names (`photo_<UUID>_L0_001.*`) are migrated in the app (section 9). Until migrated they are known because a record or index entry points at them; code has no legacy branch.
- An already-uploaded derivative keeps its stem (`previousKey`), so an edit overwrites rather than orphans. A hidden carrier's key is recomputed from the record and the album keys (`hiddenBaseName`), and stored in the index entry once filed.
- Live Photo halves share a base name, differ by extension.
- Filing writes a new carrier under a new name (S3 cannot rename; filing creates the object anyway). Un-hiding deletes the carrier.

### 2. Carrier v2
- Header (81 B) gains `nonce` (8 B); `locator = HMAC(macKey, nonce)[0:8]`. `macKey` comes from passphrase (PBKDF2) plus the 4-digit PIN. `nonce = HMAC(nameKey, "nonce|seed")[0:8]`, `nameKey = HKDF(albumKey, "pv-name-v1")`.
- A carrier built without metadata stays v1 (69 B, 4-byte locator).
- The name tag **is** the in-file locator, by construction. An unlocked album recognises its names by recomputing the HMAC from the nonce in the name: local, no network.
- Real taken date, width, height, video flag go inside the encrypted thumbnail section; one ranged GET of the first 64 KB returns them.
- v1 carriers stay readable and deletable; v1 has no date, so adopt uses the decoy date.
- Format only changes how new carriers are written; v1 paths are untouched.

### 3. Recognising a carrier without downloading it
- JPEG: payload in APP7 segments within the first 64 KB; one ranged GET.
- MP4: payload is a top-level `free` box after a `PVC1` tag. Walk the top-level boxes with 16-byte ranged GETs (3 to 5 requests), then read the header and up to 64 KB of payload at the `free` box start. No trailer is needed.
- Parsing must require a known version byte and lengths that fit the file size, so an ordinary photo with stray APP7/`free` data stays ordinary.
- Foreign carriers: the header carries the passphrase salt; the index header lists the salts of every passphrase this install has seen (plain, not secret). Salt not on the list means another install or a lost generation, so it is treated as an ordinary photo.

### 4. One listing, kept in the db
- The normal cloud sync lists `originals/` and `thumbnails/` into a `bucket_object` table (`key, size, lastModified, claimedByRecord`), incrementally, off the UI isolate, skipped when nothing changed.
- No hidden flag anywhere in the table. It holds names the bucket already shows to anyone who can list it.
- Hidden albums scan this table locally: recompute the locator from each name's nonce. A match costs one ranged GET for the v2 metadata, then goes into the album index (`HiddenBucketScan`). The listing runs on app pause, at most every 12 hours and never over an empty library (a fresh install has not restored its records), and again from the album menu and the Flagged Items page.

### 5. Library behaviour
- Names that fit the protocol are neither shown nor imported: they may be hidden carriers and only an album can say.
- Names that do not fit are **flagged**, never silently skipped.

### 6. Flagged items and fixes
Each fix does one job. Fixes are separate actions.

| Fix | Does | Transfer |
|---|---|---|
| **Rename** | Server-side copy to a protocol name, HEAD-verify, delete old | none (reads first bytes only) |
| **Re-format** | Download, convert (existing backup format), upload under a protocol name, verify, delete old | download + upload, warned with sizes |
| **Remove** (orphan thumbnail) | Delete | none |

Rename decides the name by what the first bytes say:
- Not a carrier: ordinary protocol name, imported as a cloud-only record.
- v2 carrier with a salt on our list: hidden-format name built from the header's own nonce and locator. **No passcode needed.** The album claims it by name.
- v1 carrier with a salt on our list: left flagged with "open its album to restore this one" (a v1 header cannot be put in a name).
- Carrier with an unknown salt, or a header failing checks: ordinary photo (visible).

Re-format is offered only after a positive check that the file is **not** a carrier, since re-encoding destroys a payload. Videos are never transcoded. Unverified files get Rename only.

### 7. Parking a foreign carrier
Filing it as an ordinary photo keeps its foreign payload intact inside our carrier (`CarrierBuilder.build` encrypts the file bytes verbatim). Hiding a cloud-only photo is **refused today** (`private_album_gate.dart`), so this needs a new path: download, build carrier, verify, then retract the plain copy, keeping the cloud copy if any step fails.

### 9. One-time in-app name migration
Every object is renamed by the same steps, ordinary or hidden: copy to the new name, update the reference (record `destinationKey` or index entry), HEAD-verify, delete the old.
- Ordinary photos: runs in the background after sync, in small batches, resumable (the reference changes only after the copy verifies).
- Hidden carriers: per album, only while unlocked; the new name is built from the carrier's header.
- Not done on the Mac: references live in the phone db and the encrypted index.
- Classification stays uniform: an object is known if something points at it, else protocol-shaped (album may claim), else flagged. Migration just makes every name protocol-shaped.
- Flagging waits until the app-data snapshot is restored, or a fresh install sees every object as unreferenced.

### 10. Gaps left
- Regenerating a missing thumbnail is not built; only orphan removal.
- Protocol-shaped unknown ordinary files (record lost, no album claims) are invisible, by design.
- Large objects: one `CopyObject` handles up to 5 GB; larger ones fail and stay as they are.

### 8. Not needed
- A name-to-path mapping table does not help discovery (unknown files are by definition absent). It remains useful for multiple destinations; separate task.
- Metadata or tags on objects: HEAD per object, and cannot be added to existing objects without a rewrite.
- A per-album constant in the name: repetition groups the album.
- Plaintext real date in a hidden name: leaks when the photo was taken.

## Leftovers

An unclaimed original is a **likely leftover**, not a new photo, when:
- no capture date in its own header (EXIF DateTimeOriginal/DateTime in JPEG,
  WebP `EXIF`, a HEIC Exif item inside the first 64 KB; MP4/MOV `mvhd`), and
- its name stamp is within 72 h of its LastModified, i.e. written at upload
  or rename time, not by a camera.

- Read from the same 64 KB the carrier probe already fetches; videos walk
  top-level boxes to `moov`.
- Listed on Flagged Items (Ignore · Import anyway); never counted in the
  Cloud row's offer, never imported by the batch.
- Import date: header date › name stamp › LastModified.
- Ignored keys live in `app_state` (`bucket_ignored_keys`); detection skips
  them for good. The bucket keeps the files.
- `LeftoverSweep` ran once on upgrade: untouched `bucket:` records matching
  the rule (reference = earlier of LastModified and import time, since the
  import's copy moved LastModified) left the library and their keys were
  ignored. Favourites, tags, captions, places, albums, people, locks kept.

## Risks
- Format change touches real hidden photos and the delete path. v1 stays; v2 sits beside it.
- 64-bit locator: chance match is negligible; the carrier MAC settles it before anything is added.
- Un-hiding a parked foreign carrier into Photos may strip the payload; export to Files instead (untested).
- Mixed naming in one bucket until old objects are renamed.
