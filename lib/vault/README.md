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
cache.dart       Library/Caches, encrypted, TTL + LRU per pool
```

Design and the reasoning behind each choice:
[`docs/design/hidden-backup/DESIGN.md`](../../docs/design/hidden-backup/DESIGN.md).

Two rules worth not rediscovering:

- **Nothing about the private side goes in sqlite.** The database is in the
  daily app-data snapshot, which is in the bucket next to the carriers.
- **A wrong 4-digit code is never an error.** It derives a different album
  key, which matches no index section and no carrier MAC, so the album is
  simply empty. There is no code path that could report "wrong passcode".
