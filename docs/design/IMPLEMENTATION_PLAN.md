# Photo Backup App — Implementation Plan

## Phase 1: Foundation & Settings
Everything else needs credentials and a place to record upload state — build these first.

- [x] T1.1 Project scaffold (Flutter app, iOS focus, Android backlog) — see `lib/` — depends: none
- [x] T1.2 i18n scaffold: `flutter_localizations` + `intl` + `flutter gen-l10n`, English + Mandarin (Simplified) ARB files, all placeholder screens wired through `AppLocalizations` — see `lib/l10n/` — depends: T1.1
- [x] T1.3 Settings: list of `S3BackupTarget`s in `flutter_secure_storage` (multiple buckets supported), "Add S3 Backup" screen with delete/confirm on the list — see `lib/settings/` — depends: T1.1
- [x] T1.4 S3 connectivity check (`HEAD` bucket, signed with `aws_signature_v4`) run before a new target is saved, inline error on failure (forbidden/not-found/network) — see `lib/settings/s3_connectivity.dart` — depends: T1.3
- [x] T1.5 SQLite schema (`sqflite`): `asset_record` (localId, contentHash, per-derivative upload state + destination key, platform, timestamps) — see `lib/storage/` — depends: T1.1
- [x] ~~T1.6 Generalize the settings store to a sealed `BackupTarget` list (`S3BackupTarget | LocalFolderBackupTarget`) instead of S3-only~~ — **dropped and reverted**: app is S3-only by decision (see design doc's "Backup destination scope" option) — depends: T1.3
- [x] ~~T1.7 `LocalFolderBackupTarget` add flow~~ — **dropped**: non-S3 destinations are out of scope; those already have official apps — depends: T1.6
- [x] ~~T1.8 Bookmark resolution + re-pick recovery~~ — **dropped** along with T1.7 — depends: T1.7

## Phase 2: Photo Processing Pipeline
Turns raw `photo_manager` assets into the derivatives the upload engine will send. Depends on the SQLite schema to record what's been processed.

- [ ] T2.1 `photo_manager` enumeration + permission flow (iOS PHPhotoLibrary) for incremental new/changed asset detection — see `lib/photos/photo_library_service.dart` — depends: T1.5. **Partial**: permission request + full-library metadata sync (id/created date/is-video, no file/thumbnail bytes touched) into `asset_record` as `photoManager` records, wired into `LibraryScreen`'s grid and backup pipeline (`fileFor` resolves the actual file on demand, downloading from iCloud if needed). Still todo: incremental (changed-only) detection — today it's a full re-list on every launch, deduped by `upsert`'s no-op-if-tracked check, not a true delta query.
- [ ] T2.2 Image derivative generator: thumbnail + medium + original passthrough via the `image` package — see `lib/photos/image_pipeline.dart` — depends: T2.1
- [ ] T2.3 Video derivative generator: poster-frame thumbnail via `video_thumbnail`, original file passthrough — see `lib/photos/video_pipeline.dart` — depends: T2.1
- [ ] T2.4 Live Photo / burst / iCloud-only-asset handling — see `docs/design/photo-backup-app-t2.4.md` — depends: T2.2, T2.3
- [ ] T2.5 Manual add flow: multi-select files via `file_picker` (Files app / iCloud Drive) — done, see `lib/photos/manual_add.dart`; still needs the photos/videos-via-`photo_manager`'s-picker half once T2.1 lands — depends: T1.5, T2.1
- [ ] T2.6 iOS Share Extension: accept photos/videos/files shared from other apps via the Share Sheet (native `Runner` extension target + `receive_sharing_intent`), enqueued into the same pipeline as T2.5 — see `ios/ShareExtension/`, `lib/photos/share_intent.dart` — depends: T2.5

## Phase 3: Upload Engine
Moves derivatives to S3. Needs Settings (creds) from Phase 1 and derivatives to upload from Phase 2.

- [x] T3.1 On-device SigV4 presigned-URL signer via `aws_signature_v4` (single-part PUT) — see `lib/upload/signing.dart` — depends: T1.3
- [x] T3.2 S3 upload on `background_downloader` (prefix-based key layout) — see `lib/upload/s3_uploader.dart`, `lib/upload/backup_coordinator.dart` (fans a derivative out to every configured S3 target); retry/backoff still lands in T3.4 — depends: T3.1, T2.2, T2.3
- [ ] T3.3 Multipart upload flow for large files (per-part presign, ETag tracking, complete-multipart) — see `lib/upload/multipart.dart` — depends: T3.1
- [ ] T3.4 Retry/backoff + periodic background scheduling (`background_downloader`'s native iOS queue) to resume pending uploads — see `lib/upload/scheduler.dart` — depends: T3.2, T3.3
- [x] ~~T3.5 Local-folder writer~~ — **dropped** along with the local-folder target type (see T1.7) — depends: T1.7, T2.2, T2.3

## Phase 4: Viewer UI
The user-facing payoff — browsing what's backed up. Needs derivative files (Phase 2) and live upload status (Phase 3) for badges.

- [ ] T4.1 Photo grid (camera roll) with backup-status badges, thumbnail-first progressive loading — see `lib/viewer/library_screen.dart` — depends: T2.2, T3.2. **Visual shell done**: real Photos-app-style single-page IA (one scrollable page, no bottom tab bar — day-grouped square grid up top, then Collections (Albums/People/Places/Events) + Media Types + Utilities grouped lists), swipe viewer, long-press context menu for Favorite/Hide/Delete. Favorites/Hidden/Recently Deleted are real (`lib/viewer/favorites_screen.dart`, `hidden_screen.dart`, `recently_deleted_screen.dart`, soft-delete + restore on `asset_record`) — the grid now also lists real camera-roll assets synced in via `photo_manager` (T2.1), alongside manually-added files, with thumbnails loaded on demand (`PhotoManagerThumbnail`); video tiles are still a placeholder icon, not an extracted frame (needs T2.2/T2.3). Albums are real; People/Places/Events are placeholder rows (see T4.4).
- [ ] T4.2 Detail viewer: thumbnail → medium → original progressive load, video playback (`video_player`) — see `lib/viewer/detail_screen.dart` — depends: T2.2, T2.3. **Visual shell done**: swipeable full-screen viewer with Photos-style bottom bar (share/favorite are inert stubs, info/delete are real) opening the original file directly — progressive load needs the derivative pipeline.
- [ ] T4.3 Backup dashboard: queued/uploading/done/failed counts, storage used per tier — see `lib/viewer/backup_screen.dart` — depends: T3.4. **Partial**: real per-status counts from `asset_record` already shown; storage-used-per-tier still pending.
- [ ] T4.4 AI-recognized People/Events smart collections via OpenAI (opt-in, user-supplied API key) — see `lib/photos/ai_vision_service.dart`, `lib/photos/ai_analysis_store.dart`, `lib/viewer/smart_collection_screen.dart` — depends: T4.1. **Partial**: People/Events rows now open a real screen that calls OpenAI (`gpt-4o-mini` vision) per unanalyzed photo on an opt-in "Analyze" tap, caches `{people_count, event_label}` in a local `ai_analysis` table, and groups by people-count/event label. Only `manualFile`-sourced assets (manual add, demo photos) are analyzable — `photoManager` assets need T2.1's on-demand resolution first. No cross-photo identity clustering ("this is the same person as that photo") — grouping is by count/label only. Places (GPS-based, no AI/API key needed) still stubbed pending EXIF location extraction.

## Phase 5: Reliability & Polish
Hardens the app against the real-world edge cases identified in the design doc's risks. Comes last because it needs the full pipeline (Phases 2-4) working end-to-end to test against.

- [ ] T5.1 Glacier/Deep Archive restore handling: detect `InvalidObjectState`, trigger `RestoreObject`, poll, show "restoring" UI — see `lib/viewer/detail_screen.dart` — depends: T4.2
- [ ] T5.2 Cellular vs Wi-Fi-only upload setting, low-battery guards — see `lib/upload/scheduler.dart` — depends: T3.4
- [ ] T5.3 IAM least-privilege policy + example S3 Lifecycle Rule JSON (Standard→IA→Glacier by prefix), delivered as README docs — see `docs/aws-setup.md` — depends: none
- [ ] T5.4 On-device testing: real iPhone (not just simulator) for background-upload reliability — see `docs/design/photo-backup-app-t5.4.md` — depends: T3.4

## Phase 6: Private Albums
Passcode-gated hidden space in Utilities. Needs the asset store (Phase 1) and the shared grid (T4.1).

- [x] T6.1 `private_album` table (id = passcode hash, createdAt) + a `private_album_asset` join table (mirrors `album_store.dart`, `moved` flag distinguishes move-hides-from-library vs copy-stays-visible) — see `lib/storage/private_album_store.dart` — depends: T1.5. **Built as a join table, not a nullable FK column**: keeps "move" vs "copy" from ever needing a duplicate `asset_record` row (which would've broken `photo_manager` id resolution for copies) and lets "Delete Album" just un-hide moved-in assets rather than destroy anything — see DESIGN.md.
- [x] T6.2 Passcode sheet (4-digit entry, "Enter" / "Create New") on the existing Utilities "Hidden" row — hashed-code lookup, no distinct wrong-passcode state (see DESIGN.md) — see `lib/viewer/private_album_gate.dart` — depends: T6.1. Also reused by every grid's long-press "Hide" action, replacing the old plain-`isHidden`-toggle.
- [x] T6.3 Private album screen: reuses `assetGridSlivers()`, header shows item count + total size (best-effort: only files already resolvable on disk, no forced iCloud fetch), "..." menu for Move/Copy from Library and "Delete Album" (confirm sheet; un-hides moved-in assets, deletes nothing) — see `lib/viewer/private_album_screen.dart` — depends: T6.2, T4.1
- [x] T6.4 Move/copy-from-library picker into a private album, via the shared `AssetPickerScreen` (multi-select grid, also used by T7.3's "Add Photos") — see `lib/viewer/asset_picker_screen.dart` — depends: T6.3

## Phase 7: People Profiles & Relationship Graph
Grows T4.4's count-only People grouping into per-person identity + a full profile. Needs T4.4's AI analysis plumbing.

- [x] T7.1 `Person` identity: manual "+ Add Person" + "Add Photos" tagging flow (`PeopleScreen`/`PersonPageScreen`), not seeded from per-photo AI analysis — see `lib/photos/person_store.dart` — depends: T4.4. **Scope note**: on-device face-clustering / AI-seeded identity is still the stretch goal noted in DESIGN.md; today's People screen and the older AI people-*count* grouping (`SmartCollectionScreen`) coexist, linked via a "Find People with AI Analysis" row.
- [x] T7.2 `Person` model/store: name, profile photo, bio fields (education/job/family/relatives), locked flag + passcode hash + hint — see `lib/photos/person.dart`, `lib/photos/person_store.dart` — depends: T7.1
- [x] T7.3 `PersonPageScreen` (avatar/name + chevron + tagged-photo grid) and `PersonProfileScreen` (editable bio sections) — chevron-from-name entry point off the People grid — see `lib/viewer/person_page_screen.dart`, `lib/viewer/person_profile_screen.dart` — depends: T7.2. **AI-assisted auto-fill not built**: bio fields are blank until the user fills them in; DESIGN.md's "suggestion-only" auto-fill from AI vision is still open.
- [x] T7.4 Profile lock: set passcode + hint, locked profile hides bio/relationships/location fields until unlocked (photos stay visible — see DESIGN.md risk note) — see `lib/viewer/person_profile_screen.dart`, `lib/viewer/passcode_prompt.dart` — depends: T7.3
- [x] T7.5 Relationship links: person↔person edges with a type (family/spouse/parent-child/sibling/friend/colleague/other), stored mirrored both directions, "link to existing person" picker from a profile — see `lib/photos/person_store.dart` (`addRelationship`/`relationshipsFor`) — depends: T7.2
- [x] T7.6 Relationship net graph screen: hand-rolled `CustomPainter` node-link layout (not the `graphview` package originally considered — union-find clusters family-type edges into a circle per cluster, no force-directed math needed for this scale), other relation types styled by line color — see `lib/viewer/person_graph_screen.dart` — depends: T7.5
- [x] T7.7 Geolocation movement history: origin + relocation entries (place + date), editable, explicitly excludes trips/travel — see `lib/photos/person_store.dart` (`addLocation`/`locationsFor`) — depends: T7.3. **Manual entry only**: not yet clustered from photo EXIF GPS — still depends on Places' EXIF extraction (T4.4's stub).

Demo data for both features (so they're immediately explorable, not just implemented): `DemoAssetsService.addAll()` now also seeds a demo Private Album at passcode `1234` (3 photos moved in, 1 copied in) and three demo `Person` profiles with bios, tagged photos, a friend + a family relationship, and one location history — all idempotent/reset-safe like the existing demo albums. See `lib/photos/demo_assets_service.dart`.

## Backlog: Library zoom

Pinch to change grid density, the way real Photos does — designed in
UIUX-DESIGN.md ("Library zoom"), not built. The app has one density (4
across, day sections); this adds three more and two new groupings.

- [ ] TZ.1 `PhotoGridLayout` takes a `crossAxisCount` and a sectioning
      strategy (day/month/year) instead of assuming 4-across days — see
      `lib/viewer/photo_grid_layout.dart` — depends: nothing
- [ ] TZ.2 Pinch handling on `AssetGridView`: one level per pinch past a
      threshold, tiles scaling smoothly within a level, viewport pinned on
      the top photo across the change (reuses `_viewportPin`) — depends:
      TZ.1
- [ ] TZ.3 Cheap tiles for dense levels: no badges, no context menu, and
      thumbnails decoded at a smaller `cacheWidth` — a year view of 20,000
      photos must not decode 20,000 full-size thumbnails — depends: TZ.1
- [ ] TZ.4 `Years · Months · All` pill: appears on pinch and when scrolling
      stops, fades while scrolling, taps change level — depends: TZ.2
- [ ] TZ.5 Date scrubber labels follow the level (days → months → years) —
      see `lib/viewer/date_scrubber.dart` — depends: TZ.1

## Backlog: Android
Deferred until iOS is solid. The Flutter codebase already builds for Android (`android/` scaffold exists); these are the tasks to pick up when Android gets prioritized, not new platform work.

- [ ] TA.1 Re-verify `photo_manager` permission flow on Android scoped storage (API 29+) — depends: T2.1
- [ ] TA.2 Verify `background_downloader` upload reliability under Android's WorkManager, including manufacturer battery-optimization opt-out prompts (Xiaomi/Huawei/OnePlus) — depends: T3.4
- [ ] TA.3 On-device testing matrix across real Android devices/OEMs — depends: TA.2
- [ ] TA.4 Play Store release setup (signing, listing, `android/app/build.gradle.kts` release config) — depends: TA.3
