# Publishing Photos Vault — step by step

Every field below is ready to paste. `TODO` = only you can supply it.
App Store Connect paths start at **Apps → Photos Vault →**.

| | |
|---|---|
| Bundle ID | `com.example.photosVault` |
| SKU | `photosvault-ios` |
| Version | `1.0.0` (`version:` in `pubspec.yaml`) |
| Build | timestamp, set by `make release` |
| Devices | iPhone only (`TARGETED_DEVICE_FAMILY = 1`) — no iPad screenshots needed |
| Min iOS | 15.0 |
| iCloud container | `iCloud.com.example.photosVault` |
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

- [ ] Identifiers → `com.example.photosVault` → **iCloud** checked, container `iCloud.com.example.photosVault` assigned.
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
| Name | `Photos Vault — Your Bucket` |
| Primary Language | English (U.S.) |
| Bundle ID | `com.example.photosVault` (dropdown) |
| SKU | `photosvault-ios` |
| User Access | Full Access |

If the name is taken, try in order: `Photos Vault — Own Your Backup`,
`Photos Vault: Your Own Bucket`, `Photo Vault Bucket Backup`. The name only
has to be unique across the store; the bundle ID does not change.

**The name and subtitle sell custody and findability, not secrecy.** They
used to read `Photos Vault: Complete Privacy` / `Back up to a bucket you
own` — two lines about privacy, which is not the thing people hesitate
over. What stops somebody handing a photo library to an app is *will this
still be here, and can I get it out again*. So the name says whose storage
it is and the subtitle answers the second question; the privacy story is
still in the first line of the description, where it was always doing the
work. It also drops an absolute claim ("Complete") that a metadata reviewer
can argue with, for one that is demonstrable in the app.

"Photos" being Apple's own app name is the one remaining thing a reviewer
occasionally raises: the listing claims no association, and the description
says whose bucket the photos go to in its first sentence. If it comes back
as a metadata rejection, `Photos Vault — Own Your Backup` sidesteps it
without a new build.

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
No iPad set — the app is iPhone-only.

Nothing is tracked under `docs/release/screenshots/` — the three PNGs in the
repo root are README art at ~840 px and upscale into mush. Capture a fresh set:

1. Build Release and install on the iPhone (step 4) — no debug banner.
2. Load a library with real photos, a bucket configured, a few named people.
3. Status bar: full battery, Wi-Fi, no notification badges. Side button + Volume Up per shot.
4. Shots, in upload order:
   1. **Library** — the day-grouped grid, scrolled to a dense month
   2. **Collections** — albums, People, Places
   3. **People** — the face grid, several named
   4. **Photo detail** — place, faces, tags on one photo
   5. **Cloud** — the bucket list with "56 of 57 photos backed up"
   6. **Sync Queue** — uploads in flight
   7. **Optimize Storage** — "Free up to 12.4 GB"
   8. **Your Copies, Your Privacy** — the note at the foot of the library
5. AirDrop to the Mac, e.g. `~/Desktop/shots/`, then:

```
make screenshots FROM=~/Desktop/shots
```

Writes `docs/release/screenshots/`, JPEG, alpha stripped (App Store
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
| Copyright | `2026 solomonxie` |
| Routing App Coverage File | leave blank |
| Build | the uploaded build (step 10) |
| App Review → Sign-In Required | Off |
| App Review → Contact First / Last Name | TODO |
| App Review → Phone | TODO (with country code) |
| App Review → Email | TODO |
| App Review → Notes | below |
| App Review → Attachment | none |
| Version Release | **Manually release this version** |

Promotional Text (148/170 — no price words here, Guideline 2.3.7):

```
Back up your camera roll to a bucket you own — S3, COS or OSS. Plain files, plus an index you can read without this app. No account and no server in the middle.
```

Description:

```
Photos Vault backs up your photos and videos to object storage you own — an Amazon S3, Tencent COS or Alibaba Cloud OSS bucket, with your credentials, under your bill. There is no Photos Vault account, no subscription, and no server between your camera roll and your bucket.

IF YOU EVER LOSE THIS APP
• Your photos are ordinary files in your own bucket, not a proprietary archive
• An index.csv sits beside them listing every photo by date, album, person, caption and place — open it in any spreadsheet and find anything again, with no account and nothing installed
• Check Now asks your bucket, object by object, whether it really holds what this app says it holds
• Test Restore downloads photos back out of the bucket and checks them, so "backed up" is something you have watched work rather than a number on a screen
• Nothing on the phone is deleted on the strength of an unverified backup
• A bucket copy is removed only when you delete that photo for good

BACKUP TO STORAGE YOU OWN
• Add a bucket by name — the region is detected for you, and access is verified before anything is saved
• Automatic backup of new and changed photos, resumable, surviving a lock screen or a dropped connection
• More than one bucket at once: mirror every photo to each, or fill one completely before the next
• Upload as HEIF to cut storage by about half, or originals byte-for-byte
• Separate key prefixes so your own bucket Lifecycle Rules can tier storage however you like
• Browse what is actually in the bucket, from inside the app

A GALLERY, NOT A BACKUP TOOL
• Day-grouped grid built to scroll like Photos does, on libraries of tens of thousands
• Albums, favorites, tags, captions and places
• Live Photos, GIFs, videos, bursts
• Crop, rotate and resize — always saved as a new photo
• Lock a photo and nothing can delete it, edit it, or shrink it to save space

PEOPLE AND FACES, ON THE DEVICE
• Faces are found and matched by a face model that runs on the phone
• Name someone once and the next photo of them suggests the name
• Each person gets a profile: bio, relationships, a relationship graph, movement history
• Nothing about this is sent anywhere, and none of it costs anything

PRIVATE ALBUMS
• A four-digit code opens a hidden album, and every code is valid — a wrong one opens an empty album, never an error, so nothing confirms an album exists
• Hidden photos are encrypted with your passphrase and disguised as ordinary pictures — on the phone, and in your bucket
• No readable trace stays on the phone — no plain file, no thumbnail, no record
• A person can have a hidden folder of their own, opened from their page

FREE UP SPACE
• See what the library is costing you, per photo: large files, oversized resolutions, formats that could be smaller
• Drop the full-resolution copy of anything already backed up — the photo stays in your library and comes back on demand

OPTIONAL AI
Add your own AI key to help fill in people's profiles from text you provide. The key is yours, usage is billed to your own account with that provider, and nothing is sent until you add one. No photo is ever sent to an AI service. Skip it and the app works the same — faces and search never needed it. Not available in China mainland.

YOUR DATA
• Library, records and faces live in a database on this iPhone and are worked out here
• Albums, people, tags and captions are copied to your iCloud Drive and your bucket on any day something changed — on by default, and pulled back automatically if you reinstall
• Every copy carries that readable index.csv, so the backup opens without this app
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
More -> Cloud Settings -> Add Cloud Bucket, paste the above, Save. The
app verifies access before saving. Then Sync Now, and Queue shows uploads.
These are throwaway credentials scoped to that one bucket and will be revoked
after review.

WITHOUT a bucket, everything except upload still works: the library, albums,
People and face recognition, search, editing, private albums (they stay on
the device when no bucket is configured).

PRIVATE ALBUMS (More -> Hidden): a four-digit code. Every code is valid
by design — an unused one opens a new empty album rather than showing an
error, because an error would confirm that some other album exists. There is
no "wrong passcode" state and nothing is being hidden from the reviewer; any
four digits will open a working album.

DELETING FROM PHOTOS: hiding a photo, or freeing up space, asks iOS to remove
the original from the Photos library. That always goes through the system
confirmation sheet — the app cannot and does not delete anything silently.

AI: off by default and unusable until the user adds their own API key. It is
used only to help fill in person profiles from text the user provides; no
photo is ever sent to an AI service.

CHINA MAINLAND: all AI functionality, including ChatGPT/OpenAI, is
deactivated in the China mainland storefront. The app reads the App Store
account's country at launch (StoreKit storefront) and, for China mainland,
removes AI Settings and every AI option from the app and blocks all AI
requests, even if a key were stored. No metadata mentions ChatGPT or OpenAI.

Face recognition is a model running on the device and needs no key.

We operate no server and receive no user data. Photos go only to the bucket
the user configures.
```

What's New: not shown for a first version. From 1.0.1 on, write it here.

### `General → App Information`

| Field | Value |
|---|---|
| Name | `Photos Vault — Your Bucket` |
| Subtitle (28/30) | `Your photos, always findable` |
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

## 简体中文 localization (China mainland storefront)

App Store Connect → App Information → language dropdown (top right) →
**Add Chinese (Simplified)**, then switch the `1.0.0` page to it. Written as
native copy, not a translation. No AI feature or vendor is mentioned anywhere
(AI is off in China mainland, see `docs/release/README.md`).

| Field | Value |
|---|---|
| Name | `Photos Vault 照片保险库` |
| Subtitle | `照片存进自己的桶，丢不了` |
| Keywords | `照片,备份,存储桶,相册,人脸,隐私,私密,加密,对象存储,图库,云备份,相机胶卷,整理,离线` |
| Privacy Policy URL | same |
| Screenshots | own set in Chinese UI, `docs/release/screenshots/zh/` (steps below) |

Promotional Text:

```
照片备份到你自己的存储桶，支持 S3、腾讯云 COS、阿里云 OSS。存下来的就是普通文件，还附带一份表格索引，不装这个 App 也能查。不用注册账号，中间也没有别人的服务器。
```

Description:

```
Photos Vault 把手机里的照片和视频备份到你自己的对象存储里，可以是 Amazon S3、腾讯云 COS 或阿里云 OSS。用的是你自己的密钥，花的是你自己的钱。不用注册账号，不收订阅费，照片从手机到存储桶，中间不经过任何第三方服务器。

万一哪天这个 App 不用了，照片也丢不了
• 备份出来的就是普通文件，直接躺在你自己的存储桶里，不是什么只有本 App 才能打开的压缩包
• 每个备份旁边都有一份 index.csv，按日期、相册、人物、备注和地点列好了每一张照片，用 Excel 或 WPS 打开就能找，不用账号，也不用装任何软件
• 「立即核对」会逐个文件去问存储桶：App 说备份了的，你桶里是不是真的有
• 「试试恢复」会把照片从存储桶下载回来并校验，“已备份”不再只是屏幕上一个数字，而是你亲眼看过的结果
• 没确认备份成功之前，手机上的照片一张都不会被删
• 只有你自己彻底删除某张照片时，存储桶里的那份才会跟着删

备份到自己的存储桶
• 只要填桶的名字，地域自动识别，保存之前先帮你验证权限
• 新拍的、改过的照片自动备份，断网、锁屏都能接着传
• 可以同时接多个桶：每张照片都发到每个桶，或者先把一个装满再用下一个
• 可存为 HEIF，大约省一半空间；也可以原图原样上传
• 缩略图、中图、原图分前缀存放，想用桶的生命周期规则做冷热分层，随你
• 在 App 里就能翻看桶里到底存了什么

先是个好用的相册，然后才是备份工具
• 按天分组的网格，几万张照片也滑得顺，手感向系统相册看齐
• 相册、收藏、标签、备注、地点
• 实况照片、GIF、视频、连拍都支持
• 裁剪、旋转、缩小尺寸，改完都是另存一张新的，原图不动
• 给照片加锁，就不会被删、被改，也不会被“释放空间”压缩

人脸识别，全在手机上完成
• 人脸的查找和比对都由手机上的模型完成
• 给某个人起一次名字，之后再有他的照片，就会主动提示
• 每个人都有一页档案：简介、亲友关系、关系图、搬家轨迹
• 全程不联网上传，也不花一分钱

私密相册
• 输入四位数字打开隐藏相册，输任何四位数都能进：输错了只会打开一个空相册，不会提示错误，别人也就看不出这里有没有藏东西
• 隐藏的照片用你设的口令加密，还会伪装成普通图片，手机上是这样，存储桶里也是这样
• 手机上不留任何看得出来的痕迹：没有明文文件，没有缩略图，没有记录
• 每个人物还可以有自己的隐藏文件夹，从他的主页进入

腾出手机空间
• 逐张看清哪些照片最占地方：体积大的、分辨率过高的、格式可以更省的
• 已经备份的照片，可以只删掉手机里的原图，照片仍留在相册里，要看的时候再下载回来

数据都在你自己手里
• 照片库、各项记录和人脸数据都存在这台 iPhone 本机的数据库里，也都在本机计算
• 相册、人物、标签和备注，在有改动的当天会同步到你的 iCloud 云盘和存储桶，默认开启，重装后自动恢复
• 每份副本都带着可直接阅读的 index.csv，不用本 App 也能打开
• 随时可以导出、导入成普通文件
• 密钥存在系统钥匙串里，不会进入任何备份
• 卸载 App，本机数据也一并清除

免费，没有广告，不做数据统计，也没有内购。
```

### Chinese screenshots

1. `make install-ios STOREFRONT=CHN` (forces China mode: no AI anywhere), phone language set to 简体中文, demo mode on.
2. Same 8 shots, same order, as the English set; skip any that shows AI.
3. AirDrop to `~/Desktop/shots-zh/`, then `make screenshots FROM=~/Desktop/shots-zh OUT=docs/release/screenshots/zh`.
4. Upload the `zh` folder to the 6.9" slot of the Chinese (Simplified) page.
