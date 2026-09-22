# settings

Configuring where photos back up to: provider/credentials/bucket/prefix,
held in platform secure storage (Keychain/Keystore), plus a draft of any
in-progress attempt so a failed or abandoned add doesn't mean retyping
everything.

Three providers, one code path — AWS S3, Tencent COS and Alibaba Cloud OSS
all answer the S3 API with SigV4 (service `s3`), so only the hostname
differs and `bucket_endpoint.dart` is the only file that knows which:

```text
S3      <bucket>.s3.<region>.amazonaws.com       region detected from the bucket
COS     <bucket>.cos.<region>.myqcloud.com       bucket name carries the APPID
OSS     <bucket>.s3.oss-<region>.aliyuncs.com    `s3.` = the S3-compatible API
```

```text
SettingsScreen "+"                                    settings_screen.dart
  ▼
AddBackupScreen                                       add_backup_screen.dart
  │ loads drafts: S3TargetDraftsStore.loadAll()        s3_target_drafts_store.dart
  │ paste a credentials block ──► fills the fields     s3_credentials_text.dart
  │   an endpoint/console URL in it also sets provider + region
  ▼ user picks provider, fills form, taps Save
  │ saves this attempt as a draft first                s3_target_drafts_store.dart:save()
  ▼
S3 only ──► detectRegion(bucket)                      s3_region_detection.dart
  │ unsigned HEAD; reads x-amz-bucket-region header
  ├─ fail ──► show error, stop
COS/OSS ──► region picked (or typed) on the form      backup_storage_type.dart
  ▼ ok
checkAccess(accessKeyId, secretAccessKey, region, bucket, provider)
  │                                                   s3_connectivity.dart
  │ signed ListObjectsV2 (max-keys=1) — needs s3:ListBucket
  │ also where a wrong COS/OSS region shows up, as a 404
  ├─ forbidden / notFound / networkError ──► show error, stop
  ▼ ok
BackupTargetsStore.add(...)                           backup_targets_store.dart
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

Any photo's share sheet (library or hidden)           bucket_location.dart
  │ targetHolding(objectKey) — one-byte ranged GET per target
  ├─ Show in Bucket    ──► BucketBrowserScreen(prefix: the object's folder)
  └─ Open in Browser   ──► presigned GET (1 h) ──► the phone's own browser
```

Both `backup_targets_store.dart` and `s3_target_drafts_store.dart` sit on the
same `secure_store.dart` (`SecureStore` abstraction over
`flutter_secure_storage`, swappable in tests).

- `backup_storage_type.dart` — the provider list, each one's regions, and
  what a row calls it.
- `bucket_endpoint.dart` — host, request URI and signing region per
  provider; the only place a provider's hostname appears.
- `s3_backup_target.dart` / `s3_target_draft.dart` — the two persisted models.
- `s3_connectivity.dart` / `s3_region_detection.dart` — the two unauthenticated
  and authenticated network checks run before a target is ever saved.
- `s3_listing.dart` — paginated `ListObjectsV2` for `bucket_browser_screen.dart`,
  same signing approach as `s3_connectivity.dart`.
- `s3_credentials_text.dart` — parses a pasted block (`name: value`,
  `NAME=value`, JSON-ish, `s3://`/`cos://`/`oss://`, an endpoint URL,
  `SecretId`/`AccessKeySecret`, a COS `appid` to join onto the bucket name)
  into the form fields, so credentials are never retyped by hand.
