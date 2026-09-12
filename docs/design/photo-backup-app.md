# Photo Backup App

## Problem
Photo apps like Google Photos/iCloud lock the user's photos into a vendor's storage and pricing. Need an iPhone app that backs up the camera roll to a bucket the user owns and controls, while still browsing/viewing as fast as a native gallery. Android is on the roadmap but backlogged — see Non-goals.

## Goals
- Auto-backup new/changed Photos/Videos to a destination the user owns, incrementally. iOS first.
- Manual backup too, not just auto-detected camera-roll assets: pick files from the Files app, pick specific photos/videos, or receive a file shared from another app via the Share Sheet — all enqueued into the same pipeline.
- Support multiple configured backup targets, each validated for real access before being saved:
  - **S3**: bucket + credentials + prefix.
  - **Local iCloud Drive folder**: no AWS account needed — lets someone back up before/without ever setting up S3.
- Generate thumbnail + medium + original derivatives on-device before upload.
- Upload each derivative under a distinct, clearly separate S3 key prefix (`thumbnails/`, `medium/`, `originals/`) so the user's own bucket Lifecycle Rules can target each class independently — storage class/tiering is entirely the bucket owner's concern, set up outside the app; the app's only job is the clean prefix split.
- In-app viewer: thumbnail-first grid, progressive load to full res on open.
- Survive backgrounding/app kill/network loss; resumable uploads for large videos.
- i18n from the start: every user-facing string goes through the localization layer, not hardcoded — English and Mandarin (Simplified) supported now, more locales just add an ARB file later.

## Non-goals (v1)
- **Android build/test/release — backlog, not abandoned.** The Flutter codebase already runs on Android (scaffold builds for both), but Android-specific verification, permission-flow testing, and Play Store release are deferred until iOS is solid.
- Multi-device sync / shared library.
- Managing S3 Lifecycle Rules from inside the app (user configures these directly in AWS).
- Web/desktop platforms (mobile only).
- Deleting local originals after backup to reclaim device storage (candidate for later phase).
- Multi-resolution video transcoding (poster-frame thumbnail + original only, in v1).
- STS/Cognito temporary credentials — static IAM user keys only (single-user personal app, no backend to broker tokens).

## Options considered
- **Platform**: native Swift+Kotlin (two codebases) vs React Native/Expo vs Flutter/Dart → Flutter wins: one Dart codebase, and `flutter run` produces a real compiled native app from day one — no sandboxed dev runtime (unlike Expo Go) standing between the app and native background-transfer APIs. Kept even though Android is now backlogged: it costs nothing to build iOS-only for now on a codebase that's already Android-ready, versus committing to a native Swift rewrite if/when Android gets prioritized.
- **AWS access**: full AWS SDK vs on-device SigV4 presigned URLs + a native background-transfer package → presigned URLs win, same reasoning as any mobile client: keeps the bundle light and lets uploads run through a package that wraps native `URLSession`/`WorkManager` transfer instead of the SDK's own HTTP stack.
- **Background transfer package**: hand-rolled platform channels vs `background_downloader` (pub.dev) → `background_downloader` wraps native `URLSessionUploadTask` (iOS) and `WorkManager` (Android) for resumable, backgrounded uploads out of the box — avoids writing and maintaining two sets of platform channel code.
- **SigV4 signing**: hand-rolled HMAC-SHA256 vs the `aws_signature_v4` package (pub.dev, from the AWS SDK for Dart family) → use the package: it's maintained by AWS, removes the "fiddly to get right" risk a hand-rolled signer would carry.
- **Large file transfer**: single PUT vs S3 multipart → multipart above a size threshold: resumability over cellular, each part as its own `background_downloader` upload task.
- **State/metadata store**: local SQLite (`sqflite`) vs S3-hosted manifest → local SQLite: v1 is single-device, no cross-device merge needed; S3 only holds asset bytes (+ optional per-asset JSON sidecar for future multi-device use).
- **Storage tiering**: app sets `x-amz-storage-class` at upload vs leaves it entirely to the bucket owner → entirely to the bucket owner. The app has no opinion on Standard/IA/Glacier — it just keeps derivatives under clearly separate prefixes; storage-class decisions belong to the S3 account owner's own Lifecycle Rules, configured outside the app.
- **Multiple buckets**: single configured bucket vs a list of backup targets → a list. Nothing about backup requires exactly one destination, and letting the config live as a list from the start avoids a later migration.
- **Non-S3 destination**: S3-only vs also support a local iCloud Drive folder → also support it. Requiring an AWS account before the app is useful at all is real onboarding friction; a folder target reuses the same list-of-targets model already decided above.
- **iCloud folder access**: app's own iCloud container (`path_provider`, automatic, but invisible to the user in Files/other apps) vs native folder picker (`UIDocumentPickerViewController` via `file_picker`) + persisted security-scoped bookmark → the picker. It lets the user point at any iCloud Drive folder they already use, matching how sandboxed iOS apps are meant to get durable access outside their own container.
- **Validating new backup targets**: save first vs validate access, then save → validate first. A signed `HEAD` request against the bucket (needs `s3:ListBucket`, the same permission actual backups will need) runs before the entry is persisted, so a typo'd bucket name or bad key never silently sits in the list.
- **i18n**: retrofit later vs wire it in at the scaffold stage → wire it in now, via Flutter's own `flutter_localizations` + `intl` + ARB files (`flutter gen-l10n`) rather than a third-party package — it's the framework-native approach, and retrofitting after screens exist means re-touching every hardcoded string later.

## Decision
Flutter app, developed and tested against **iOS first**; Android stays buildable from the same codebase but is backlog for verification/release. Settings holds a **list** of `BackupTarget`s in `flutter_secure_storage` — a sealed type with two variants today:
- `S3BackupTarget` (accessKeyId, secretAccessKey, region, bucket, prefix). "Add S3 Backup" runs a signed connectivity check (`aws_signature_v4` + `http`) against the entered bucket before saving — failures (forbidden/not-found/network) are shown inline and nothing is persisted until it passes.
- `LocalFolderBackupTarget` (display name, prefix, persisted security-scoped bookmark). "Add iCloud Folder Backup" opens the native folder picker (`file_picker`'s directory picker), resolves the picked folder to a security-scoped bookmark, and verifies it can actually be opened before saving — same "validate before persist" shape as the S3 flow.

`photo_manager` enumerates the camera roll; a manual add flow (`file_picker` for Files-app documents, `photo_manager`'s picker for specific photos/videos) and an iOS Share Extension (`receive_sharing_intent`, files shared in from other apps) feed the same queue for anything not auto-detected. A local pipeline (`image` package + `video_thumbnail`) generates {thumbnail, medium, original-passthrough} derivatives. Per target type, derivatives are delivered differently but land under the same prefix-separated key layout (`thumbnails/`, `medium/`, `originals/`): S3 targets get each derivative PUT via a presigned URL through `background_downloader` upload tasks (multipart for large files); local folder targets get each derivative written directly into the bookmarked folder (security scope started/stopped around the write, no network involved). The user's own S3 bucket Lifecycle Rules do all storage-class tiering — the app has no storage-class concept at all, and a local folder target has no tiering concept either. Upload/dedup state lives in local `sqflite`. All UI strings are routed through `AppLocalizations` (generated from `lib/l10n/app_{en,zh}.arb`) from the first screen onward — `en` and `zh` (Simplified) ship now.

## Risks / open questions
- If a lifecycle rule has already moved an original to Glacier/Deep Archive, viewing it requires a `RestoreObject` call and a multi-hour wait — app must detect `InvalidObjectState` and show "restoring", not fail silently.
- iOS background execution has its own throttling (BGTaskScheduler budget) even with a native transfer package — needs on-device testing, not just the simulator.
- `photo_manager` exposes less low-level resource detail than PhotoKit directly — Live Photos and bursts need explicit verification.
- Static long-lived IAM keys stored on a phone is an accepted risk for a single-user app with no backend — mitigated only by secure-storage + a least-privilege IAM policy scoped to one bucket/prefix.
- A security-scoped bookmark for a local folder target can go stale (user moves/renames/deletes the folder, or revokes access) — must detect resolution failure explicitly and prompt re-pick, not fail silently mid-backup.
- `file_picker`'s iOS directory picker + long-lived security-scoped bookmark persistence needs on-device verification before T1.7 is considered done — package behavior here isn't guaranteed by its docs alone.
- **Backlogged, revisit when Android is prioritized**: WorkManager can be killed early by aggressive manufacturer battery-optimization (Xiaomi/Huawei/OnePlus); Android scoped-storage rules (API 29+) may limit media access without extra permission flows. Neither blocks iOS-only work now.
- "Mandarin" was assumed to mean Simplified Chinese (`zh`, matching mainland China's writing system) rather than Traditional (`zh-Hant`, Taiwan/Hong Kong) — flag if Traditional was actually wanted, it's a one-ARB-file swap.
