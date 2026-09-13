# settings

Configuring where photos back up to: S3 credentials/bucket/prefix, held in
platform secure storage (Keychain/Keystore), plus a draft of any in-progress
attempt so a failed or abandoned add doesn't mean retyping everything.

```text
SettingsScreen "+"                                    settings_screen.dart
  ▼
AddS3BackupScreen                                     add_s3_backup_screen.dart
  │ loads drafts: S3TargetDraftsStore.loadAll()        s3_target_drafts_store.dart
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
```

Both `backup_targets_store.dart` and `s3_target_drafts_store.dart` sit on the
same `secure_store.dart` (`SecureStore` abstraction over
`flutter_secure_storage`, swappable in tests).

- `s3_backup_target.dart` / `s3_target_draft.dart` — the two persisted models.
- `s3_connectivity.dart` / `s3_region_detection.dart` — the two unauthenticated
  and authenticated network checks run before a target is ever saved.
