# vault

Hidden photos, as objects in a bucket that look like ordinary photos.

```text
keys.dart        passphrase ─PBKDF2─▶ masterKey ─HKDF+4 digits─▶ albumKey
   │                                  (keychain)                 (RAM only)
   ▼
cipher.dart      AES-256-CTR + PBKDF2 via dart:ffi → CommonCrypto (system,
                 so nothing ships); HMAC-SHA256 from `crypto`; HKDF here
   ▼
carrier.dart     header · encrypted thumbnail · encrypted original.
                 v2 header adds a nonce and 8-byte locator, and the photo's
                 date/size/kind inside the encrypted thumbnail section
   ├── jpeg_segments.dart   payload in APP7 segments, before the image data
   └── mp4_boxes.dart       payload in a `free` box, after `moov`
   ▲
decoy.dart       which photo the carrier pretends to be: closest in *size*,
                 never closest in time, its thumbnail upscaled
still_video.dart the video decoy — one frame held for a real duration,
                 rendered by AVFoundation (ios/Runner/StillVideoChannel.swift)

album_index.dart app-data/index.bin — every install writes one, same size
                 always, 32 padded sections, yours found by a keyed tag
object_key.dart  what every object is called: `<date>_<32 hex>`. Ordinary =
                 hash of the id; hidden = nonce + HMAC locator, so the album
                 whose key made it recognises it by name. Relative, so one
                 index reads against every bucket
carrier_probe.dart  is this object a carrier? a JPEG's first 64 KB, or an
                 MP4's top-level boxes by tiny ranged reads. Never a download
hidden_bucket_scan.dart  adds carriers of this album found in the bucket
hidden_migration.dart    gives old carrier names protocol names, album open
store.dart       <AppSupport>/vault — the carriers themselves, durable and
                 out of the device backup. **The local copy.**
cache.dart       Library/Caches, encrypted, TTL + LRU per pool — for what
                 came *down* from a bucket, and free to be thrown away
```

## An ordinary photo, plus an encrypted backup

A hidden photo is an ordinary record with a passcode hash: its plain file
stays on this phone, and it shows, opens, zooms and shares through the same
grid and viewer as any other photo. Nothing about it changes when it is
backed up.

Backup is automatic (`hidden_backup.dart` → `SyncEngine.backUpHidden`): a
carrier is built from the plain file and sent to every bucket; the record's
status flips and its underline turns green. It runs for every album whose
key is on hand — started on opening an album, after hiding, at launch and
on return to the app, and it carries on after the album closes. Album keys
sit in the keychain (`vault_ring_v1`) so a relaunch resumes without the
code; no new exposure, since the master key beside them already opens any
album in 10,000 guesses. The gate never reads them.
The queue, the Cloud page and the overnight run never touch hidden photos,
so none of them can reveal that any exist.

```text
hide ─▶ plain file + row (the photo) ── HiddenBackup ─▶ CarrierBuilder ─▶ bucket
```

Older builds *filed* hidden photos — deleted the plain file and the row and
kept only the carrier (`store.dart`). `filed_photos.dart` turns those back
into ordinary ones when the album opens: from this phone's carrier, or from
the bucket's the first time the tile is tapped.

Design and the reasoning behind each choice:
[`docs/design/hidden-backup/DESIGN.md`](../../docs/design/hidden-backup/DESIGN.md).

Rules worth not rediscovering:

- **The row and the plain file stay on this phone.** Chosen Oct 2026 so a
  hidden photo is no different to use than any other. The cost: its row
  (date, name) is in sqlite, and so in the app-data snapshot in the bucket.
  The photo itself only ever leaves the phone encrypted. Album notes
  (`hidden_notes.dart`) are rows, sealed with the album key and tagged by a
  keyed hash, not the passcode hash.
- **Deleting a hidden photo is permanent** (`hidden_removal.dart`): index
  first, then this phone's files, then the bucket via `PendingDeletes`.
  Never the library's Recently Deleted, which opens without a code.
- **A rewrite merges into the index as it stands, local or remote.** Falling
  back to "no index" while offline builds a fresh one — 32 sections of random
  bytes — and every other album on the phone is gone. `VaultBucket.currentIndex`
  is the one place that decides which index a rewrite is based on.
- **Carriers filed with no bucket by older builds** are marked unsent
  (`VaultStore.setUnsent`), their key sealed under the outbox key, and the
  sync still sends them with no album open.
- **The index records motion** (`IndexEntry.hasMotion`), so a still un-hides
  offline. Entries filed before that ask the buckets.
- **Un-hiding a filed photo** (`hidden_restore.dart`): Photos takes it back
  first, then `HiddenRemoval.release` unlists it. The bucket's carriers
  wait in `DeferredDeletes` until the plain copy is in every bucket.
- **A wrong 4-digit code is never an error.** It derives a different album
  key, which matches no index section and no carrier MAC, so the album is
  simply empty. There is no code path that could report "wrong passcode".
