# Hidden photos live in the bucket, disguised as ordinary photos

A photo in a hidden album leaves the phone entirely. What lands in the
bucket is **a JPEG that opens as a photo** — an unrelated picture from the
user's own library, at its own resolution and its own date — carrying the
real photo's bytes inside it, encrypted. Nothing about the hidden photo
stays on the device: no file, no thumbnail, no database row.

Today's behaviour, which the footer copy states plainly: same folders,
filename replaced by an id, **not encrypted**. The id hides *which* photo it
is and nothing else.

## What this covers

Everything about the private album, in one place: what a carrier is and how
one is built, how the decoy is chosen, where the keys come from, what is
kept on the phone and for how long, and what happens on a new phone.

| | |
|---|---|
| [Threat model](#threat-model-the-format-is-public) | what this defends against, and what it concedes |
| [The shape of it](#the-shape-of-it) | phone and bucket, at a glance |
| [The carrier](#the-carrier) | JPEG segments, the payload layout, why not the alternatives |
| [The decoy](#the-decoy-closest-in-size-never-closest-in-time) | which photo it pretends to be, and why size and not time |
| [What it costs](#what-it-costs-measured) | measured overhead, and where it goes |
| [Videos](#videos-an-mp4-carrier-whose-decoy-is-one-frame-held) | MP4 boxes, and one frame held for a real duration |
| [Nothing stays on this phone](#nothing-stays-on-this-phone) | records, thumbnails, the cache, TTL and LRU |
| [The index](#the-index) | `app-data/index.bin`, sections, padding |
| [The key](#the-key) | passphrase → master key → album key, and where each lives |
| [Leaving the app](#leaving-the-app-leaves-the-album) | backgrounding, the switcher snapshot |
| [Confirmations](#one-confirmation-and-it-is-the-systems) | one prompt, the system's |
| [Flows](#flows) | setup, adding, removing, hide/unhide, six walkthroughs |
| [Cipher](#cipher) | AES-CTR, PBKDF2, HMAC, the carrier header |
| [Size budget](#size-budget-no-new-packages-at-all) | why no packaged encoder |
| [Open decisions](#open-decisions) · [What this does not protect](#what-this-does-not-protect) | |

Code: [`lib/vault/`](../../../lib/vault/README.md),
`lib/upload/pending_deletes.dart`,
`ios/Runner/StillVideoChannel.swift`. Plan and what is still unproven:
[`IMPLEMENT_PLAN.md`](IMPLEMENT_PLAN.md).

## What's wrong today

1. `originals/<id>.heic` is the hidden photo, readable by anyone who can
   read the bucket.
2. `_backUpRecords` also enqueues `uploadThumbnail`, so `thumbnails/<id>.jpg`
   is the same photo at 320 px, in the folder built for cheap browsing.
3. Hiding a photo that was **already backed up** leaves both objects up
   there. Nothing removes them.
4. `thumbnail_cache` keeps a plain JPEG of every photo, hidden ones
   included, in the app's cache directory — a browsable contact sheet for
   anything that can read the container.
5. The record row carries `passcodeHash` *and* the photo's date, filename,
   description, location, event and people — plaintext, in sqlite, in the
   daily snapshot, in the bucket. `sha256(4 digits)` is 10,000 guesses to
   reverse.

## Threat model: the format is public

This repo is public. Anyone can read how a carrier is built and write a
detector for it — a large unknown `APP7` segment on a soft photo is not
subtle once you know to look. **The design does not pretend otherwise.**

| against | defended by | holds? |
|---|---|---|
| someone **browsing** the bucket — a console, a family member on a shared account, a provider's content scan | the decoy: every object is a photo that opens as a photo | yes |
| someone **counting** carriers, who has read this repo | nothing — they run the detector and get a count | **no, accepted** |
| someone **opening** a hidden photo, holding the bucket, the snapshot and this repo | the passphrase, which is in none of them | yes |
| someone **imaging the phone** | nothing is there to find | yes, after the upload lands |

The fully-undetectable version — splitting every photo across many objects
so none is anomalous — is not worth it: it doesn't reach undetectable
(object count and total bytes still don't match a library that size), and it
trades per-photo restore for a scheme where losing one object loses many
photos.

## The shape of it

```text
                      the phone                                the bucket
  ┌──────────────────────────────────┐        ┌──────────────────────────────┐
  │ passphrase ─PBKDF2─▶ masterKey   │        │ originals/<id>.jpg  carrier  │
  │                     (Keychain)   │        │ originals/<id>.jpg  carrier  │
  │       │ HKDF + the 4 digits      │        │ app-data/20260921.zip        │
  │       ▼                          │        │ app-data/index.bin  always   │
  │   albumKey (RAM only)            │        └──────────────────────────────┘
  │       │                          │                      ▲
  │       ├─ names your section of ──┼──────────────────────┘
  │       │  index.bin → object keys │
  │       └─ opens each carrier      │
  │                                  │
  │  no hidden files, no thumbnails, │
  │  no rows                         │
  └──────────────────────────────────┘
```

## The carrier

A JPEG is a stream of marker segments, and decoders skip `APPn` segments
they don't recognise — that is what they are for. Payloads go in `APP7`
(`FFE7`, unassigned in practice) chains **before the image data**, never
appended past `EOI`.

```text
FFD8  SOI
FFE1  APP1   the decoy's EXIF — the decoy's date, not the hidden photo's
FFE7  APP7   header + encrypted thumbnail     ← ~25 KB, inside the first 64 KB
FFE7  APP7   encrypted original               ← the rest, ≤ 65 533 B a segment
FFDB…FFDA    the decoy's image data
FFD9  EOI
```

Opens in Photos, Preview, Chrome, a bucket console's preview — everywhere,
as the decoy. `tail`, `strings`, a trailing-bytes check: nothing past `EOI`.
Exiftool shows "unknown APP7" — the shape of a proprietary maker note, whose
contents are ciphertext and therefore indistinguishable from random.

**Thumbnail first, so the grid is cheap.** A ranged GET of the first 64 KB
returns the encrypted thumbnail without pulling the original — or even the
decoy's pixels, which sit at the end. S3, COS and OSS all honour `Range`.

### Why not the alternatives

| | why not |
|---|---|
| **append past EOI** | `tail -c` finds it; some pipelines truncate to `EOI` |
| **LSB in pixels** | 8 bytes of carrier per byte hidden — a 4 MB photo needs ~32 MB of pixels — and only survives a *lossless* container, so one 40 MB PNG in a bucket of JPEGs. Louder than what it hides. |
| **EXIF UserComment** | a field viewers *display*, and 64 KB total |

### The decoy: closest in size, never closest in time

A **non-hidden record whose own file size is closest to the payload's**,
tie-broken at random among the nearest few. Its cached thumbnail, upscaled
to that record's own resolution, q≈50, carrying that record's own EXIF
date.

**Size, so the object weighs what it claims to.** The carrier is the decoy's
resolution plus the payload's bytes; pick a decoy that really weighs about
that much and the result is exactly what a second copy of that photo would
weigh. Resolution, date and size all agree with each other.

**Never nearest in time.** A time-adjacent decoy wears a timestamp within
hours of the hidden photo's, so every carrier would announce **when** the
photo it hides was taken. Size says nothing about time — that is the whole
reason it is the right axis to match on.

What the bucket looks like: a library with some photos in it twice, at their
own dates and their own weights. People re-save their own photos constantly.

- **Never a hidden record** — the pool is the ordinary library.
- **No decoy used more than twice.** Fifty carriers wearing one face is a
  pattern; two copies of a picture is Tuesday.
- **Prefer an already-cached thumbnail**, which is nearly all of them: a
  carrier then costs an upscale and an encode, never a full-size decode.
- **Nothing records which decoy was used.** Restore does not need it, and a
  `carrier → decoy` column would be a list of exactly which objects are
  carriers, in the database, riding to the bucket in the snapshot.
- **No decoy is ever a real photo on the phone.** It exists inside the
  carrier object and nowhere else; the library gains no duplicate.

### What it costs, measured

Measured, not predicted — an earlier draft of this doc guessed 0.2–0.4 MB
for the decoy and was wrong:

```text
decoy pixels   4032×3024, upscaled from a 320 px thumbnail, q=50   ~450 KB
thumbnail      encrypted, the hidden photo's own 320 px             ~25 KB
original       encrypted (HEIC stays HEIC, never re-encoded)        ~2 MB
object                                                              ~2.5 MB
```

**~20 % over the original**, against the ~10 % first claimed. It replaces
*two* objects (the `originals/` and `thumbnails/` pair an ordinary photo
produces), so the bucket sees more like 15 %.

Where that 450 KB goes is worth knowing, because it bounds what any tuning
can win: a 12 MP JPEG is ~190 000 blocks, and even a handful of bytes each
is most of the file. **It is a floor of the pixel count, not of the
detail.** Measurements on a real image:

| | size |
|---|---|
| q=40 | 434 KB |
| q=50 | 454 KB |
| q=60 | 477 KB |
| q=50, blurred first (radius 8) | 430 KB |

Dropping quality or smoothing the upscale moves it by single-digit
percents. The only real lever is resolution, and the size-matched decoy
already handles that: a decoy picked to weigh what the payload weighs is
usually a photo of about the right resolution too, so small payloads get
small decoys and the ratio stays roughly constant.

The other cost is that the decoy is **visibly soft** at full size. Someone
browsing sees an ordinary photo; someone scripting resolution-against-size
can flag the soft ones. Beating that costs a real full-res decoy at ~2 MB a
photo — not the default, a switch if ever wanted.

Never re-encode the payload upward: HEIC is already the compact one. With
`BackupFormat.optimized` the payload is the WebP, ~half again.

## Videos: an MP4 carrier whose decoy is one frame, held

MP4 is a box stream, and `free` / `skip` boxes exist to be ignored. The
payload goes in one, **after `moov`**, so no `stco`/`co64` offset has to be
rewritten — appending a `free` box is structurally ordinary, unlike trailing
bytes on a JPEG.

```text
ftyp
mdat        the decoy's frames
moov        the decoy's tracks
free        header + encrypted poster + encrypted original
```

### The duration is what makes it plausible

A two-second clip weighing 200 MB is absurd, and that was the hole. Fix it
by giving the decoy a **real duration**: one keyframe, repeated for as long
as the decoy's source runs.

```text
decoy = first frame of a non-hidden video, held for that video's own
        duration, at its resolution and frame rate

200 MB ÷ 3 min ≈ 9 Mbps  — an ordinary 1080p capture
200 MB ÷ 2 s    ≈ 800 Mbps — nothing on earth
```

Which non-hidden video: **the one whose file size is closest to the
payload's** — the same rule as photos. Its duration and resolution then
already imply a bitrate that fits the bytes, and none of the hidden video's
own metadata is exposed.

### It is nearly free to make

Identical frames encode to almost nothing. A static 1080p30 three-minute
HEVC is one I-frame plus a few hundred bytes a frame — ~2 MB, about 1 % of
what it carries — and the hardware encoder produces it in seconds, versus
minutes of CPU and heat for a full-length re-encode of somebody's real
video.

Set a long keyframe interval, or the periodic I-frames cost more than the
whole rest of the file.

### What it still gives away

Playing it shows a frozen frame. A browser, a console, a poster thumbnail:
an ordinary video. Anyone who actually watches two seconds of it knows. That
is the same trade the soft JPEG decoy makes — plausible at a glance, odd
under inspection — and it is a far smaller tell than bytes-against-duration,
which was checkable by script across an entire bucket without watching
anything.

No similar-sized video in the library to copy: synthesize a duration from
the payload size at an ordinary bitrate rather than picking a wrong one.

A hidden Live Photo's `.mov` half takes this path too, so its motion
survives — which the still-only version would have lost.

## Nothing stays on this phone

No original in the container, no thumbnail in the cache directory, **no
database row**. A phone that is imaged, dumped or browsed yields nothing
about a private album, and the app does not grow by a gigabyte because
someone hid a lot.

Deleting the row matters as much as deleting the file: it holds the photo's
date, filename, description, location, event and people, and the *count of
rows* is itself the answer to the question the gate exists not to answer.

### The local cache is a cache, and lives where caches live

Not "nothing on disk" — **nothing *lasting*, nothing browsable, nothing
backed up**. A hidden photo's bytes may sit on the phone the way any app's
cache does: evictable, expiring, opaque.

`Library/Caches/` (`getApplicationCacheDirectory`), and the distinction is
not cosmetic:

| | browsable in Files | in the iCloud/Finder device backup | purged by iOS |
|---|---|---|---|
| `Documents/` | yes, if the app opts in | yes | no |
| `Library/Application Support/` — **where thumbnails go today** | no | **yes** | no |
| `Library/Caches/` | no | **no** | yes, under pressure |

Today's `thumbnail_cache` writes to Application Support, so a hidden photo's
thumbnail rides into the user's own iCloud device backup. That is a leak in
its own right and the move is part of this work.

Rules for the cache:

- **Encrypted at rest** with the album key — as opaque on the phone as in
  the bucket. A purge that leaves recoverable blocks, a jailbreak dump, a
  forensic image: all get ciphertext.
- **Opaque names.** `HMAC(albumKey, objectKey)`, never a filename, never an
  id. (Hidden records have no row to hang a `thumbnailPath` on anyway.)
- **Two pools, separate budgets**, because the cost of a miss is not the
  same:

```text
thumbnails      ~25 KB each   cap ~100 MB    TTL 7 days     cheap to refetch
photos, Live    ~2 MB each    cap ~500 MB    TTL 24 hours   one ranged GET
videos          big           cap ~2 GB      TTL 30 days    expensive; keep
```

  A re-fetched thumbnail costs 64 KB; a re-fetched video costs minutes and
  someone's data plan. Videos earn the long tail, photos do not.
- **LRU within each pool**, TTL across both, and the whole cache is dropped
  when the passphrase is forgotten on this phone.
- RAM stays the first tier above it: decoded thumbnails in a bounded LRU
  while the album is open.

### What is still local, and for how long

Three exceptions. Two are ours and temporary; one is the operating
system's and is the largest hole in the design.

1. **Between hiding and the upload landing**, the file and a minimal record
   exist — the phone holds the only copy. Both are deleted the moment the
   carrier is confirmed on ≥1 target.
2. **The sync queue names its jobs.** `displayName` is the filename today; a
   hidden job carries an opaque label instead.
3. **iOS Photos keeps what it deleted for 30 days.** Hiding removes the
   asset from the OS library, which puts it in Photos' own *Recently
   Deleted* — visible, restorable, and not ours to purge. **For 30 days the
   phone still has it**, unless the user empties that album. The OS keeps
   its own thumbnail caches on its own schedule too.

(3) belongs in the copy, at the moment of hiding, with a button that opens
Photos there. Hiding is not complete until that album is emptied.

### With no bucket configured

There is nowhere to put them, so hidden photos stay local and unencrypted,
exactly as today, and the album says so. The private side is local-only
until a bucket exists, then it moves out entirely.

## The index

One object, `app-data/index.bin`, beside the daily snapshot the app already
writes.

**It does not hide — it is unremarkable.** An encrypted blob that appears
only when someone has a private album is the loudest object in the bucket.
One that **every install writes, always, whether anything is hidden or
not**, says nothing.

```text
plaintext header   version · KDF salt · verifier · hint
┌─ section ──────┐  tag = HMAC(albumKey, "section")     ← find yours
│ entries:       │  object key · date · dimensions · name · IV
└────────────────┘
┌─ section ──────┐  another album, or padding. No way to tell which.
└────────────────┘  × 8, all the same size
```

- **A wrong code matches no section** — which is exactly what an unused
  album looks like. Empty album, no error, nothing to report.
- **The size never moves.** Fixed sections, fixed count, rewritten on a
  schedule whether or not anything changed, so it cannot be watched for
  "they hid something today".
- **Salt, verifier and hint live in its plaintext header**, not in the
  database. They have to be readable before any key exists, they have to
  survive to a new phone, and a hint sitting in a sqlite row would itself
  announce that a passphrase was set. Local-only installs keep them in the
  Keychain instead.
- **Two phones at once**: read-modify-write with `If-Match` on the ETag
  where the vendor supports it; union on conflict.
- **Losing it costs a rebuild, not the photos** — scan objects' first 64 KB
  and test the locator. Slow; the fallback, not the path.

## The key

```text
passphrase (user-chosen, any length ≥ minimum)
   │  PBKDF2-HMAC-SHA256, 600 000 iters, 16 B salt   ← expensive, once
   ▼
masterKey ....................................... Keychain, one unnamed item
   │  HKDF, with the 4 digits typed at the gate     ← free, per unlock
   ▼
albumKey ........................................ RAM only, in AlbumKeyRing
   │
   ├─ HMAC(albumKey, "section")  → which slice of index.bin is yours
   └─ encKey + macKey            → every carrier in that album
```

**One key per album, one random 16 B IV per file.** Per-file *keys* bought
nothing an attacker could not also compute; what matters is that no two
files share a counter, which the IV gives for free. Each carrier stores its
own IV and the `masterSalt`, 32 bytes that make it openable **without the
index** — passphrase plus code is enough, so the index stays a convenience
rather than a single point of total loss.

Stretching runs **once**, not per photo: a passphrase strong enough to need
600k iterations cannot be run 100 times during a batch upload.

### The gate's deniability becomes arithmetic

Wrong 4 digits derive a different `albumKey`, which names a section that
isn't there and MACs that never match. There is no code path that *could*
report "wrong passcode" — the app genuinely cannot tell an unused code from
a mistyped one. The README's promise stops being a UI convention.

### Where the keys live — never the database

| | verdict |
|---|---|
| passphrase, anywhere | **never stored.** Only the derived key is, and nothing needs the plaintext back. |
| `masterKey` in the Keychain | **yes, default.** Credentials already live there and are excluded from the snapshot. `ThisDeviceOnly`, not iCloud-synced. |
| salt · verifier · hint | `index.bin`'s plaintext header (Keychain while there is no bucket) |
| anything in sqlite | **no.** It is in the snapshot, which is in the bucket, next to the carriers. |

**A Keychain item survives a reinstall on iOS** — the repo already relies on
this (`bucket_backup.dart`). So deleting and reinstalling the app on the
same phone does *not* ask for the passphrase, and does not lock anyone out.
Only a different phone does. Worth an explicit *Forget the passphrase on
this phone* action for anyone who wants the opposite.

**Memory-only is a switch, not the default.** It changes nothing for an
attacker with the bucket (who never had the Keychain) and only helps against
forensic extraction of an unlocked phone. It costs real function: every cold
start stops hidden uploads until the passphrase is typed, and the queue runs
in the background precisely when nobody is looking at the app.

### The passphrase, and what the hint costs

Typed when chosen, and again only on a **new phone**. In between the
Keychain has it.

A user-chosen passphrase is the documented downgrade from a random 256-bit
code: a code cannot be guessed by anyone, a passphrase sometimes can. It
buys memorability and a hint. Enforced minimum length, and the setup screen
says the trade without softening it.

**The hint is readable by anyone who can read the backup.** It has to be —
it must reach a phone that has just been restored and knows nothing, so it
lives in `index.bin`'s plaintext header. There is nowhere else to put it.
Same for the verifier that lets a restored phone tell right from wrong: it
permits offline guessing, exactly as the carriers' own MACs already do.

### More than one passphrase can exist

The awkward order happens: new phone, set a passphrase, hide a few photos,
*then* connect the bucket holding carriers under an older one.

Not a conflict, as long as the app holds a **set** of master keys:
entries merge on restore and are never dropped, the active one covers new
uploads, and opening a carrier tries each key it holds (two HKDFs and a
MAC per key — microseconds, since the expensive step already happened).
An entry nobody can open breaks nothing: those carriers show as locked with
their hint until someone types that passphrase, or deletes them
deliberately.

## Leaving the app leaves the album

Switch apps, lock the phone, or hand it over with the album open, and coming
back lands on the library. The code is cheap to type again; an open private
album in a handed-over phone is not recoverable.

Two moments, because iOS has two:

- **inactive** — a control-centre swipe, a banner, an incoming call, *and*
  the system's own prompts, including the delete confirmation hiding puts
  up. Too ordinary to throw the screen away for, but it is the moment
  before the app-switcher snapshot is taken, so the album is covered with
  an opaque layer. Coming straight back uncovers it.
- **paused** — actually backgrounded. Now everything above the library is
  popped, the opened photo included.

Covering rather than popping on `inactive` is what keeps hiding working: the
OS delete prompt makes the app inactive, and an album that popped itself
there would take the half-finished hide with it. Opaque rather than blurred,
because a blur of a photo is still a photo.

`lib/vault/private_lifecycle.dart`, mixed into the album and the photo
screen.

## One confirmation, and it is the system's

Hiding asks **once**, and it is iOS asking. `LibraryCustody.takeOutMany`
copies every original out and verifies it, then calls
`deleteManyFromLibrary` once for the group — iOS raises its sheet per call,
so a loop of twenty photos was twenty sheets.

Nothing of ours wraps it. The photos were already selected, so a "hide
these?" dialog first asks a question already answered, and two dialogs in a
row saying nearly the same thing teach people to tap through both. The OS
sheet lists exactly what is about to go, which is the confirmation carrying
real information.

Capped at 100 per call, deliberately: past a hundred thumbnails that sheet
stops being checkable, and a confirmation nobody can check is not one.
Anything over the cap comes back as "still in Photos" rather than going
silently.

## Flows

### Setup is one prompt, and it never says no

```text
  Private photos

  Passphrase  ┌───────────────────────┐
              └───────────────────────┘
  Hint        ┌───────────────────────┐   optional; travels in your backup
              └───────────────────────┘
              [[ Continue ]]  → straight into the album
```

No "new or existing" fork. Whatever is typed becomes the active passphrase;
if it happens to be one used before, that generation's carriers start
opening. **No wrong answer and no verdict** — a screen that can say "wrong"
is a screen that confirms there is something to be wrong about.

No network needed. Set a passphrase, hide photos, browse them; a phone that
never connects a bucket never uses the passphrase for anything.

### Old passphrases are added inside the album

The unlocked album is the only place that can safely offer it, because
getting there already took a code:

```text
  ‹  Hidden                                   •••
  ┌───────┐ ┌───────┐ ┌───────┐
  │ photo │ │ photo │ │  🔒   │   ← in the bucket, not openable yet
  └───────┘ └───────┘ └───────┘
  PASSPHRASES
  │ In use · hint: the usual one             │
  │ Added  · hint: old phone                 │
  │ + Add a passphrase                       │
```

Adding one can only *unlock* things. Locked items become photos or stay
locked — the result is the feedback, so nothing has to pass judgement.
Deleting a generation's carriers is an ordinary, deliberate action next to
that list.

### Adding and removing photos

```text
add     → select in the picker
        → one OS delete prompt for the group (LibraryCustody.takeOutMany)
        → each record tagged with the passcode hash
        → the plain objects each already had are queued for deletion
        → carrier uploaded; record and local file deleted once it lands

remove  → "Recover to Library": the copy is handed back to Photos, which
          creates a *new* asset with a new id, so the record keeps its own
          localId and its tags, people and albums survive the round trip
        → the carrier is deleted and its index entry removed
```

### Hide / unhide is a bucket operation

```text
hide    → remove from Photos (already today) → prompt about Recently Deleted
        → delete originals/<id>.* and thumbnails/<id>.jpg from every target
        → upload the carrier, add the entry to index.bin
        → delete the local file and the record

unhide  → download the carrier, decrypt
        → write the photo back into Photos
        → delete the carrier, remove the entry from index.bin
        → the record comes back as an ordinary one, backed up normally
```

- **A pending delete never expires.** Hiding happens offline constantly, so
  the task sits in a pending-deletes table and retries on every reconnect.
  It ends two ways: the object is gone, or the photo itself is deleted.
- **404 is success** — the right bucket, no such key, somebody removed it by
  hand. Done, not failed.
- **Nothing else is.** `403`, expired credentials, 5xx, DNS, no network —
  all retry. Reading "denied" as "not there" is how a plain hidden photo
  gets left in a bucket while the app reports itself clean.
- **One task per object per target.** A target removed from the app leaves
  its tasks dormant; re-add it and they run.
- Outstanding counts show **inside the unlocked album**, nowhere else.

### Walking through it

**1. New phone, nothing hidden yet.**
Tap Hidden → passphrase + hint → 4 digits → the album opens. With a bucket
configured, hidden photos leave the phone as carriers. Without one, they
stay local and the album says so.

**2. Changed phone, app data restored, same passphrase.**
Install → restore app data → re-enter the bucket credentials, which never
travel in a backup → tap Hidden → passphrase → 4 digits → the album is
there, drawn from `index.bin`, tiles arriving as 64 KB ranged GETs. The
photos are not in the new phone's Photos and never will be: the bucket is
the only place they exist.

**3. Changed phone, a different passphrase typed first.**
That becomes the active one and covers new uploads. The old carriers show
as locked; add the old passphrase in the album and they open. Both
generations live in the same bucket.

**4. Changed phone, old passphrase gone for good.**
Those carriers stay locked, listed with their hint, costing bucket space
and nothing else. The app has no opinion about when someone stops trying to
remember; deleting them is a deliberate action in the album.

**5. Someone else picks up the phone.**
Whatever they type opens an album. An unused code opens an empty one.
Nothing counts, nothing errors, nothing says a passphrase was ever set.

**6. Two phones, one bucket.**
Same passphrase on both → one shared generation. Different ones → each
reads its own and sees the other's as locked until that passphrase is
added. **Nothing destroys anything.**

### Restore

Pointing the app at a bucket with the passphrase is enough: `index.bin`
gives every album's contents, and each carrier is self-describing if the
index is gone. A bucket restored *without* the passphrase is a complete,
working library of ordinary photos — the carriers are the duplicates nobody
looks at twice.

## Cipher

AES-256-CTR + HMAC-SHA256, encrypt-then-MAC, streamed in 1 MB chunks on an
isolate. Each payload carries its own 32 B tag, so the thumbnail verifies
from a 64 KB read without the original present.

Via `dart:ffi` to **CommonCrypto** (`CCCryptorCreate`/`Update`/`Final`,
`CCKeyDerivationPBKDF`) — already on every iPhone. No new package: the
budget is 33 MB and pointycastle would spend a slice of it on AES that iOS
already ships. HMAC comes from `crypto`, already a dependency. ~60 lines of
FFI behind a `VaultCipher` interface, so an Android `javax.crypto` channel
slots in when Android does. No hand-rolled primitives.

### Header

First `APP7` segment, after a 4-byte locator:

```text
version     1 B
masterSalt 16 B      the passphrase's KDF salt — makes this file self-describing
thumbLen    4 B      encrypted thumbnail bytes that follow
ivThumb    16 B      AES-CTR counter block, thumbnail
ivFull     16 B      AES-CTR counter block, original
length      8 B      plaintext bytes of the original
ext         4 B      "heic", "jpg\0" — what it was
```

**Locator** = first 4 bytes of `HMAC(macKey, "pv-carrier-v1")`. Keyed, so
the rebuild scan can find its own carriers; not a secret, since the format
is public and the segment's shape gives it away anyway. It just keeps a
constant magic string out of every object.

`masterSalt` costs a fingerprint — one generation's carriers share it, so a
bucket can be grouped by generation — which the threat model already
concedes.

## Size budget: no new packages, at all

Headroom is **0.8 MB** — 32.2 MB measured against a 33 MB budget. That
settles the media question before it is asked: every packaged encoder is an
order of magnitude over the whole remaining budget, so the work goes to
frameworks already inside iOS.

| need | how | added |
|---|---|---|
| JPEG segments, MP4 boxes | ~500 lines of pure Dart — both are size+type+payload streams | ~0 |
| decoy still: upscale + JPEG encode | `image`, already a dependency, already reached via `encodeThumbnail` / `copyResize` | 0 |
| EXIF on the decoy | hand-written minimal APP1, ~100 lines — avoids pulling `image`'s Exif encoder in | ~0 |
| AES + PBKDF2 + HMAC | `dart:ffi` → CommonCrypto (system), HMAC from `crypto` (already a dependency) | 0 |
| decoy video: hold one frame | AVFoundation `AVAssetWriter` via a platform channel, ~150 lines of Swift | ~0 |
| first frame of a decoy video | `AVAssetImageGenerator`, or `photo_manager`'s poster frame, already used | 0 |
| duration / resolution / size of a video | `photo_manager`, already used | 0 |
| playback | `video_player` → AVPlayer, already a dependency | 0 |

Realistic total: **under 0.2 MB**, nearly all of it Dart AOT for ~900 new
lines.

**`ffmpeg_kit_flutter` is out of the question** — its smallest variant is
tens of megabytes, twenty times the headroom, for an encode iOS performs in
hardware. So is any "video toolbox" plugin that vendors its own binaries.
Thin wrappers over AVFoundation would fit, but the wrapper is bigger than
the ~150 lines it replaces (CLAUDE.md: prefer writing the forty lines).

Two things to watch when measuring:

- **`image` retention.** The repo's standing rule is `decodePhoto`, never
  `img.decodeImage`, because the latter drags every decoder into AOT. The
  decoy path must stay on the already-reached calls; a new corner of that
  package is a megabyte nobody budgeted.
- Check with `flutter build ios --release --analyze-size` (dropping
  `--obfuscate`, which cannot combine with it) before and after, not by
  reasoning about it.

Android, when it comes: `MediaCodec` / `MediaMuxer` and `javax.crypto`,
system again, same zero.

## Open decisions

- **Whether video carriers ship in v1** or land after the JPEG path. They
  are real extra work (MP4 boxes, a held-frame encoder) but no longer a
  weak link.
- **How loudly to say the Recently Deleted thing.** A prompt every time is
  noise; once per install is forgettable. Leaning: every time, until the
  user has emptied it once.
- **Sharp-decoy switch** for anyone who wants to beat scripted analysis at
  ~2 MB a photo. Not v1.

## What this does not protect

- **The 30 days Photos holds a deleted asset.** The biggest gap, and not
  ours to close.
- **The count.** Anyone with the bucket and this repo can detect carriers
  and count them. Accepted.
- **Traffic.** Upload sizes and timing are what they are.
- **A phone in someone's hands, unlocked, with the code typed.** Never the
  gate's claim.
- **Person-profile locks (T7.4)** still use `hashPasscode`, unchanged and
  out of scope here.

## Copy, as it now reads

`privateAlbumBackupExplainer` (en + zh) was the one string making a claim
about the bucket copy, and it used to end "The photo itself is not
encrypted". It now says what actually happens, and the album footer carries
two more: what to do when there is no bucket, and the 30-day Recently
Deleted caveat. **How this works** under it is ten plain sentences —
collapsed to three with a More — covering the no-wrong-passcode property,
the decoy, where the key comes from, what stays on the phone, and the fact
that anyone who reads this repo can count carriers but not open one.

The per-album backup switch and `PrivateAlbumSync` are gone: everything
hidden is cloud-native, so there was nothing left to choose. See
`docs/design/uiux/collections.md`.
