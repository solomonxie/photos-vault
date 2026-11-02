# Sync protocol v1

What the phone (Dart, `lib/sync/`) and the extension (TS,
`extension/src/sync/`) must agree on exactly. Both run the fixtures in
`vectors/`. A change here bumps `v` and adds vectors.

## Bucket layout (home bucket, under the target's prefix)

```text
sync/
├── devices/<device>.json                 {device, name, kind: phone|browser, created, lastSeen}
├── log/<device>/<seq:012d>.ndjson.gz     immutable segment, seq from 1, no gaps
└── checkpoints/<device>/<hlc>.ndjson.gz  full state + version vector
originals/ thumbnails/ medium/ edited/    unchanged; see lib/upload/object_keys.dart
```

- `<device>`: UUID v4, lowercase.
- **Write-once**: every segment and checkpoint PUT carries `If-None-Match: *`
  (S3), `x-oss-forbid-overwrite: true` (OSS) or `x-cos-forbid-overwrite: true`
  (COS).
  - A 412/409 means the key exists. HEAD it and compare the MD5. Equal means
    an earlier try landed (done); different means a collision, which is a fatal
    sync error, and the device stops writing.
  - A segment's bytes are sealed locally before the first PUT and never rebuilt.

## Clock and stamps

```text
hlc    = "<wall:013d>-<counter:04d>"     fixed width, so it sorts as a string
stamp  = "<hlc>@<device>"                total order = string order
wall   = local ms + offset to the bucket's `Date` response header (refreshed each pull),
         so a phone with a wrong clock still stamps in bucket time
tick:     wall' = max(now, last.wall); counter = wall'==last.wall ? last.counter+1 : 0
receive:  last = max(last, op.hlc) before the next tick, so a later local op outranks what it saw
bound:    an op with wall > segment LastModified + 1h is ignored by everyone
          (LastModified is set by the server: every reader decides the same way)
```

Every op gets a fresh tick, so stamps are unique.

## Op (one JSON line; `d` and `seq` come from the segment)

```json
{"h":"1793414025123-0003","e":"asset","id":"9F2C…/L0/001","o":"set","f":"description","x":"Beach, day 2"}
```

| `o` | Meaning | Fields |
|---|---|---|
| `add` | the entity exists; each field in `x` is set as if by `set` with this stamp | `x`: field map |
| `set` | LWW one field | `f`, `x` (JSON scalar or null) |
| `madd` | OR-set add; its tag is the op's own stamp | `f` (set), `x` (member) |
| `mrem` | OR-set remove | `f`, `x`, `ts`: tags it saw for that member |

Bin = `set deleted_at <ms>`; restore = `set deleted_at null`. There is no
erase op. A photo whose record the phone deleted for good (bytes purged by
the guarded delete) gets `set purged <ms>`, and every client drops it.

Entities and fields (v1). Anything not listed never leaves the phone:

| `e` | id | fields (LWW) | text fields (conflict-tracked) | sets |
|---|---|---|---|---|
| `asset` | `local_id` / `web:<uuid>` | `created_at` (taken), `latitude`, `longitude`, `is_favorite`, `is_archived`, `deleted_at`, `hidden`, `purged`, `original_key`, `thumbnail_key`, `medium_key`, `live_key`, `edited_key`; at `add`: `content_hash`, `is_video`, `is_live_photo`, `width`, `height` | `description`, `location` | `tags` |
| `album` | UUID | `cover_local_id`, `deleted_at` | `name`, `description` | `members` (asset ids), `tags` |
| `person` | UUID | `birth_date`, `gender`, `avatar_local_id`, `deleted_at`, `hidden` | `name`, `bio` | `members` (asset ids) |
| `place` | UUID (travel.db) | `kind` (country · city · area · point), `lat`, `lng`, `parent_id`, `country`, `address`, `category`, `created_at`, `deleted_at` | `name`, `description` | — |
| `entry` | UUID (travel.db) | `place_id`, `kind` (impression · diary), `at`, `rating`, `created_at`, `deleted_at` | `title`, `text` | `tags`, `photos`, `people` |
| `route` | UUID (travel.db) | `starts`, `ends`, `created_at`, `deleted_at` | `title`, `note`, `stops` (JSON `[{place, arrived, note, mode, leg, review}]`, leg = to the next stop) | `photos`, `people` |

**Private stays private.** A hidden, locked or passcode-gated row never
emits an op. Hiding an asset that was already synced emits
`set hidden true`, and every client drops it from view. Its earlier
metadata stays in the immutable log; the UI says so when hiding. A locked
person works the same way.

## Merge (order-independent)

**Seen.** Op `a` has seen op `b` when:
- `a.d == b.d` and `a.stamp > b.stamp`, or
- `a.vv[b.d] >= b.seq`.

`vv` is its segment's version vector. Seen is transitive.

```text
field value     = x of the op with the greatest stamp among (e, id, f)   (`add` counts per field)
text heads      = ops on (e, id, f) not seen by any other op on it
conflicts       = text heads − winner     (both values are kept; nothing silently lost)
set members     = { x | some madd tag for x is in no mrem.ts }
entity listed   = an `add` for it has been applied
op before its add → kept, applied as it arrives; the result is the same in any order
```

**Incremental heads.** For an arriving op `n`:
- if some head saw `n`, drop `n`;
- else remove the heads that `n` saw, then add `n`.

The winner is always the max of the heads.

Resolving a conflict is a new `set` made after seeing every head, so it
supersedes all of them.

## Segments: sealing before applying

```text
line 1: {"v":1,"d":"<device>","seq":42,"vv":{"<device>":<seq>,…},"n":<ops>}
then n op lines. gzip. ≤ 200 ops or 256 KB.
```

- `vv` = the highest contiguous seq applied per other device.
- **Seal the outbox before applying any pulled segment.** Every op in a
  segment was then created knowing exactly `vv`. Otherwise an op would claim
  to have seen something it hadn't, and a real conflict would vanish.
- An unsealed local op merges locally as `seq = next seq` with `vv = current vv`.

## Checkpoint

```text
line 1: {"v":1,"d":"<device>","h":"<hlc>","vv":{…all devices incl. own…}}
then one line per entity:
  {"e","id","exists":bool,
   "f":{field:{"x":…,"s":"<stamp>"}},
   "heads":{textField:[{"x","s","seq","vv"}…]},
   "sets":{set:{member:{"a":[tags],"r":[tags]}}}}
```

Load = the newest checkpoint by `h` across devices. Then for each device,
the segments with `seq > vv[device]`. A checkpoint is exactly the merge
state, so loading it and applying the rest equals applying everything.

**Bootstrap.** A phone's first sync queues its whole library as `add`
and `madd` ops through the ordinary log (segments from seq 1), then
publishes a checkpoint.
- Two phones bootstrapping at once both land in the log, so neither is
  lost. The checkpoint only saves new devices the download.
- A phone joining a library that already exists adopts the checkpoint,
  takes the cloud's values for everything it shares, and adds only what
  the cloud lacks.
- A device with no state loaded never edits. A browser waits for the first
  checkpoint.

## Pull

```text
per device prefix under sync/log/: ListObjectsV2 start-after=<last applied key>
apply in seq order; a gap → stop for that device, retry next pull
apply in one local transaction, then advance vv; a crash mid-apply → reapply (idempotent)
```

## Fixtures: `vectors/*.json`

```json
{"name":"…","now":"<hlc>",
 "segments":[{"d":"a","seq":1,"vv":{},"lastModified":1793414025000,"ops":[…]}],
 "expect":{"entities":{"asset/A":{"fields":{…},"sets":{"tags":["beach"]}}},
           "conflicts":[{"e":"asset","id":"A","f":"description","x":"…","d":"b"}]}}
```

- Runners apply the segments in **every permutation** that keeps each
  device's seq order, and with each segment repeated. Every run must equal
  `expect`.
- Same-device segments stay in seq order, as the pull guarantees.
- `fields` lists every field with an op, including nulls.
- `sets` lists members sorted.
- `conflicts` is sorted by `(e, id, f, stamp)`.
