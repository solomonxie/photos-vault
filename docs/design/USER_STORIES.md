# User Stories

Deletion and out-of-band changes. Each row: what the user does, what should
happen, what happens today (`gap` = see Gaps below).

Vocabulary: **local** = file on the phone / OS Photos. **remote** = bucket.
**cloud-only** = row kept, local original gone, remote copy is the only one.
**bin** = the app's Recently Deleted.

## Invariants

- A photo is never made cloud-only unless the bucket is proven to hold its
  original **and** its thumbnail (HEAD, not the row's claim).
- Nothing leaves the bucket without the user choosing "delete everywhere".
- A delete that can't finish is queued and retried, never silently dropped.
- Hidden photos never leave a plaintext trace locally or remotely.

## Stories

| # | Story | Expected | Today |
|---|-------|----------|-------|
| 1 | Free space: remove from device only | Original gone locally; row, thumbnail, bucket kept; cloud-only with Download | Gated on an uploaded thumbnail; single and batch paths both prove original + thumbnail per bucket |
| 2 | Delete a photo (ordinary) | OS asset removed, row to bin, bucket kept | Done; bin purges after 30 days and has Empty |
| 3 | Recover from bin | Row back | Row back; a photo gone from the OS library returns cloud-only (no save-to-Photos API), Download restores it |
| 4 | Delete permanently | Local files, row, every derivative in every bucket gone | Row dropped at once; bucket deletes go on the durable queue, retried each sync, per-bucket keys |
| 5 | Delete from both in one step | Same as 4 from the grid | Single-photo sheet offers Delete Permanently; batch sheet does not |
| 6 | Delete in the OS Photos app | Backed up: cloud-only, bucket kept | Marked cloud-only at once, then proven against the bucket on the next spot check |
| 7 | Photo comes back from OS bin | Row restored | Done |
| 8 | File added to bucket without the app | Offered for import, never silent | Detected on sync; Cloud settings shows "N new files found"; unclaimed names included; same-size files flagged as likely duplicates; upload-stamped files with no capture date of their own listed as likely leftovers, never offered; import dated from the file's own metadata |
| 9 | File removed from bucket without the app | User told; local copy re-uploads; never auto-delete the row | Per-bucket spot check; local copy re-queued for the bucket that lost it; with no copy left the photo is counted Lost on Safety; thumbnails checked too |
| 10 | Hide a photo | Plain copies retracted from every bucket | Per-bucket key resolution |
| 11 | Delete a hidden photo | Local + carriers gone, no bin | Same, per-bucket keys; waits for a bucket if none is configured |
| 12 | Free space for a hidden photo | Carrier dropped locally, encrypted tile kept | Proof is a 64 KB prefix read |
| 13 | Unhide | Plain copy back, carriers removed after | Pending delete skips a key the new upload holds |
| 14 | Hidden carrier deleted from bucket | User told | Viewer says the photo is no longer in the bucket (404 on every bucket), not "needs network" |
| 15 | Edit a photo | Bucket original and thumbnail updated | Thumbnail refreshed; Live Photo motion half checked; old key queued for delete if the name changes |
| 16 | Reinstall / new device | Library rebuilt from bucket | Restore runs before the first scan on an empty library (10 s cap); per-bucket upload rows in the snapshot |
| 17 | Remove All App Data | Bucket untouched; pending deletes survive | Pending and deferred deletes both carried over |
| 18 | Small, video or any photo | Always has a thumbnail in the bucket | Size skip removed; existing ones backfilled on sync |

## Remaining gaps

- **Hidden photos, free-up proof:** a prefix read, not the whole object.
- **Duplicates:** size-only guess in the bucket; no byte dedupe on the camera roll.
- **Batch delete sheet:** no permanent option.
- **Dead target:** deletes wait until the bucket is reachable or the user forgets it.
- **Lost state:** shown on Safety and as the red dashed tile; no dedicated label in the detail screen.
- **Derived keys:** a bucket with no recorded row is rebuilt from the layout and can miss a differently named object.
