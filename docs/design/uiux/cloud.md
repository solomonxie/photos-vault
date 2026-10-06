# Cloud Settings

`lib/settings/settings_screen.dart` — status first, settings last. Full
mocks, states and copy: `cloud-redesign.md`.

```
 ‹ More                 Cloud
 ╭ ◉ All backed up ───────────────────────────────╮
 │ 184 of 210 photos · 2 buckets    ▓▓▓▓▓▓▓▓░░    │
 │ Last synced today, 3:04 PM                     │
 │ [[ Back Up Now ]]                Queue · 26 ›  │
 ╰────────────────────────────────────────────────╯
 CLOUD BUCKETS     ☁ my-photos ›  ☁ cold-storage ›  ⊕ Add Cloud Bucket
 UPLOADS           Sync · Upload Quality · Fill Order (2+ buckets) ·
                   Find New Files in Buckets (count)
 APP DATA ⓘ        iCloud Drive ─● · Your Cloud Bucket ─● · Export · Restore
```

- One inset group per subject; `title … value ›` rows; sheets carry choices.
- Status priority: lost > failed > paused > syncing > waiting > all done.
- Fill Order only with a second bucket: with one, both orders are the same.
- The copy in the app's own container is a footer line, never a third
  switch: it dies with the app, so it can't sit beside two that don't.
- A blocked iCloud row keeps its place; its reason replaces the subtitle
  and only the fixable state gets the accent "how" line.
- Export/Restore keep their confirmation: it states the file's date and
  that nothing existing is overwritten and a copy of today is saved first.
- Fresh-install restore has no confirmation: nothing to overwrite.

## Add a bucket  `lib/settings/add_backup_screen.dart`

The same dark, card-less page as Cloud Settings one step in — section
heading, rows on the background, filled fields under small labels. Save is
a navigation-bar action: a filled button under the drafts list sits below
the fold on every visit and reads as a second page's worth of chrome.

```
 ‹ Cloud Settings   Add Cloud Bucket            Save
 Bucket                          (paste info to add)
 Cloud vendor
 ┌───────────┐ ┌───────────────────┐
 │ Amazon S3 │ │ Tencent Cloud COS │   ← the choices, not a
 └───────────┘ └───────────────────┘     row that hides them
 ┌───────────────────┐
 │ Alibaba Cloud OSS │
 └───────────────────┘
 Whose cloud the bucket lives in — Amazon S3, Tencent
 COS, Alibaba OSS. Google Cloud Storage, Azure Blob
 and Backblaze B2 are coming.
 ───────────────────────────────────────────────────
 Access key ID
 ┌─────────────────────────────────────────────────┐
 │ AKIAIOSFODNN7EXAMP                              │
 └─────────────────────────────────────────────────┘
 18 characters — AWS keys are usually 20. Check for
 a bad paste.                    ← AWS lengths only
 Secret access key
 ┌────────────────────────────────────────────┬────┐
 │ ••••••••••••                               │ 👁 │
 └────────────────────────────────────────────┴────┘
 Bucket name
 ┌─────────────────────────────────────────────────┐
 │ holiday-snaps                                   │
 └─────────────────────────────────────────────────┘
 Required                        ← red, only on Save
 Key prefix
 ┌─────────────────────────────────────────────────┐
 │ photos-vault/                          │
 └─────────────────────────────────────────────────┘
 ⊗ Access denied. Check the access key, secret, and
   that this bucket allows it. (AccessDenied)
 ═══════════════════════════════════════════════════
 DRAFTS
 holiday-snaps                                    ⊗
 S3 · AKIA…MPLE
```

```
saving   Save ⇒ ⟳ in the nav bar, every field greyed
         ⟳ Validating bucket access…   ← under the fields, not over them
```

COS and OSS differ by four lines, never by a second form:

```
 Cloud vendor             [ Tencent Cloud COS ] ← filled
 SecretId                     ← each console's own words for the
 SecretKey                      two halves of a credential
 Bucket name
 │ holiday-snaps-1250000000                       │
 Including the APPID suffix, e.g. my-photos-1250000000.
 Region
 │ ap-guangzhou                                 ▾ │  ← tap ⇒ picker sheet
 The one the bucket's console shows. Pick it or type it.
 Pick the region this bucket is in.   ← red, on Save

 ✗ a free-text region box        ✗ a closed dropdown
   a typo is a 404 two              a region added after this
   screens later                    release can't be entered
```

## Two ways to pick

```
 Cloud vendor  — 3 of them             Region — 46 of them
 ▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁       ▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁
 ┌───────────┐ ┌─────────┐           ( Cancel )      Region
 │*Amazon S3*│ │ Tencent │           ┌──────────────────────┐
 └───────────┘ └─────────┘           │ 🔍 ap-gu             │
 on the page, always visible         └──────────────────────┘
 no sheet, no second tap             ap-guangzhou          ✓
                                     ─────────────────────
                                     Use "ap-guangzhou-1"
                                       ↑ typed, unlisted
                                     shown, not hidden
```

A handful of options is a row of chips: the question and its answers are
both on the page, and choosing costs one tap. Forty-six is a sheet — Region
reuses `viewer/search_picker_sheet.dart`, the same search-or-create
drop-down as places and tags.

The three unbuilt backends are named in the vendor hint rather than shown
as dead chips: the roadmap is worth saying, not worth three tap targets
that do nothing.

## Paste to fill

The group's header carries it; the box replaces the fields in place. Rules
(one paste then snap back, typing keeps it open, buffer cleared on every
toggle) live in the `uiux` skill's `paste-to-fill.md`.

```
 Bucket                           (back to fields)
 Cloud vendor    [ Tencent Cloud COS ] filled          ← stays: a pasted
 Credentials block                                       endpoint moves it
 ┌─────────────────────────────────────────────────┐
 │ bucket: my-photos                               │
 │ prefix: photos-vault/                  │
 │ access_key_id: AKIA…                        📋  │
 │ secret_access_key: …                            │
 └─────────────────────────────────────────────────┘
 "name: value" or "name=value", any spelling. Paste
 the bucket's endpoint URL and it fills in the
 region too.
```

## Bucket browser  `lib/settings/bucket_browser_screen.dart`

One screen per depth, pushing itself. The listing is live — this answers
"did my backup actually land?" without the AWS console.

```
 ‹        photos-vault/            Select
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
