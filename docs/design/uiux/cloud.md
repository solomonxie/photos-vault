# Cloud Settings

`lib/settings/settings_screen.dart` — one flat page. Nothing here pushes a
sub-page that only holds controls: per-connection actions live in that row's
own sheet, and the queue opens over this page.

```
 ‹           Cloud Settings
 App Data
 Albums, people, tags, captions and places — everything that isn't the
 photo itself. Copied out once a day, on the days something changed,
 and pulled back automatically if you reinstall.
 ┌───┐ iCloud Drive                                        ─●
 │ ☁ │ Files → iCloud Drive → Photos Vault
 └───┘ Last copy 2 hours ago
 ┌───┐ Your Cloud Bucket                                   ─●
 │ ▣ │ app-data/YYYYMMDD.zip in every bucket
 └───┘ Nothing backed up yet
 [ ⇧ Export File ]  [ ⇩ Restore from File ]   ← press-once, so pills
 Also kept on this iPhone — Files → On My iPhone → Bring Your
 Own Photos. The last 7 days, plus a copy taken before anything
 that rewrites a lot at once. Deleting the app deletes those too.
 ══════════════════════════════════════════════════════════
 Cloud                                                    ⊕
 Photos upload to storage you own. Credentials stay on this device and go
 straight to the bucket. Syncing runs only while the app is open — there's
 no background-sync permission yet.
 ┌───┐ my-photos                                           ›
 │ ☁ │ s3://my-photos/photos-vault/
 └───┘ ca-central-1
 ┌───┐ cold-storage                                        ›
 │ ☁ │ cos://cold-storage-1250000000/vault/
 └───┘ ap-guangzhou
 [ ⇄ Photo by Photo ]        ← live once there's a second bucket
 2 buckets · 184 of 210 photos backed up       ← footer line, tappable
 ⟳ Syncing…                                    ← rides on the same line
```

Pills, not bare accent words, for the things you come here to press. A pill
says where to put your thumb. Everything about the *upload* — Sync Now, the
schedule, format, speed, the queue — is the Backup Queue's page (`queue.md`);
what stays here is the list of connections and the one setting that is a
property of the list itself.

## Filling more than one bucket

```
 [ ⇄ Photo by Photo ]
 ┌────────────────────────────────────────────────┐
 │ Bucket Order                                   │
 │ Every photo ends up in every bucket either     │
 │ way — this only changes the order they're      │
 │ filled in.                                     │
 │ Photo by Photo: each photo goes to every       │
 │ bucket before the next photo starts — every    │
 │ bucket stays equally up to date.               │
 │ Bucket by Bucket: one bucket gets the whole    │
 │ library before the next one starts — the first │
 │ complete copy exists sooner.                   │
 │ ✓ Photo by Photo      Bucket by Bucket         │
 │ ( Cancel )                                     │
 └────────────────────────────────────────────────┘
```

The message leads with what *doesn't* change. "Order" beside a list of
buckets reads like splitting the library between them, and a user who picks
one believing that has lost every copy but one. Neither option drops a
copy; both are the same uploads, resequenced.

With one bucket it is **dimmed, not hidden**, and carries the line that says
when it starts to count:

```
 ┌───┐ my-photos                                           ›
 │ ☁ │ s3://my-photos/photos-vault/
 └───┘ ca-central-1
 [ ⇄ Photo by Photo ]·       ← dimmed
 Matters once you add a second bucket.
 1 bucket · 184 of 210 photos backed up
```

Hiding it entirely made it findable only *after* the user had built the
situation it governs — which is the moment they'd have to go looking for a
setting they'd never seen. Dimmed, it's part of what a second bucket means,
read before it's needed. What it must not be is live: with one bucket both
answers are the same upload in the same order, and a choice that changes
nothing is worse than no choice at all.

## Three tiers, two switches

The copy in the app's own container is a **footer line, never a third
switch**. It shares the app's sandbox — deleting the app takes it and the
library together — so standing it beside two destinations that outlive the
app would promise something it can't keep. What it *can* promise is a
folder you can open, so the folder is what the line names.

```
 tier          answers                        switch?
 ─────────────────────────────────────────────────────────────
 this iPhone   "that import was a mistake"    no — a footer line
 iCloud Drive  "I reinstalled"                yes
 your bucket   "what did March look like?"    yes
```

Nothing is a *choice* between destinations: two switches, both allowed on.
A segmented "iCloud / bucket" would make the user pick when the answer is
"both".

## Export and restore

```
 [ ⇧ Export File ]                    [ ⇩ Restore from File ]
        │                                      │
        ▼                                      ▼
 [ share sheet · OS ]                   [ Files picker · OS ]
 photos-vault-2026-09-18.zip          │
 AirDrop · Files · Mail                        ▼
                                 ┌──────────────────────────────────┐
                                 │ Restore this backup?             │
                                 │ Adds the albums, people, tags    │
                                 │ and captions from Sep 12.        │
                                 │ Nothing already here is changed, │
                                 │ and a copy of today is saved     │
                                 │ first.                           │
                                 │      ( Cancel )   ( Restore )    │
                                 └──────────────────────────────────┘
                                                │
                                                ▼
                                 "Restored 184 photos' details.
                                  26 were already here and kept
                                  what they had."
```

The confirmation sits at the point of action and restates what the thing
about to happen does — not "are you sure", which tells the user nothing
they didn't already know. What it adds is the date in the file and the two
facts they can't see: nothing already here is overwritten, and a copy of
today goes in the folder first.

The result line reports what *didn't* land as well as what did. A file
whose photos aren't on this phone yet still restores their captions and
tags; saying only "184 restored" out of 210 reads as a half-failed import.

The one restore with no confirmation is a fresh install pulling its own
data back. There is nothing to overwrite and no context yet for the
question — and getting the library's work back is the whole point of
having taken the copy.

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

## Empty

```
 ▣  No Cloud Buckets Yet
    Add one to start backing up your photos and videos.
    [[ Add Cloud Bucket ]]
```

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
