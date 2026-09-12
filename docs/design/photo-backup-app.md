# Photo Backup App

## Problem
Photo apps like Google Photos/iCloud lock the user's photos into a vendor's storage and pricing. Need an iOS + Android app that backs up the camera roll to a bucket the user owns and controls, while still browsing/viewing as fast as a native gallery.

## Goals
- Auto-backup new/changed Photos/Videos to user's own S3 bucket, incrementally.
- Single codebase covering both iOS and Android.
- AWS credentials (access key, secret, region, bucket, prefix) entered once in Settings, stored securely.
- Generate thumbnail + medium + original derivatives on-device before upload.
- Upload each derivative to a distinct S3 prefix so the user's own bucket Lifecycle Rules (Standard/IA/Glacier/…) can tier each class independently — app never manages tiering itself.
- In-app viewer: thumbnail-first grid, progressive load to full res on open.
- Survive backgrounding/app kill/network loss; resumable uploads for large videos, on both platforms.

## Non-goals (v1)
- Multi-device sync / shared library.
- Managing S3 Lifecycle Rules from inside the app (user configures these directly in AWS).
- Web/desktop platforms (mobile only).
- Deleting local originals after backup to reclaim device storage (candidate for later phase).
- Multi-resolution video transcoding (poster-frame thumbnail + original only, in v1).
- STS/Cognito temporary credentials — static IAM user keys only (single-user personal app, no backend to broker tokens).

## Options considered
- **Platform**: native Swift+Kotlin (two codebases) vs React Native/Expo vs Flutter/Dart → Flutter wins: one Dart codebase for both platforms, and `flutter run` produces a real compiled native app on both from day one — no sandboxed dev runtime (unlike Expo Go) standing between the app and native background-transfer APIs.
- **AWS access**: full AWS SDK vs on-device SigV4 presigned URLs + a native background-transfer package → presigned URLs win, same reasoning as any mobile client: keeps the bundle light and lets uploads run through a package that wraps native `URLSession`/`WorkManager` transfer instead of the SDK's own HTTP stack.
- **Background transfer package**: hand-rolled platform channels vs `background_downloader` (pub.dev) → `background_downloader` wraps native `URLSessionUploadTask` (iOS) and `WorkManager` (Android) for resumable, backgrounded uploads out of the box — avoids writing and maintaining two sets of platform channel code.
- **SigV4 signing**: hand-rolled HMAC-SHA256 vs the `aws_signature_v4` package (pub.dev, from the AWS SDK for Dart family) → use the package: it's maintained by AWS, removes the "fiddly to get right" risk a hand-rolled signer would carry.
- **Large file transfer**: single PUT vs S3 multipart → multipart above a size threshold: resumability over cellular, each part as its own `background_downloader` upload task.
- **State/metadata store**: local SQLite (`sqflite`) vs S3-hosted manifest → local SQLite: v1 is single-device, no cross-device merge needed; S3 only holds asset bytes (+ optional per-asset JSON sidecar for future multi-device use).
- **Storage-class control**: 100% lifecycle-rule-driven vs app sets `x-amz-storage-class` at upload → app supports an optional per-tier default storage-class override in Settings (falls back to STANDARD), lifecycle rules still own time-based transitions after that — avoids paying Standard rates for originals until the first nightly lifecycle evaluation.

## Decision
Flutter app targeting iOS + Android from one codebase. `photo_manager` enumerates the camera roll on both platforms; a local pipeline (`image` package + `video_thumbnail`) generates {thumbnail, medium, original-passthrough} derivatives; each derivative is PUT via a presigned URL (signed with `aws_signature_v4`) through `background_downloader` upload tasks (multipart for large files), landing under prefix-separated S3 keys (`thumbnails/`, `medium/`, `originals/`) so the user's own bucket Lifecycle Rules do all tiering. Credentials live in `flutter_secure_storage` (Keychain on iOS, Keystore on Android) only. Upload/dedup state lives in local `sqflite`.

## Risks / open questions
- If a lifecycle rule has already moved an original to Glacier/Deep Archive, viewing it requires a `RestoreObject` call and a multi-hour wait — app must detect `InvalidObjectState` and show "restoring", not fail silently.
- Background execution still differs by platform even with a native transfer package: iOS keeps its own throttling (BGTaskScheduler budget), and Android's WorkManager can be killed early by aggressive manufacturer battery-optimization (Xiaomi/Huawei/OnePlus) — needs on-device testing on both, not just simulators/emulators.
- `photo_manager` exposes less low-level resource detail than PhotoKit/MediaStore directly — Live Photos, bursts, and iCloud-only (optimized/not-downloaded) assets need explicit verification per platform.
- Static long-lived IAM keys stored on a phone is an accepted risk for a single-user app with no backend — mitigated only by secure-storage + a least-privilege IAM policy scoped to one bucket/prefix.
- Android scoped-storage rules (API 29+) may limit which media the app can enumerate/write without the user granting broader access — needs explicit permission-flow testing on a real Android version matrix.
