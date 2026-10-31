# Cloud sync + browser extension

Wire format: `PROTOCOL.md` · Interface: `UIUX_DESIGN.md` · Build: `IMPLEMENT_PLAN.md`

## Problem
The library lives in the phone's SQLite. The bucket only gets photo bytes and a
daily `app-data/` zip, which is enough to restore but not enough to share with a
second device. So nothing on a computer can browse or edit the library. And an
edit made anywhere except the phone has nowhere to go.

## Goals
- **The bucket is the source of truth**, holding photo bytes *and* library
  metadata. The phone and the browser are both caches of it.
- A Chrome extension (`extension/`) opens a Google-Photos-like page over the
  bucket. Its only setup is a bucket connection.
- From the browser: browse (timeline, albums, people, places, search, viewer),
  upload from the computer, edit metadata, and move items to the bin or back.
- The phone pulls changes on its own (on foreground, every few minutes while
  open, in the BG task), so a browser edit shows up with no action on the phone.
- **No lost data under any interleaving**: concurrent edits, two tabs, a
  killed app, a half-finished upload, clock skew, a reinstall.
- The phone stays as fast as today. A pull never janks the grid.

## Non-goals (v1)
- **Hidden photos** (passcode-locked, stored encrypted in the bucket as
  carriers). They stay phone-only and never enter the log. The browser can't
  see them, not even their count. Same for locked people and anything else
  behind a passcode.
- Permanent bucket deletes from the browser. Purging stays on the phone,
  behind `BucketOps.deleteGuarded`.
- Syncing chats, writings, travel, AI analysis and faces. They keep riding
  the daily snapshot; they're later phases of this same log.
- Real-time collaboration and multiple users. One owner, a few devices.
- Writing into the iOS photo library. A browser upload is cloud-only on the
  phone, like a record restored after a reinstall.
- Firefox/Safari. The page is plain web code, so porting later is cheap.

## Options considered
- **Shared snapshot + compare-and-swap** (`If-Match` on one library file):
  every edit rewrites a multi-MB file, and conditional-write support differs
  across S3, COS and OSS. → rejected.
- **Server or DB in the middle** (Firestore, Supabase, a Lambda): there's no
  backend, and the bucket the user owns *is* the product. → rejected.
- **Per-device append-only op log (WAL)**: every device writes only under its
  own prefix, so no two writers ever touch the same object. A merge is
  deterministic and needs no coordinator. → **chosen**.
- Merge rule: whole-row LWW (drops a concurrent edit to another field) vs
  per-field LWW with add/remove sets (CRDT-style) → **per-field LWW + OR-sets**.
- Extension stack: Flutter web (MBs of runtime, slow first paint) vs plain
  TypeScript, no framework, esbuild → **TypeScript**, in line with "blazing fast"
  and "write the forty lines".

## Decision
Per-device op log in the bucket under `sync/`. Details in `PROTOCOL.md`:

- **Segments are immutable.** `sync/log/<device>/<seq>.ndjson.gz`, write-once
  (`If-None-Match: *` / `x-oss-forbid-overwrite` / `x-cos-forbid-overwrite`).
  A retry PUTs the same bytes to the same key, so it's idempotent.
- **Ordering**: hybrid logical clock `(wall ms, counter, device)`. It's
  monotonic despite skewed clocks, and two devices never tie.
- **Merge**:
  - Scalar fields are LWW per field.
  - Album/person/tag membership is an OR-set: a remove cancels only the adds
    it has seen, so a concurrent add survives.
  - Deletes are the bin (`deleted_at`), never an erase.
- **Losing a concurrent text edit is not silent.** When two devices edit the
  same text field without seeing each other's edit, the loser is kept as a
  *conflict*. Both sides show "Edited elsewhere" with both values. And the log
  is never trimmed below the oldest checkpoint, so any overwritten value can
  still be recovered.
- **Bytes before ops.** An `asset.add` op is written only after HEAD confirms
  its objects (the rule `app-data/` zips already follow for blobs). So no op
  ever points at a missing file.
- **Local write and outbox in one SQLite transaction** on the phone, in one
  IndexedDB transaction in the browser. A crash leaves either both or
  neither.
- **Checkpoints**: any device can publish
  `sync/checkpoints/<device>/<hlc>.ndjson.gz` (the full materialized state +
  version vector). A new device loads the newest checkpoint plus the log after
  it.
- **Device IDs**: one fresh UUID per install or browser profile, stored in the
  database (never the keychain, which survives reinstalls). Before its first
  write, a device lists its own prefix and must find it empty. A restore takes a
  new ID and re-stamps its unsent outbox under it.
- **The phone bootstraps.** On first enable it publishes a checkpoint of its
  whole library. Until that exists, the extension shows "Open Photos Vault on
  your phone once".
- **Identity**: an asset's global id is today's `local_id`, which bucket keys
  already carry. Browser uploads use `web:<uuid>`. Albums and people already
  have TEXT UUIDs.

## Data & integrations
- **Bucket**: the home bucket gets `sync/log/`, `sync/checkpoints/` and
  `sync/devices/<device>.json` (name, last seen). Browser uploads use the
  existing `originals/` and `thumbnails/` layout (`lib/upload/object_keys.dart`).
- **Home bucket**: the log lives in one configured target, picked in the
  phone's Settings. The default is the first target. Mirror buckets keep
  getting the bytes and the daily snapshot as today.
- **Phone**: a new `sync.db` holds the outbox, applied version vector, HLC,
  device id and conflicts. It's added to `DatabaseHome.names` and the app-data
  backup (with a restore test) and moves the change mark.
- **Extension**:
  - The connection lives in `chrome.storage.local`, never `.sync`, so the
    secret doesn't follow the Google account.
  - Library state lives in IndexedDB; thumbnails go in the Cache API.
  - `host_permissions` for the bucket endpoint is requested at setup.
    Extension pages aren't subject to CORS, so the bucket needs no
    configuration change.
- **Cost**:
  - Pulls are one `ListObjectsV2` per device prefix with `start-after`, which
    is cents a month.
  - A segment is one PUT per batch of edits, flushed after 2 s of quiet or 200
    ops.
  - Checkpoints are written at most daily, by whichever device has the most
    ops since the last one.

## Risks / open questions
- **Wall clock badly wrong** (years off): HLC keeps the order, but a
  far-future op would win every later LWW. Ops more than 24 h ahead of the
  receiver are rejected and shown as a sync error, not applied.
- **Log growth**: never trimmed in v1. That's about 100 B per op. Trimming to
  "older than every device's last checkpoint" comes later.
- **HEIC uploaded from a computer**: Chrome can't decode it. The original goes
  up with no thumbnail, the grid shows a placeholder, and the phone renders one
  on its next pull and publishes it. Video posters come from a `<video>`
  frame.
- **An old phone build meeting a newer op version**: it stops writing and
  pulls read-only until updated, rather than misapplying ops.
- **Mirror buckets for browser uploads**: the phone copies them on its next
  backup pass (open: on Wi-Fi only?).
