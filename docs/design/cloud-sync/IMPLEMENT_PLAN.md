# Cloud sync + browser extension: implementation plan

Design: `DESIGN.md` · Wire format: `PROTOCOL.md` · Drawings: `uiux/`

## Phase 1: Protocol fixtures
Both sides implement the same merge, so the shared fixtures come first. Every
later sync task is "make these vectors pass".

- [x] T1.1 Write `vectors/*.json` for every case listed in `PROTOCOL.md` → Fixtures — see `docs/design/cloud-sync/PROTOCOL.md` — depends: none
- [x] T1.2 Permutation runner spec: apply the segments in every order (and with duplicates), assert identical state — see `docs/design/cloud-sync/PROTOCOL.md` — depends: T1.1

## Phase 2: Sync engines (phone and extension in parallel)
These are pure cores with no UI: HLC, op codec, merge, segment/checkpoint
codec, pull loop. Dart and TS are written independently against the same
vectors. That's the cross-check that they agree.

- [x] T2.1 Dart core `lib/sync/`: `hlc.dart`, `op.dart`, `merge.dart`, `segment.dart`, `checkpoint.dart`; vector + permutation tests — see `lib/sync/` — depends: T1.2
- [x] T2.2 `sync.db` (`lib/sync/sync_store.dart`): device id, HLC, outbox, applied vv, conflicts; add to `DatabaseHome.names`, the app-data backup, the change mark; restore takes a new device id and re-stamps the outbox; backup + fresh-install restore tests — see `lib/backup/` — depends: T2.1
- [x] T2.3 Outbox capture: triggers on `asset_record`, `album`, `album_asset`, `person`, `person_asset` record writes into `sync_outbox` in the writer's transaction; `sync_flag` keeps them idle until enabled and silent while applying pulled ops; private rows record only their flip; `translate.dart` turns rows into ops — see `lib/sync/capture.dart`, `lib/sync/translate.dart` — depends: T2.2
- [x] T2.4 Bucket I/O: write-once PUT per provider (`If-None-Match` / forbid-overwrite headers, 412 → MD5 check), segment flush (2 s quiet / 200 ops), list-from-cursor pull, gap handling — see `lib/sync/bucket_log.dart`, `lib/upload/bucket_http.dart` — depends: T2.1
- [x] T2.5 TS core `extension/src/sync/`: same modules + vitest on the vectors — see `extension/` — depends: T1.2
- [x] T2.6 TS bucket client `extension/src/bucket/`: SigV4 for S3/COS/OSS (port of `lib/upload/signing.dart`), list/get/put/head/multipart, write-once headers; no AWS SDK — see `extension/` — depends: none
- [x] T2.7 TS local store: IndexedDB (entities, outbox, vv, conflicts), the outbox + entity write in one transaction, one writer via the service worker + Web Locks — see `extension/src/store/` — depends: T2.5

## Phase 3: Phone publishes and pulls
The phone holds all the data today, so it goes first. Until it publishes a
checkpoint, the extension has nothing to show.

- [x] T3.1 Bootstrap/join: capture on first, then publish the library through the ordinary log + a checkpoint, or adopt the bucket's checkpoint, take its values for shared entities and queue only what it lacks — see `lib/sync/bootstrap.dart`, `lib/sync/cloud_sync.dart` — depends: T2.3, T2.4
- [x] T3.2 Applier: merged state → this phone's rows in one transaction per database, skipped while local edits wait uncollected; existing photo records only (new ones: T6.3); albums deleted elsewhere keep their notes — see `lib/sync/apply.dart` — depends: T2.3, T2.4
- [x] T3.3 Scheduling: a 30 s tick while open (round when edits wait or every 2 min), on resume and pause, once in the BG task — see `lib/sync/cloud_sync.dart`, `lib/viewer/library_screen.dart`, `lib/main.dart` — depends: T3.2
- [x] T3.4 Checkpoint cadence: weekly per phone (thinning old checkpoints still open) — see `lib/sync/cloud_sync.dart` — depends: T3.1
- [ ] T3.5 Settings › Library Sync group (done), conflict card in the detail panel (done); Library nav badge and "Binned on another device" in the Bin still open — see `docs/design/cloud-sync/uiux/sync.md` — depends: T3.2
- [ ] T3.6 Thumbnails for HEIC `web:` assets: render on the phone, PUT to `thumbnails/`, op `set thumbnail_key` — see `lib/photos/image_pipeline.dart` — depends: T6.3

## Phase 4: Extension shell and browsing
This needs the TS engine and a published checkpoint. It's read-only first, so
a wrong sync can't hurt anything yet.

- [ ] T4.1 Scaffold `extension/`: MV3 manifest, esbuild, TS strict, `_locales/en` + `zh_CN`, `npm run build` → `extension/dist/`, local `node_modules` only — see `extension/README.md` — depends: none
- [ ] T4.2 Setup page + paste mode + drafts + optional host permission + access check + no-library check + waiting-for-phone — see `uiux/setup.md` — depends: T2.6, T4.1
- [ ] T4.3 Load: checkpoint + log into IndexedDB with progress; pull every 30 s while visible — see `extension/src/sync/` — depends: T2.7, T4.2
- [ ] T4.4 Library grid: virtualized day grid, thumbnail cache, scrubber, selection — see `uiux/library.md` — depends: T4.3
- [ ] T4.5 Viewer overlay + info panel (read-only first) — see `uiux/viewer.md` — depends: T4.4
- [ ] T4.6 Albums / People / Places / search index + results — see `uiux/collections.md`, `uiux/library.md → Search` — depends: T4.4

## Phase 5: Editing from the browser
Writes reach the bucket only after the phone has proved it applies them
(Phase 3 vectors + an on-device check).

- [ ] T5.1 Edits: description, favorite, tags, taken date, location, album/person membership, album create/rename/delete, person rename — see `uiux/viewer.md`, `uiux/collections.md` — depends: T4.5, T4.6, T3.2
- [ ] T5.2 Bin / Restore + Bin page + undo toast — see `uiux/collections.md → Bin` — depends: T5.1
- [ ] T5.3 Status chip + Sync panel + conflict card + resolve — see `uiux/sync.md`, `uiux/viewer.md` — depends: T5.1

## Phase 6: Upload from the computer
Last, because it adds bytes on top of everything above.

- [ ] T6.1 Upload tray: drop/pick, SHA-256 dedupe against `content_hash`, EXIF date/GPS, thumbnail/poster, multipart resume, HEAD both, then `asset.add` — see `uiux/upload.md` — depends: T5.1
- [ ] T6.2 Phone mirrors `web:` originals to the other configured buckets on its backup pass — see `lib/upload/backup_coordinator.dart` — depends: T3.2, T6.1
- [ ] T6.3 Cloud-only records on the phone for photos added elsewhere (browser, another phone): insert in the applier's transaction with keys and derivative targets, then re-apply the albums and people that name them — see `lib/sync/apply.dart`, `lib/upload/library_restore.dart` — depends: T3.2, T6.1

## Phase 7: Proving no data loss
Run before any release. Per the repo `CLAUDE.md`, this is the one test pass
at the end.

- [ ] T7.1 Multi-device simulation: 3 virtual devices, random edits, offline windows, crashes between "PUT done" and "recorded", clock skew; assert convergence and that no write is lost (in the final state or as a conflict) — see `test/sync/` — depends: T2.1, T2.4
- [ ] T7.2 Same simulation in TS, plus Dart ↔ TS cross-run over a fake bucket directory — see `extension/test/` — depends: T2.5, T2.6, T7.1
- [ ] T7.3 On device (iPhone 14 + SE on iOS 15): edit in Chrome → appears on both; edit the same caption on phone and Chrome offline → conflict card on both; kill the app mid-flush → nothing lost — depends: T5.3, T6.1
- [ ] T7.4 Size check: the phone stays under the 25 MB budget; the extension `dist/` is under 300 KB — depends: T5.3
- [ ] T7.5 Chrome Web Store packaging (unlisted) via the `chrome-extension` skill — depends: T7.3
