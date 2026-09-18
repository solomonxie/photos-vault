# Cloud Settings

`lib/settings/settings_screen.dart` — one flat page. Nothing here pushes a
sub-page that only holds controls: per-connection actions live in that row's
own sheet, and the queue opens over this page.

```
 ‹           Cloud Settings
 App Data
 Albums, people, tags, captions and places — everything that isn't the
 photo itself. One file, rewritten when it changes and pulled back
 automatically if you reinstall.
 ┌───┐ iCloud Drive                                        ─●
 │ ☁ │ Files → iCloud Drive → Bring Your Own Photos
 └───┘ Last copy 2 hours ago
 ┌───┐ Your Cloud Bucket                                   ─●
 │ ▣ │ app-data/YYYYMM.zip in every bucket
 └───┘ Nothing backed up yet
 ══════════════════════════════════════════════════════════
 Cloud                                                    ⊕
 Photos upload to storage you own. Credentials stay on this device and go
 straight to the bucket. Syncing runs only while the app is open — there's
 no background-sync permission yet.
 ┌───┐ my-photos                                           ›
 │ ☁ │ s3://my-photos/bring-your-own-photos/
 └───┘ ca-central-1
 Last synced Sep 17, 12:04 PM                  ← 12 muted, above the block
 [ ⟳ Sync Now ]  [ 🕐 Manual ▾ ]  [ 📥 Queue (12) ]  ← reads "Paused"
 [ ▣ Original ▾ ]  [ − 2 at a time + ]                 when paused
 1 bucket · 184 of 210 photos backed up        ← footer line, tappable
 ⟳ Syncing…                                    ← rides on the same line
```

Pills, not bare accent words, for the things you come here to press. A pill
says where to put your thumb — and one block of them under the list reads as
a toolbar for it, where a column of one-control rows read as a pile. Speed
keeps the pill shape with a stepper inside: it's a dial, not a list.

## Blocked iCloud, all four

```
 iCloud Drive                                           ·  ○─
 This build of the app isn't signed for iCloud

 iCloud Drive                                           ·  ○─
 iCloud Drive is off on this device
 Settings → your name → iCloud → Drive → turn on       ← accent, here only

 iCloud Drive                                           ·  ○─
 iCloud isn't ready yet — try again shortly

 Your Cloud Bucket                                      ·  ○─
 Add a bucket below first
```

## The menus behind the pills

```
 🕐 Manual ▾                       ▣ Original ▾
 ┌─────────────────────────────┐   ┌──────────────────────────────────┐
 │ Sync Frequency              │   │ Backup Format                    │
 │ Runs only while the app is  │   │ Original: Full quality, byte-    │
 │ open — there's no           │   │ identical to your device —       │
 │ background-sync permission  │   │ larger uploads and more storage. │
 │ yet.                        │   │ Optimized (WebP): Re-encodes to  │
 │ ✓ Manual Only               │   │ cut upload and storage size, at  │
 │   Every 15 Minutes          │   │ a small, usually unnoticeable    │
 │   Every Hour                │   │ quality loss.                    │
 │   Every 6 Hours             │   │ Videos always back up at original│
 │   Daily                     │   │ quality…                         │
 │ ( Cancel )                  │   │ ✓ Original    Optimized (WebP)   │
 └─────────────────────────────┘   └──────────────────────────────────┘
```

## Empty

```
 ▣  No Cloud Buckets Yet
    Add one to start backing up your photos and videos.
    [[ Add Cloud Bucket ]]
```

## Add a bucket  `lib/settings/add_s3_backup_screen.dart`

```
 ‹            Add Cloud Bucket
 Storage type                      Amazon S3 ▾
                                   Backblaze B2 (coming soon) ·
 ┌ S3 Bucket (paste info to add) ──────────────┐  ← the "(…)" is the button
 │ Access key ID                               │
 │ 18 characters — AWS keys are usually 20.    │  ← paste-length sanity hint
 │ Check for a bad paste.                      │
 │ Secret access key                           │
 │ Bucket                     Required         │
 │ Key prefix   bring-your-own-photos/         │  ← filled in for you
 └─────────────────────────────────────────────┘
 [[ Save ]]     ⟳ Validating bucket access…
 ⊗ Access denied. Check the access key, secret, and that this bucket
   allows it.
 ⊗ Bucket not found. Check the bucket name.
 ⊗ Could not reach S3. Check your network and try again.
 ⊗ Couldn't detect this bucket's region automatically.
 Drafts                                        ← an unfinished add is kept
 (no bucket yet)                            🗑

 tap (paste info to add) ↓
 ┌ S3 Bucket (back to fields) ─────────────────┐            📋
 │ bucket: my-photos                           │  ← Paste from Clipboard
 │ prefix: bring-your-own-photos/              │
 │ access_key_id: AKIA…                        │
 │ secret_access_key: …                        │
 └─────────────────────────────────────────────┘
 "name: value" or "name=value", any spelling. The region is still
 detected for you.
```

## Bucket browser  `lib/settings/bucket_browser_screen.dart`

One screen per depth, pushing itself. The listing is live — this answers
"did my backup actually land?" without the AWS console.

```
 ‹        bring-your-own-photos/            Select
 📁 originals                                    ›
 📁 thumbnails                                   ›
 🖼 IMG_4934.HEIC                         4.2 MB ›
 🎞 IMG_5001.MOV                         18.0 MB ›
 📄 library.json                           12 KB ›
 [ Load More ]                                   ← paged listing
 2 folders · 184 files · 1.2 GB                  ← stats line
 empty       This folder is empty.
 error       Couldn't reach the bucket. / Access denied… / Bucket not found.

 Select ⇒  ✓ per row, then
 [ Delete 3 files? ]!
 They go from the bucket for good. Photos on this device aren't touched —
 but any copy that only existed here is gone.
 ⚠ 1 file couldn't be deleted.
 tap a file ⇒ preview  ·  Can't preview this file type. [ Open Externally ]
 connection ⋯ ⇒ Browse Files · Delete Connection !
              Remove this backup target?  This won't delete any files
              already in the bucket — just this app's saved configuration.
```
