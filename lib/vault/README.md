# vault

Hidden photos, as objects in a bucket that look like ordinary photos.

```text
keys.dart        passphrase ─PBKDF2─▶ masterKey ─HKDF+4 digits─▶ albumKey
   │                                  (keychain)                 (RAM only)
   ▼
cipher.dart      AES-256-CTR + PBKDF2 via dart:ffi → CommonCrypto (system,
                 so nothing ships); HMAC-SHA256 from `crypto`; HKDF here
   ▼
carrier.dart     header · encrypted thumbnail · encrypted original
   ├── jpeg_segments.dart   payload in APP7 segments, before the image data
   └── mp4_boxes.dart       payload in a `free` box, after `moov`
   ▲
decoy.dart       which photo the carrier pretends to be: closest in *size*,
                 never closest in time, its thumbnail upscaled
still_video.dart the video decoy — one frame held for a real duration,
                 rendered by AVFoundation (ios/Runner/StillVideoChannel.swift)

album_index.dart app-data/index.bin — every install writes one, same size
                 always, 32 padded sections, yours found by a keyed tag
object_key.dart  what a carrier is called, everywhere — relative, so one
                 index reads against every bucket and a photo has a name
                 before any bucket exists
store.dart       <AppSupport>/vault — the carriers themselves, durable and
                 out of the device backup. **The local copy.**
cache.dart       Library/Caches, encrypted, TTL + LRU per pool — for what
                 came *down* from a bucket, and free to be thrown away
```

## This phone first, the bucket second

A hidden photo's carrier is kept in `store.dart`, so an album opens, scrolls
and plays with **no network and no bucket configured at all**. The bucket is
the copy that survives losing the phone, and the only source for a photo the
user has deliberately sent back to it.

The carrier is stored exactly as uploaded — already encrypted under the album
key, already a real openable JPEG or MP4 of somebody else's picture. One
artifact, two homes: the local file *is* the upload body, and the two copies
can be compared byte for byte.

```text
hide ─▶ CarrierBuilder ─▶ VaultStore (the copy) ─▶ bucket (the backup)
                              │                       │
   tile:  seek first 64 KB ◀──┘        ranged GET ◀────┘  (only if not here)
   photo: read the file    ◀──┘        whole GET  ◀────┘
```

Per-photo, the user chooses: **Free Up Space** drops the local carrier and
keeps an encrypted thumbnail in its place (the tile still draws offline);
**Download** fetches it back. Freeing is refused for a photo the bucket cannot
be shown to hold — until something else has it, this app's copy is the only
one.

Where it lives, and why nowhere else: Application Support is durable and in
the device backup, Caches is out of the backup and purgeable, and this needs
both properties — so it takes the durable directory and turns the backup off
(`ios/Runner/BackupExclusionChannel.swift`).

Design and the reasoning behind each choice:
[`docs/design/hidden-backup/DESIGN.md`](../../docs/design/hidden-backup/DESIGN.md).

Rules worth not rediscovering:

- **Nothing about the private side goes in sqlite in the clear.** The
  database is in the daily app-data snapshot, which is in the bucket next to
  the carriers. A hidden photo's row is deleted the moment its carrier is
  filed; the album index is the only thing that describes it after that.
  Album notes (`hidden_notes.dart`) are rows, but sealed with the album key
  and tagged by a keyed hash, not the passcode hash.
- **Deleting a hidden photo is permanent** (`hidden_removal.dart`): index
  first, then this phone's files, then the bucket via `PendingDeletes`.
  Never the library's Recently Deleted, which opens without a code.
- **A rewrite merges into the index as it stands, local or remote.** Falling
  back to "no index" while offline builds a fresh one — 32 sections of random
  bytes — and every other album on the phone is gone. `VaultBucket.currentIndex`
  is the one place that decides which index a rewrite is based on.
- **No bucket still means encrypted.** Hidden photos are carried and filed
  without one (`hidden_filing.dart`); the carrier is marked unsent
  (`VaultStore.setUnsent`), its object key sealed under the outbox key —
  derived from the master key alone, so the sync sends it with no album
  open. Markers from older builds wait for their album to open.
- **The index records motion** (`IndexEntry.hasMotion`), so a still un-hides
  offline. Entries filed before that ask the buckets.
- **Un-hiding a filed photo** (`hidden_restore.dart`): Photos takes it back
  first, then `HiddenRemoval.release` unlists it. The bucket's carriers
  wait in `DeferredDeletes` until the plain copy is in every bucket.
- **A wrong 4-digit code is never an error.** It derives a different album
  key, which matches no index section and no carrier MAC, so the album is
  simply empty. There is no code path that could report "wrong passcode".
