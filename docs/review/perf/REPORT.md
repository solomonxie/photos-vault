# Performance Review (Oct 2026, n = 40k photos)

Findings in `01-ui.md` (UI-*), `02-storage.md` (DB-*), `03-background.md` (BG-*). These are estimates from reading the code, plus a synthetic 40k sqlite model. Confirm the P0s in a profile build (`_reportJank`).

## Headline

| # | Problem at 40k | IDs |
|---|---|---|
| 1 | `entity.file` re-renders each photo as a quality-1.0 JPEG on every call (verified in `PMManager.m:1751`). About 4-5 renders per photo, est. 10-25 h CPU and TB-scale flash writes. The bucket receives JPEG re-renders, not HEIC originals | BG-2, BG-4, BG-10 |
| 2 | Each resume does a full camera-roll re-scan: 200 pages, album list fetched per page, title per asset. Est. 20-60 s native CPU, plus reloads every 1 s | BG-1, UI-3, UI-4 |
| 3 | Cold start: 40k rows are read and mapped on the UI isolate, so no photo shows for 0.8-1 s. Eight library-wide jobs start in the same tick | UI-1, DB-1, DB-3, BG-3 |
| 4 | Strangers row: about 16-20 MB of descriptors decoded on the UI isolate. 0.2-0.6 s per pass, after each delete, hide or name | UI-2, DB-2 |
| 5 | Change log stores the full row twice, with a 20k cap. This explains most of the 289 MB DB. Backups and daily copies carry it (~1.4 GB of disk) | DB-4, DB-8, DB-9 |
| 6 | Periodic waste: storage sweep every 20 s rewrites a 2-3 MB cache; analyze queue reads 6 tables every 30 s; flag scan every 15 s during uploads | BG-7, BG-9, BG-12, UI-11, UI-18 |
| 7 | Grid paint: a blurred shadow per backed-up tile, 30-45 per frame | UI-7, UI-8 |

## Fix plan (work packages, in order)

| PW | Scope | IDs | Data risk |
|---|---|---|---|
| PW1 | Startup: stage launch jobs behind idle; lean `listAll` (no raw maps kept, mapping off the UI isolate); repairs and trigger rebuild after the first frame; parallel pre-frame platform calls | UI-1, DB-1, DB-3, BG-3, UI-16 | none |
| PW2 | Resume: recent lane only, full pass at most daily; album list once per pass; `needTitle: false` (title only for new ids); one transaction per page; reload coalesced during scan | BG-1, BG-8, DB-6 (txn part), UI-3, UI-4 | none (`_markGone` unchanged) |
| PW3 | Renders: PhotoKit thumbnails and Vision without a file; hash in an isolate, once; `checkChanges` by modification date; clear plugin tmp | BG-4, BG-10, BG-5, BG-6 | none |
| PW3b | Upload source `originFile` (true original bytes) plus a one-time hash re-baseline | BG-2 | **decision**: edited photos, re-baseline |
| PW4 | Faces: `descriptorsOf(newest 1200)`; indexes; batched avatars; capped cover/avatar decodes | UI-2, DB-2, DB-10, UI-9, UI-10 | none |
| PW5 | DB size: change log stores changed fields only; prune at launch plus 5k cap; VACUUM with file temp store; `secure_delete=FAST` inside the prune only; decode log in isolate; daily copies exclude log/cache | DB-4, DB-5, DB-7, DB-8, DB-9 | low: hidden rows still zeroed |
| PW6 | Periodic: early-out sweep, incremental analyze refresh, cached import thumbs, flag rescan only on relevant rev, skip failing thumbs | BG-7, BG-9, BG-11, BG-12, UI-11, UI-18, BG-15 | none |
| PW7 | Grid: badge shadow to a pre-baked icon, clip to tile-level `ClipRRect` hardEdge or none; no per-tile actions or formatters; one scroll timer | UI-7, UI-8, UI-13, UI-15, UI-12 | none |
| PW8 | Reload and search: skip unchanged derived sets; debounced, isolate-built search index; cheaper drag-select, sub-screens | UI-5, DB-14, UI-6, UI-14, UI-17, UI-19 | none |
| PW9 | Rest: streamed carriers and optimizer reads; batched per-id calls; WAL (`synchronous=FULL` plus checkpoint after hidden deletes); indexes; single-flight open | BG-13, BG-14, BG-16-18, DB-6 (WAL), DB-11-13, DB-15, DB-16 | WAL/rebuild behind guard copy |

Order: PW1, PW2, PW3, PW4 deliver most of the user-visible gain. PW3b changes what gets backed up and needs a decision first.
