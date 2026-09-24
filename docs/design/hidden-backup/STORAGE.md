# One pile of shards on the phone, carriers in the bucket

Supersedes the "a hidden photo leaves the phone entirely" premise in
[DESIGN.md](DESIGN.md). The carrier is not wrong — it is the *bucket's*
format, and the app made it the only one.

## What's wrong today

- The private album only works with a bucket configured. Without one the
  footer admits it ("No bucket yet, so these stay on this phone") and the
  photos sit as ordinary files, unencrypted. The people most likely to want
  a private album are the least likely to have an S3 account.
- `VaultCache` writes one encrypted file per object, so the ciphertext's
  length is the plaintext's length. A directory listing reads 38 KB /
  2.4 MB / 1.9 GB — thumbnail / photo / video, per entry, without
  decrypting anything.
- Hidden files and ordinary cached files live in different places under
  different schemes, so *where a file is* already says what kind it is.

## Three stores, and only one of them holds pictures locally

| store | holds | format |
|---|---|---|
| **the phone** | every local byte of every picture — hidden photos, and the ordinary thumbnail/photo/video caches | shards |
| **the bucket** (S3/COS/OSS) | backups of everything, hidden ones as carriers | unchanged: `originals/`, `thumbnails/`, and carriers |
| **iCloud Drive** | app metadata only — albums, people, tags, captions. **No pictures, hidden or otherwise** | unchanged: `app-data/YYYYMMDD.zip` |

iCloud stays what it is today. It is document-scope-public and shows up in
Files, and a folder of pictures there is a folder of pictures no matter what
is inside them.

## The shard store

One tree. Everything local goes in it, and that is the point: a hidden
photo's shards are in the same tree, the same size, and the same shape as
the shards of the thumbnail on your grid.

```
Application Support/shards/ab/12/de/ab12de9f4c…bin
                           └─┴──┴── first three byte-pairs of the name
```

- **Name**: `HMAC(key, objectId ‖ index)`, 32 hex. Only the key that wrote a
  shard can name it, so nothing can be enumerated or grouped by reading the
  tree.
- **Fanned three deep**, from the name's own first six characters. No single
  directory lists more than a handful of shards, and the handful it lists
  has nothing to do with each other — one shard of a hidden video, one of
  somebody's grid thumbnail, one of a cached original, in one folder, in no
  order that means anything.
- **Every shard is the same size on disk.** The last one of an object is
  padded with random bytes; the true length lives in the object header
  inside shard 0.
- **Shard body**: `IV (16) ‖ ciphertext ‖ HMAC-SHA256 (32)`, AES-256-CTR,
  encrypt-then-MAC, through the existing `lib/vault/cipher.dart`. No new
  primitives and no new packages — see CLAUDE.md's size budget.
- **Excluded from the device backup** (`NSURLIsExcludedFromBackupKey`), so
  none of it rides into the owner's own iCloud backup. Thumbnails stop
  being backed up as a side effect; they are regenerable, and this is the
  better trade.

### Two keys, one tree

| written with | for | available |
|---|---|---|
| a device key in the Keychain | ordinary thumbnails, cached photos and videos | always |
| the album key (passphrase ‖ the four digits) | hidden photos and their thumbnails | only while the album is open |

Same format, same sizes, same tree. What an attacker holding the unlocked
phone can do is decrypt everything the device key opens and note that some
shards are left over. That is a **count**, and it is the same concession the
[threat model](DESIGN.md#threat-model-the-format-is-public) already makes
for carriers in the bucket: the format is public, counting is not defended,
opening is. Against everything short of that — a file browser, a borrowed
phone, a backup extractor, someone who knows the app — the tree says
nothing.

### Sizes

Two shard sizes, because one cannot serve a 38 KB thumbnail and a 2 GB
video:

| | shard | a 40 KB thumbnail | a 2 MB photo | a 500 MB video |
|---|---|---|---|---|
| `small` | 64 KiB | 1 shard | 32 | — |
| `large` | 1 MiB | — | 2 | 500 |

Which size an object uses follows its length, so one bit leaks —
"small thing" or "big thing". Everything finer is gone: 38 KB vs 61 KB, a
photo vs a Live Photo vs a short clip.

### Why fixed size at all

1. **Length survives encryption.** It is in every directory listing, and a
   photo's size next to its neighbours' sizes is a fingerprint of a camera
   roll.
2. **Eviction gets a unit.** TTL and LRU currently work on whole objects of
   wildly different cost. Shards make "drop 200 MB" exact.
3. **Partial reads get a unit.** Shard 0 carries the thumbnail, so a grid
   tile never reads shard 1 — the same property the carrier's first 64 KB
   buys in the bucket.

### Eviction never takes the last copy

The cache half is evictable because it can be fetched again. A hidden
photo's shards are evictable **only** if a bucket holds its carrier. With no
bucket, the phone holds the only copy, and the store refuses to reclaim it —
which needs saying in the copy, and probably a one-time confirmation on the
first hide.

## The decoy stays bucket-only

A decoy answers one question — *does this object look like a photo to
someone reading a list of objects?* — and only a bucket is read that way. On
the phone it defends nothing and costs a full-resolution upscale per hidden
photo. `decoy.dart`, `jpeg_segments.dart`, `mp4_boxes.dart` and
`still_video.dart` stay, reached only by the bucket writer.

## Code

| file | |
|---|---|
| `lib/vault/shards.dart` | **new** — the format: name, path, write, read, read shard 0, delete, measure |
| `lib/vault/shard_store.dart` | **new** — the tree, its two keys, TTL/LRU, and the "never the last copy" rule |
| `lib/vault/cache.dart` | rewritten over the shard store, keeps its pools and caps |
| `lib/photos/thumbnail_cache.dart` | moves into the same tree under the device key |
| `lib/vault/gallery.dart` | reads the phone first, the bucket second |
| `lib/vault/bucket.dart`, `carrier_upload.dart`, `decoy.dart` | unchanged |

## Migration

Nothing here is losable: the caches are caches, and carriers already in a
bucket are still read by the bucket reader. Existing plain thumbnails and
the old `VaultCache` files are deleted on first run and regenerate. A phone
whose hidden photos are *only* in the bucket re-fetches them on demand, as
it does today.

## Open

- **Three levels of fanout** is the shape asked for. It is also up to
  16.7M possible directories; they are created lazily, so a 200k-shard
  library makes ~150k directories holding one or two shards each. Cheap in
  bytes, not free in inodes. Worth measuring on a real library before it
  ships, with two levels as the fallback.
- **The leftover-shard count** above. Worth deciding whether the store
  keeps a floor of unused shards so the count is never zero — or whether
  that is exactly the kind of cleverness the threat model says not to
  claim.
