# Photo Backup App — Implementation Plan

## Phase 1: Foundation & Settings
Everything else needs credentials and a place to record upload state — build these first.

- [x] T1.1 Project scaffold (Flutter app, iOS focus, Android backlog) — see `lib/` — depends: none
- [x] T1.2 i18n scaffold: `flutter_localizations` + `intl` + `flutter gen-l10n`, English + Mandarin (Simplified) ARB files, all placeholder screens wired through `AppLocalizations` — see `lib/l10n/` — depends: T1.1
- [x] T1.3 Settings: list of `S3BackupTarget`s in `flutter_secure_storage` (multiple buckets supported), "Add S3 Backup" screen with delete/confirm on the list — see `lib/settings/` — depends: T1.1
- [x] T1.4 S3 connectivity check (`HEAD` bucket, signed with `aws_signature_v4`) run before a new target is saved, inline error on failure (forbidden/not-found/network) — see `lib/settings/s3_connectivity.dart` — depends: T1.3
- [x] T1.5 SQLite schema (`sqflite`): `asset_record` (localId, contentHash, per-derivative upload state + destination key, platform, timestamps) — see `lib/storage/` — depends: T1.1
- [x] T1.6 Generalize the settings store to a sealed `BackupTarget` list (`S3BackupTarget | LocalFolderBackupTarget`) instead of S3-only; list screen renders both kinds — see `lib/settings/` — depends: T1.3
- [x] T1.7 `LocalFolderBackupTarget` add flow: native folder picker (`file_picker`'s directory picker) resolved to a persisted security-scoped bookmark, add-button offers an S3-vs-iCloud-Folder type choice, "Add iCloud Folder Backup" screen verifies the folder opens before saving (mirrors T1.4's validate-first shape) — see `lib/settings/` — depends: T1.6
- [x] T1.8 Bookmark resolution + re-pick recovery: detect a stale/revoked security-scoped bookmark and prompt the user to re-authorize instead of failing silently — see `lib/settings/` — depends: T1.7

## Phase 2: Photo Processing Pipeline
Turns raw `photo_manager` assets into the derivatives the upload engine will send. Depends on the SQLite schema to record what's been processed.

- [ ] T2.1 `photo_manager` enumeration + permission flow (iOS PHPhotoLibrary) for incremental new/changed asset detection — see `lib/photos/` — depends: T1.5
- [ ] T2.2 Image derivative generator: thumbnail + medium + original passthrough via the `image` package — see `lib/photos/image_pipeline.dart` — depends: T2.1
- [ ] T2.3 Video derivative generator: poster-frame thumbnail via `video_thumbnail`, original file passthrough — see `lib/photos/video_pipeline.dart` — depends: T2.1
- [ ] T2.4 Live Photo / burst / iCloud-only-asset handling — see `docs/design/photo-backup-app-t2.4.md` — depends: T2.2, T2.3
- [ ] T2.5 Manual add flow: multi-select files via `file_picker` (Files app / iCloud Drive) — done, see `lib/photos/manual_add.dart`; still needs the photos/videos-via-`photo_manager`'s-picker half once T2.1 lands — depends: T1.5, T2.1
- [ ] T2.6 iOS Share Extension: accept photos/videos/files shared from other apps via the Share Sheet (native `Runner` extension target + `receive_sharing_intent`), enqueued into the same pipeline as T2.5 — see `ios/ShareExtension/`, `lib/photos/share_intent.dart` — depends: T2.5

## Phase 3: Upload Engine
Moves derivatives to S3. Needs Settings (creds) from Phase 1 and derivatives to upload from Phase 2.

- [x] T3.1 On-device SigV4 presigned-URL signer via `aws_signature_v4` (single-part PUT) — see `lib/upload/signing.dart` — depends: T1.3
- [x] T3.2 S3 upload on `background_downloader` (prefix-based key layout) — see `lib/upload/s3_uploader.dart`, `lib/upload/backup_coordinator.dart` (fans a derivative out to every configured target); retry/backoff still lands in T3.4 — depends: T3.1, T2.2, T2.3
- [ ] T3.3 Multipart upload flow for large files (per-part presign, ETag tracking, complete-multipart) — see `lib/upload/multipart.dart` — depends: T3.1
- [ ] T3.4 Retry/backoff + periodic background scheduling (`background_downloader`'s native iOS queue) to resume pending uploads — see `lib/upload/scheduler.dart` — depends: T3.2, T3.3
- [x] T3.5 Local-folder writer: writes derivatives directly into a `LocalFolderBackupTarget`'s bookmarked folder under the same prefix layout as S3, no network — resolves/starts the security-scoped bookmark per write — see `lib/upload/local_folder_writer.dart` — depends: T1.7, T2.2, T2.3

## Phase 4: Viewer UI
The user-facing payoff — browsing what's backed up. Needs derivative files (Phase 2) and live upload status (Phase 3) for badges.

- [ ] T4.1 Photo grid (camera roll) with backup-status badges, thumbnail-first progressive loading — see `lib/viewer/library_screen.dart` — depends: T2.2, T3.2
- [ ] T4.2 Detail viewer: thumbnail → medium → original progressive load, video playback (`video_player`) — see `lib/viewer/detail_screen.dart` — depends: T2.2, T2.3
- [ ] T4.3 Backup dashboard: queued/uploading/done/failed counts, storage used per tier — see `lib/viewer/backup_screen.dart` — depends: T3.4

## Phase 5: Reliability & Polish
Hardens the app against the real-world edge cases identified in the design doc's risks. Comes last because it needs the full pipeline (Phases 2-4) working end-to-end to test against.

- [ ] T5.1 Glacier/Deep Archive restore handling: detect `InvalidObjectState`, trigger `RestoreObject`, poll, show "restoring" UI — see `lib/viewer/detail_screen.dart` — depends: T4.2
- [ ] T5.2 Cellular vs Wi-Fi-only upload setting, low-battery guards — see `lib/upload/scheduler.dart` — depends: T3.4
- [ ] T5.3 IAM least-privilege policy + example S3 Lifecycle Rule JSON (Standard→IA→Glacier by prefix), delivered as README docs — see `docs/aws-setup.md` — depends: none
- [ ] T5.4 On-device testing: real iPhone (not just simulator) for background-upload reliability — see `docs/design/photo-backup-app-t5.4.md` — depends: T3.4

## Backlog: Android
Deferred until iOS is solid. The Flutter codebase already builds for Android (`android/` scaffold exists); these are the tasks to pick up when Android gets prioritized, not new platform work.

- [ ] TA.1 Re-verify `photo_manager` permission flow on Android scoped storage (API 29+) — depends: T2.1
- [ ] TA.2 Verify `background_downloader` upload reliability under Android's WorkManager, including manufacturer battery-optimization opt-out prompts (Xiaomi/Huawei/OnePlus) — depends: T3.4
- [ ] TA.3 On-device testing matrix across real Android devices/OEMs — depends: TA.2
- [ ] TA.4 Play Store release setup (signing, listing, `android/app/build.gradle.kts` release config) — depends: TA.3
