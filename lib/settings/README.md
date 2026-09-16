# settings

Configuring where photos back up to: S3 credentials/bucket/prefix, held in
platform secure storage (Keychain/Keystore), plus a draft of any in-progress
attempt so a failed or abandoned add doesn't mean retyping everything.

```text
SettingsScreen "+"                                    settings_screen.dart
  ▼
AddS3BackupScreen                                     add_s3_backup_screen.dart
  │ loads drafts: S3TargetDraftsStore.loadAll()        s3_target_drafts_store.dart
  │ paste a credentials block ──► fills the fields     s3_credentials_text.dart
  ▼ user fills form, taps Save
  │ saves this attempt as a draft first                s3_target_drafts_store.dart:save()
  ▼
detectRegion(bucket)                                  s3_region_detection.dart
  │ unsigned HEAD; reads x-amz-bucket-region header
  ├─ fail ──► show error, stop
  ▼ ok
checkAccess(accessKeyId, secretAccessKey, region, bucket)   s3_connectivity.dart
  │ signed ListObjectsV2 (max-keys=1) — needs s3:ListBucket
  ├─ forbidden / notFound / networkError ──► show error, stop
  ▼ ok
BackupTargetsStore.addS3(...)                         backup_targets_store.dart
  │ persists S3BackupTarget                            s3_backup_target.dart
  ▼
S3TargetDraftsStore.removeMatching(...)  — draft graduated, drop it
  ▼
pop(true) ──► SettingsScreen reloads target list

SettingsScreen (tap a target row)                     settings_screen.dart
  ▼
BucketBrowserScreen(target, prefix: target.prefix)    bucket_browser_screen.dart
  │ listBucket(target, prefix)                         s3_listing.dart
  │ signed ListObjectsV2, delimiter=/ — folders come back as CommonPrefixes
  ▼
folders ──► tap ──► push BucketBrowserScreen(prefix: folder)  (drill down)
objects ──► shown with size; "Load More" pages via nextToken
```

Both `backup_targets_store.dart` and `s3_target_drafts_store.dart` sit on the
same `secure_store.dart` (`SecureStore` abstraction over
`flutter_secure_storage`, swappable in tests).

- `s3_backup_target.dart` / `s3_target_draft.dart` — the two persisted models.
- `s3_connectivity.dart` / `s3_region_detection.dart` — the two unauthenticated
  and authenticated network checks run before a target is ever saved.
- `s3_listing.dart` — paginated `ListObjectsV2` for `bucket_browser_screen.dart`,
  same signing approach as `s3_connectivity.dart`.
- `s3_credentials_text.dart` — parses a pasted block (`name: value`,
  `NAME=value`, JSON-ish, `s3://bucket/prefix/`) into the four form fields, so
  credentials are never retyped by hand.
