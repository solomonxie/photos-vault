# Publishing Photos Vault — step by step

Every field below is ready to paste. `TODO` = only you can supply it.
App Store Connect paths start at **Apps → Photos Vault →**.

| | |
|---|---|
| Bundle ID | `com.solomonxie.photosVault` |
| SKU | `photosvault-ios` |
| Version | `1.0.0` (`version:` in `pubspec.yaml`) |
| Build | timestamp, set by `make release` |
| Devices | iPhone only (`TARGETED_DEVICE_FAMILY = 1`) — no iPad screenshots needed |
| Min iOS | 15.0 |
| iCloud container | `iCloud.com.solomonxie.photosVault` |
| Privacy Policy URL | `https://github.com/solomonxie/photos-vault/blob/master/docs/release/privacy-policy.md` |
| Support URL | `https://github.com/solomonxie/photos-vault/issues` |

---

## 1. Apple Developer account

- [ ] developer.apple.com → Account → membership **active** (paid; Individual is fine).
- [ ] App Store Connect → **Business** → no pending agreement banner. Free app: no Paid Apps agreement, no banking, no tax forms.

## 2. Xcode and signing

- [ ] Xcode → Settings → **Accounts** → signed in with the developer Apple ID; the team shows under it.
- [ ] `ios/Flutter/Signing.xcconfig` exists with your team ID. It is gitignored on purpose — the repo carries no account identifiers:
  ```
  LOCAL_DEVELOPMENT_TEAM = XXXXXXXXXX
  ```
- [ ] No CocoaPods step — this project uses Swift Package Manager, there is no `Podfile`.

## 3. Bundle ID and iCloud container

Both already exist (automatic signing created the App ID, the container was registered by hand — see the README). Verify at developer.apple.com → Certificates, Identifiers & Profiles:

- [ ] Identifiers → `com.solomonxie.photosVault` → **iCloud** checked, container `iCloud.com.solomonxie.photosVault` assigned.
- [ ] `ios/ExportOptions.plist` sets `iCloudContainerEnvironment = Production` — the shipped build must not point at the Development container.

## 4. Run on the iPhone

```
make check
make run
```

`make run` builds Release and installs it in place, keeping the app's data
(`flutter install` would wipe it — see CLAUDE.md). The phone is found for
you; `make run DEVICE=<udid>` if there's more than one. Never the simulator.

Smoke-test on the device: grid scroll, add a bucket, Sync Now, a photo's detail, People, a private album, Optimize Storage, iCloud app-data backup.

## 5. Create the app in App Store Connect

**Apps → + → New App**

| Field | Value |
|---|---|
| Platforms | iOS |
| Name | `Photos Vault: Complete Privacy` |
| Primary Language | English (U.S.) |
| Bundle ID | `com.solomonxie.photosVault` (dropdown) |
| SKU | `photosvault-ios` |
| User Access | Full Access |

If the name is taken, try in order: `Photos Vault — Own Your Backup`,
`Photos Vault: Your Own Bucket`, `Photo Vault Bucket Backup`. The name only
has to be unique across the store; the bundle ID does not change.

Two things reviewers do occasionally push back on with this name, both
answerable rather than fatal: "Photos" is also Apple's own app (the listing
never claims any association, and the description says whose bucket the
photos go to in the first line), and "Complete Privacy" is an absolute claim
(the privacy policy backs it — no server, no account, no analytics — so it is
a statement of fact about the app, not marketing). If either comes back as a
metadata rejection, `Photos Vault — Own Your Backup` sidesteps both without a
new build.

## 6. The reviewer needs a bucket — do this before submitting

This is the single most likely rejection (Guideline 2.1, "we could not
review the app's core functionality"). Backup is the point of the app and it
needs credentials the reviewer cannot create.

Make a throwaway bucket and a least-privilege IAM user, and paste the keys
into App Review Notes:

```
aws s3 mb s3://photosvault-review --region us-east-1
aws iam create-user --user-name photosvault-review
aws iam put-user-policy --user-name photosvault-review \
  --policy-name photosvault-review --policy-document file://policy.json
aws iam create-access-key --user-name photosvault-review
```

`policy.json`:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow",
      "Action": ["s3:ListBucket", "s3:GetBucketLocation"],
      "Resource": "arn:aws:s3:::photosvault-review" },
    { "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:GetObject", "s3:DeleteObject"],
      "Resource": "arn:aws:s3:::photosvault-review/*" }
  ]
}
```

- [ ] Keys pasted into App Review Notes (below).
- [ ] Reminder set to `aws iam delete-access-key` once the app is approved.

## 7. Listing content

Fill the pages in [App Store Connect pages](#app-store-connect-pages). Screenshots: see [Screenshots](#screenshots).

## 8. Archive and upload

```
make release
```

Formats, analyses, runs the suite, then archives and uploads. One command: archives Release (obfuscated, split debug info), signs for App
Store, and uploads — `ios/ExportOptions.plist` carries `destination=upload`,
so the export step is the upload. Verified end to end except the upload
itself, which needs the app to exist in App Store Connect first (step 5).
Processing takes 15–60 min, then an email: "build has completed processing".

Keep `build/symbols/<build-number>/` — an obfuscated build's crash reports are
unreadable without it.

If only the upload failed, retry without rebuilding:

```
make upload
```

Fallback, Xcode GUI: open `build/ios/archive/Runner.xcarchive` → Organizer →
**Distribute App** → App Store Connect → Upload.

Measured on the archive built while writing this: `Runner.app` 30 MB,
IPA 32.4 MB — inside the 33 MB budget in CLAUDE.md. Measure the archive's
copy (`build/ios/archive/Runner.xcarchive/Products/Applications/Runner.app`),
not `build/ios/Release-iphoneos/` — `flutter build ipa` doesn't touch the
latter, so it goes stale and quietly reports an older build's numbers.

## 9. TestFlight

- [ ] The build shows no "Missing Compliance" (see [Export compliance](#export-compliance)).
- [ ] Internal Testing → **+** group `Me` → add your Apple ID → install via TestFlight.
- [ ] Same smoke test as step 4, on the TestFlight build — this is the exact binary Apple reviews. Check iCloud app-data backup specifically: it is the Production container now, and a different container than every build before it.

## 10. Submit

- [ ] `iOS App → 1.0.0 Prepare for Submission` → **Build** → **+** → pick the build.
- [ ] Every page in [App Store Connect pages](#app-store-connect-pages) filled; App Privacy published.
- [ ] **Add for Review** → **Submit for Review**.

## 11. App Review

- Typical: 24–48 h. Waiting for Review → In Review → Pending Developer Release.
- Rejection → **Resolution Center**: reply there, or fix and re-run `make release` (new build number is automatic), attach the new build, resubmit.
- Likely questions, all answered in the notes below: how to test backup without a bucket, what the private album is, why the app asks to delete photos from Photos, the AI key.

## 12. Release

- [ ] **Pending Developer Release** → `1.0.0` page → **Release This Version**.
- [ ] `git tag v1.0.0 && git push --tags`.
- [ ] Delete the reviewer's IAM access key.

---

## Screenshots

**Required slot: iPhone 6.9" — exactly `1320 × 2868`** (or `1290 × 2796`).
Upload one set; App Store Connect scales it down for every smaller iPhone.
The 6.5" set (`1284 × 2778`) is optional and only worth uploading if you want
to control how older phones look. No iPad set — the app is iPhone-only.

Nothing is tracked under `docs/release/screenshots/` — the three PNGs in the
repo root are README art at ~840 px and upscale into mush. Capture a fresh set:

1. Build Release and install on the iPhone (step 4) — no debug banner.
2. Load a library with real photos, a bucket configured, a few named people.
3. Status bar: full battery, Wi-Fi, no notification badges. Side button + Volume Up per shot.
4. Shots, in upload order:
   1. **Library** — the day-grouped grid, scrolled to a dense month
   2. **Collections** — albums, People, Places, Events
   3. **People** — the face grid, several named
   4. **Photo detail** — place, event, faces, tags on one photo
   5. **Cloud** — the bucket list with "56 of 57 photos backed up"
   6. **Sync Queue** — uploads in flight
   7. **Optimize Storage** — "Free up to 12.4 GB"
   8. **Privacy by Design** — the Utilities page's privacy copy
5. AirDrop to the Mac, e.g. `~/Desktop/shots/`, then:

```
make screenshots FROM=~/Desktop/shots
```

Writes `docs/release/screenshots/{6.9,6.5}/`, JPEG, alpha stripped (App Store
Connect rejects anything with an alpha channel). Drag the `6.9` folder into
the 6.9" slot.

The paired iPhone 14 is a 6.1" phone, so its 1170 × 2532 shots get scaled up
about 13% to fill the 6.9" slot — soft if you look for it, invisible at store
thumbnail size, and Apple accepts it. Pixel-exact would mean capturing on a
6.9" phone, or, if you'll take it for screenshots only, a 6.9" simulator.

App Preview video: skip for 1.0.

Cosmetic, not a blocker: the build still ships Flutter's placeholder launch
image (`flutter build ipa` warns about it). It shows for a fraction of a
second at cold start and Apple does not reject for it — worth a pass at
`ios/Runner/Assets.xcassets/LaunchImage.imageset` sometime, not before 1.0.

---

## App Store Connect pages

### `iOS App → 1.0.0 Prepare for Submission`

| Field | Value |
|---|---|
| Previews and Screenshots | [Screenshots](#screenshots) |
| Promotional Text | below |
| Description | below |
| Keywords | below |
| Support URL | `https://github.com/solomonxie/photos-vault/issues` |
| Marketing URL | leave blank |
| Version | `1.0.0` |
| Copyright | `2026 Solomon Xie` |
| Routing App Coverage File | leave blank |
| Build | the uploaded build (step 10) |
| App Review → Sign-In Required | Off |
| App Review → Contact First / Last Name | TODO |
| App Review → Phone | TODO (with country code) |
| App Review → Email | TODO |
| App Review → Notes | below |
| App Review → Attachment | none |
| Version Release | **Manually release this version** |

Promotional Text (168/170):

```
Back up your camera roll to a bucket you own — S3, COS or OSS. No account, no subscription, no server in the middle. Faces, albums and search all run on the phone.
```

Description:

```
Photos Vault backs up your photos and videos to object storage you own — an Amazon S3, Tencent COS or Alibaba Cloud OSS bucket, with your credentials, under your bill. There is no Photos Vault account, no subscription, and no server between your camera roll and your bucket.

BACKUP TO STORAGE YOU OWN
• Add a bucket by name — the region is detected for you, and access is verified before anything is saved
• Automatic backup of new and changed photos, resumable, surviving a lock screen or a dropped connection
• More than one bucket at once: mirror every photo to each, or fill one completely before the next
• Upload originals byte-for-byte, or re-encode to WebP to cut storage
• Separate key prefixes so your own bucket Lifecycle Rules can tier storage however you like
• Browse what is actually in the bucket, from inside the app

A GALLERY, NOT A BACKUP TOOL
• Day-grouped grid built to scroll like Photos does, on libraries of tens of thousands
• Albums, favorites, tags, captions, places and events
• Live Photos, GIFs, videos, bursts
• Crop, rotate, and an optional AI touch-up — always saved as a new photo
• Lock a photo and nothing can delete it, edit it, or shrink it to save space

PEOPLE AND FACES, ON THE DEVICE
• Faces are found and matched by a face model that runs on the phone
• Name someone once and the next photo of them suggests the name
• Each person gets a profile: bio, relationships, a relationship graph, movement history
• Nothing about this is sent anywhere, and none of it costs anything

PRIVATE ALBUMS
• A four-digit code opens a hidden album, and every code is valid — a wrong one opens an empty album, never an error, so nothing confirms an album exists
• Hidden photos leave the phone encrypted with your passphrase, stored in your bucket disguised as ordinary pictures
• Nothing about them stays on the phone — no file, no thumbnail, no record

FREE UP SPACE
• See what the library is costing you, per photo: large files, oversized resolutions, formats that could be smaller
• Drop the full-resolution copy of anything already backed up — the photo stays in your library and comes back on demand

OPTIONAL AI
Bring your own API key from OpenAI, Anthropic, Google, Groq, Mistral or xAI and let it tag, caption and sort photos into People and Events collections. The key is yours, the usage is billed to your account with that vendor, and the feature is off until you turn it on. Skip it and the app works the same — faces and search never needed it.

YOUR DATA
• Library, records and faces live in a database on this iPhone and are worked out here
• Albums, people, tags and captions can be copied daily to your iCloud Drive, your bucket, or both — pulled back automatically if you reinstall
• Export and import as plain files, any time
• Keys live in the iOS Keychain and are never included in any backup
• Delete the app and the local data goes with it

Free. No ads, no analytics, no upsell.
```

Keywords (97/100 — "photos" and "vault" are omitted, the name already indexes them):

```
s3,bucket,backup,gallery,album,faces,private,hidden,offline,storage,encrypted,camera,roll,archive
```

App Review Notes:

```
No account or login. The app opens straight into your photo library.

TESTING BACKUP — this needs a bucket, so here is one:
  Provider: Amazon S3
  Bucket: TODO
  Access key ID: TODO
  Secret access key: TODO
  Key prefix: leave the default
Utilities -> Cloud Settings -> Add Cloud Bucket, paste the above, Save. The
app verifies access before saving. Then Sync Now, and Queue shows uploads.
These are throwaway credentials scoped to that one bucket and will be revoked
after review.

WITHOUT a bucket, everything except upload still works: the library, albums,
People and face recognition, search, editing, private albums (they stay on
the device when no bucket is configured).

PRIVATE ALBUMS (Utilities -> Hidden): a four-digit code. Every code is valid
by design — an unused one opens a new empty album rather than showing an
error, because an error would confirm that some other album exists. There is
no "wrong passcode" state and nothing is being hidden from the reviewer; any
four digits will open a working album.

DELETING FROM PHOTOS: hiding a photo, or freeing up space, asks iOS to remove
the original from the Photos library. That always goes through the system
confirmation sheet — the app cannot and does not delete anything silently.

AI: off by default and unusable until the user adds their own API key from
OpenAI, Anthropic, Google, Groq, Mistral or xAI. Face recognition is a model
running on the device and needs no key.

We operate no server and receive no user data. Photos go only to the bucket
the user configures.
```

What's New: not shown for a first version. From 1.0.1 on, write it here.

### `General → App Information`

| Field | Value |
|---|---|
| Name | `Photos Vault: Complete Privacy` |
| Subtitle (27/30) | `Back up to a bucket you own` |
| Category — Primary | Photo & Video |
| Category — Secondary | Utilities |
| Content Rights | **No**, it does not contain, show, or access third-party content |
| Age Rating | **Edit** → answers below → result **4+** |
| License Agreement | Apple standard EULA (default) |
| Privacy Policy URL | `https://github.com/solomonxie/photos-vault/blob/master/docs/release/privacy-policy.md` |

Age rating questionnaire:

| Section | Answer |
|---|---|
| Parental controls / age assurance | No |
| Unrestricted web access | No |
| User-generated content | No — the photos are the user's own, not shared with anyone |
| Messaging and chat | No |
| Advertising | No |
| Violence, sexual content, profanity, horror, mature themes | None |
| Alcohol, tobacco, drugs | None |
| Medical or treatment information | None |
| Gambling, contests, loot boxes | None / No |
| Made for Kids | No |

**Digital Services Act** trader status: **Not a trader** (free, no
monetization). Answer it in Business → Compliance if EU availability is
blocked without it.

### `App Store → Trust & Safety → App Privacy`

| Field | Value |
|---|---|
| Privacy Policy URL | same as above |
| Do you or your third-party partners collect data from this app? | **No, we do not collect data from this app** |

Then **Publish**. The label reads "Data Not Collected".

Why that is the honest answer: data leaves the device only to destinations the
user configures and owns — their bucket, their iCloud, their AI vendor under
their own key. None of it reaches the developer, and none of those vendors is
a partner of this app. Apple's reverse-geocoding call carries coordinates and
no identifier.

Re-check before each submission — it stops being true the moment an SDK lands:

```
grep -nriE "analytics|firebase|sentry|amplitude|mixpanel|posthog|bugsnag" pubspec.yaml
```

### Privacy manifest (in the binary, not a page)

`ios/Runner/PrivacyInfo.xcprivacy` ships in the app bundle and is wired into
the Runner target's Resources. Nothing to fill in at submission — but an
upload missing it earns an ITMS-91053 email from Apple, so it is here.

It declares no tracking, no collected data, and one required-reason API:
`NSPrivacyAccessedAPICategoryFileTimestamp`, reason `C617.1` (file metadata
inside the app's own container) — `File.stat()` in the vault cache, the local
vault's retention window, and Optimize Storage's per-photo sizes. Flutter's
plugins carry their own manifests; this one covers the app's own code.

Revisit it if the app starts reading free disk space, `UserDefaults`, system
boot time, or active keyboards — each is its own declaration.

### `App Store → Trust & Safety → App Accessibility`

Skip for 1.0 rather than over-claim.

### `App Store → Monetization → Pricing and Availability`

| Field | Value |
|---|---|
| Base Country or Region | United States (USD) |
| Price | **Free** ($0.00) |
| Availability | All countries or regions |
| Tax Category | App Store software (default) |
| iPhone and iPad Apps on Apple Silicon Macs | **Off** for 1.0 (never tested there) |
| Apple Vision Pro | Off |

### Not needed for 1.0

In-App Purchases, Subscriptions, In-App Events, Custom Product Pages, Product
Page Optimization, Promo Codes, Game Center, Featuring Nominations.

---

## Export compliance

Nothing to fill in. `ITSAppUsesNonExemptEncryption = false` in `Info.plist`
answers it at upload time.

The app does encrypt — private albums are AES-256-CTR with a PBKDF2-derived
key — but every algorithm comes from the platform: AES and PBKDF2 through
CommonCrypto (`lib/vault/cipher.dart` calls it over `dart:ffi`), TLS through
URLSession, Keychain for the key material. Apple's own table puts "encryption
limited to that within the Apple operating system" at **no documentation
required in App Store Connect**. HMAC-SHA256 (the `crypto` package) is used
for authentication and integrity, itself an exempt purpose.

Verify: TestFlight → the build is **not** marked "Missing Compliance". If it
ever is, **Manage** → the exemption for encryption within the operating
system.

If the crypto ever moves off CommonCrypto onto a bundled implementation, this
answer changes to "industry standard algorithm, not provided within the Apple
operating system", which costs a French encryption declaration for
distribution in France.

---

## Optional: 简体中文 localization

The app ships `zh`. App Store Connect → App Information → language dropdown
(top right) → **Add Chinese (Simplified)**, then switch the `1.0.0` page to it.

| Field | Value |
|---|---|
| Name | `Photos Vault 照片保险库` |
| Subtitle | `备份到你自己的存储桶` |
| Keywords | `照片,备份,存储桶,相册,人脸,隐私,离线,加密,私密,归档,对象存储,图库` |
| Privacy Policy URL | same |
| Screenshots | reuse the English ones (App Store Connect falls back automatically) |

Promotional Text:

```
把相机胶卷备份到你自己的存储桶——S3、腾讯 COS 或阿里云 OSS。无需账号，无订阅，中间没有任何服务器。人脸识别、相册和搜索全部在手机上完成。
```

Description:

```
Photos Vault 把你的照片和视频备份到你自己的对象存储——Amazon S3、腾讯云 COS 或阿里云 OSS，用你自己的密钥，走你自己的账单。没有 Photos Vault 账号，没有订阅，从相机胶卷到存储桶之间没有任何服务器。

备份到你自己的存储
• 只填存储桶名字——区域自动识别，保存前先验证访问权限
• 新照片和有改动的照片自动备份，可续传，锁屏或断网都不会前功尽弃
• 可同时配置多个存储桶：每张照片都发往全部存储桶，或先把一个装满再开始下一个
• 原图逐字节上传，或转成 WebP 以节省空间
• 缩略图/中图/原图分前缀存放，你自己的生命周期规则想怎么分层都行
• 在应用内直接浏览存储桶里真正有什么

它首先是一个图库
• 按天分组的网格，为几万张照片的滑动流畅度而写
• 相册、收藏、标签、描述、地点、事件
• 实况照片、GIF、视频、连拍
• 裁剪、旋转，以及可选的 AI 修图——永远另存为新照片
• 锁定一张照片，它就不会被删除、被编辑，也不会为了省空间被压缩

人脸识别在本机完成
• 由手机上运行的人脸模型查找并匹配人脸
• 给一个人命名一次，下一张照片就会主动建议这个名字
• 每个人都有完整档案：简介、亲友关系、关系图谱、迁居轨迹
• 全程不上传，也不产生任何费用

私密相册
• 四位数字打开隐藏相册，而且每一个都是有效的——输错只会打开一个空相册，永远不会报错，所以没有任何信息能证实某个相册存在
• 隐藏的照片先用你的口令加密再离开手机，伪装成普通图片存进你的存储桶
• 本机不留任何痕迹——没有文件，没有缩略图，没有记录

释放空间
• 逐张看清照片库占了多少：大文件、过高分辨率、可以更小的格式
• 已备份的照片可以删掉本机原图——它仍在图库里，需要时再下载回来

可选 AI
使用你自己的 OpenAI、Anthropic、Google、Groq、Mistral 或 xAI 密钥，自动打标签、写描述，并归入"人物"和"事件"智能合集。密钥属于你，用量计入你在该服务商的账户，默认关闭。完全不用它也一样好用——人脸识别和搜索从来不需要它。

你的数据
• 照片库、各项记录与人脸都存在这台 iPhone 的数据库里，也都在本机算出
• 相册、人物、标签和描述可每天复制到你的 iCloud 云盘、你的存储桶，或两者都要；重装后自动取回
• 随时导出导入为普通文件
• 密钥保存在钥匙串中，任何备份都不包含
• 删除应用，本机数据一并消失

免费。无广告，无统计分析，无内购推销。
```
