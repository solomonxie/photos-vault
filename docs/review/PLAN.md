# Code Review Plan — Oct 2026

Whole-repo review of `lib/` (~79k lines, 190 files). Read-only: findings and
suggestions only, no code changes until approved.

## Rules for every step

- **Mac load first.** `sysctl -n vm.loadavg hw.ncpu kern.memorystatus_vm_pressure_level`
  before starting a step. Max 2 steps in parallel; 1 if load > ncpu or pressure ≥ 2.
- **No builds, tests, simulators.** Read, grep, `git log`/`git blame` only.
- **Verify before filing.** Each finding names `file:line`, a concrete failure
  scenario (input/state → wrong result), and a suggested fix. Unprovable = mark
  `PLAUSIBLE`, not `CONFIRMED`.
- **Severity:** `P0` data loss / photo deleted / privacy leak · `P1` wrong
  result, crash, stuck state · `P2` perf (dropped frame, O(library) on UI
  isolate, N+1) · `P3` cleanup, simplification, dead code.
- **Output:** `docs/review/findings/NN-<step>.md`, findings ranked P0→P3, then
  improvement suggestions, then "checked and fine" (one line each).
- **Repo rules to audit everywhere** (from `CLAUDE.md`): no image decode/encode
  on main isolate; no per-build work proportional to library size; no sync file
  I/O on UI isolate; no N+1 queries; uploads only via `background_downloader`;
  `decodePhoto` not `img.decodeImage`; no `material.dart`; nothing new in
  `flutter: assets:`; knowingly-violated rules say so at the call site.

## Steps

| # | Step | Scope | Status |
|---|------|-------|--------|
| 01 | Storage | `lib/storage/` | ☑ |
| 02 | Upload & bucket | `lib/upload/` | ☑ |
| 03 | Vault & backup | `lib/vault/`, `lib/backup/` | ☑ |
| 04 | Library sync & storage fixes | `lib/photos/` sync, custody, removal, optimizer, advice, fix queue, record fixer | ☑ |
| 05 | Analysis, faces, people | `lib/photos/` ai_*, face_*, person_*, analyze_queue, on_device_* | ☑ |
| 06 | Home & grid | `library_screen`, `asset_grid*`, `photo_grid_*`, `date_scrubber`, `detail_screen`, motion/video | ☑ |
| 07 | Other screens | rest of `lib/viewer/` | ☑ |
| 08 | Settings, app shell, l10n | `lib/settings/`, `lib/demo/`, `app.dart`, `main.dart`, `lib/l10n/` | ☑ |
| 09 | Cross-cutting audit | repo rules, size budget, deps, test gaps | ☑ |
| 10 | Synthesis | `docs/review/REPORT.md`: top issues, fix order | ☑ |

### 01 Storage
- Schema + every migration path (fresh install vs upgrade from each version); `onCreate` and `onUpgrade` agree.
- Indexes vs every `where:` used in hot paths; full-table scans in loops.
- `listAll` cache: `updated_at` high-water mark, same-ms writes, deletes (does a removed row leave the cache?).
- Transactions: multi-statement writes that can half-apply on kill.
- Path rebasing (`rebaseContainerPath`, `_healed`) after container UUID change.
- Change log trigger + prune: growth, cost.
- `bucket_object` replace/forget: concurrency with readers.

### 02 Upload & bucket
- Every delete path (`_deleteObject`, pending deletes, leftovers, old copies): can it remove the only copy of a photo? Cross-check the Oct 13 loss (~304 originals deleted from the bucket).
- `BucketFlags.detect` vs each `BucketFixer` precondition: detector and fixer must agree, or the item is re-offered forever.
- Listing refresh: partial/failed listings, multiple targets, prefixes.
- Sync engine/queue: resume after kill, duplicate jobs, paused state, retries, hidden photos never queued.
- Background transfer only; no Dart HTTP for bodies.
- Etag/inspect caches: invalidation by key+size.

### 03 Vault & backup
- Crypto: key derivation, nonce reuse, passcode hashing, constant-time compare.
- Hidden/private albums: anything leaking names, dates, thumbnails, counts outside the gate (logs, queue rows, bucket keys, app switcher).
- iCloud/bucket app-data backup + restore: fresh-install detection, overwrite risk, partial restore.
- Daily copy, decoy dates, redate/undo.

### 04 Library sync & storage fixes
- `PhotoLibraryService`: syncAll/syncRecent/applyChange races; `_reconcileDeletions` false positives (limited access, paging shifts).
- `AssetRemoval`, `LibraryCustody`: any path deleting a non-backed-up original.
- `StorageOptimizer` swaps: declined prompt, kill mid-swap, pending swaps file.
- `StorageAdvisor` cache coherence; `FixQueue` resolved/failed state persistence; `RecordFixer` heuristics (time/print thresholds) false positives.
- Flagged Items flicker/re-offer issues found Oct 14 (session notes): confirm and propose a single-scan design.

### 05 Analysis, faces, people
- Model loading cost, isolate use, memory per image.
- Face grouping thresholds, identity merge/split correctness, person store memberships.
- AI vendor calls: what leaves the phone, keys handling, hidden photos excluded.
- Analyze queue pacing, pause, battery.

### 06 Home & grid
- `reload()` cost per call and call frequency; derived lists computed once.
- Grid layout memoisation, scroll anchoring (new: home rests on Albums), pins during scan growth.
- Thumbnail loading: cache, decode off main isolate, cancellation on fast scroll.
- Detail viewer: memory for large images, video/live photo lifecycle, disposal.
- Every `build` for O(library) work, sync I/O, `setState` storms.

### 07 Other screens
- Flagged Items/actions, people/person pages, albums, private album screens, recently deleted, favorites, pickers.
- Same perf rules; destructive actions confirmed and safe by default; navigation state after deletes.

### 08 Settings, app shell, l10n
- Settings persistence, secure storage of credentials, S3 config validation.
- App startup path: work before first frame.
- l10n: keys missing in `zh`, unused keys, hard-coded strings.

### 09 Cross-cutting
- Grep audits for each repo rule; list violations without a call-site justification.
- `pubspec.yaml` deps: each one's size/need; candidates to drop.
- Size budget risks; obfuscation flags in scripts.
- Test gaps: risky code (deletes, crypto, migrations) without tests.

### 10 Synthesis
- Merge findings, dedupe, rank; top 10 to fix first with effort estimates.

## Progress checks

Hourly: Mac load, step status above, findings counts, next steps started if load allows.
