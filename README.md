# Photo backup to a bucket you own

Photos Vault is a Flutter app (iOS first, Android backlog) that backs up Photos/Videos to your own bucket — AWS S3, Tencent COS or Alibaba Cloud OSS — with thumbnail-first browsing and storage tiering via your bucket's own Lifecycle Rules. Localized (English, Mandarin) from the start.

Design: `docs/design/DESIGN.md`
Demo mode: `demo/README.md`
UI/UX: `docs/design/UIUX-DESIGN.md`
Plan: `docs/design/IMPLEMENTATION_PLAN.md`

## Setup

```
./scripts/bootstrap-flutter.sh   # clones Flutter SDK locally into .tools/, no system install
.tools/flutter/bin/flutter run
```

Or, if you already have Flutter installed system-wide: `flutter run`.

## Publishing

Everything the App Store submission needs, field by field:
[`docs/release/listing.md`](docs/release/listing.md).

```
make release
```

Formats, analyses, tests, archives an obfuscated Release build and uploads it
to App Store Connect — no Xcode, no Product ▸ Archive ▸ Distribute. `make`
on its own lists the rest.

Storefront: read at launch from the App Store account's country (StoreKit) —
China mainland → `cn`, else `us` — as `AppStoreRegion.current`
(`lib/settings/app_store_region.dart`). One binary for every storefront.
`make install-ios STOREFRONT=CHN` forces `cn` on a local build for testing;
release/archive never do. `cn` defaults the language to Simplified Chinese
unless a language was picked for the app in iOS Settings.

## The backup has to open without this app

Objects go up keyed by the iOS asset identifier — `originals/B84E8479-…_L0_001.HEIC`
— which says nothing about when a photo was taken or who is in it. A bucket of
thirty thousand of those is a write-only pile. So every copy of the app-data
snapshot carries an **`index.csv`**: one row per photo, `taken_at` first, with
album, people, caption, place and the object's key. It sits loose in
`app-data/` in each bucket and in the iCloud folder as well as inside each
zip, because recovery starts with somebody in a web console who shouldn't have
to guess which of thirty archives to download. Hidden photos are excluded on
purpose — see `lib/backup/snapshot_index.dart`.

`isFullyBackedUp` is a local row written by whichever upload reported success,
and a wrong prefix, a lifecycle rule, a bucket emptied in a console or one
upload that lied all look identical from inside the database. So
`lib/upload/backup_verifier.dart` asks the bucket instead, and **nothing
deletes a local original without it** — one HEAD for a single
remove-from-device, one listing pass for a batch. An unreachable bucket blocks
the delete rather than being treated as either answer. Utilities → **Where Your
Photos Are** carries the rest: every copy that exists, when a bucket last
confirmed it, a three-photo restore drill, and the steps to get everything back
with none of this software involved.

## Private albums have no wrong passcode

Utilities → Hidden asks for four digits, and **every** code is valid. The
code *is* the album: type one that's been used before and its photos are
there, type anything else and a fresh empty album opens. There is no error
state, because an error state is what leaks.

That gives a decoy for free. A code handed over under pressure opens a real,
ordinary-looking album — and nothing anywhere says another one exists. The
same property covers the honest case: mistype your own code and you get a
blank album, not a "wrong passcode" message that would tell a shoulder-surfer
they'd found something worth pushing on. (Signal's hidden-chat PIN works the
same way.)

Only the hash is stored, so a database dump doesn't list which codes are in
use. Worth knowing what this is not: four digits is 10,000 combinations and
the photo files themselves sit unencrypted on disk like any other asset.
It's a lock against someone borrowing your phone, not encryption at rest.

## iCloud backup and the app's container

iCloud Drive backup needs a container registered against this app's App ID —
it lives on the developer account, not in the repo. `iCloud.com.example.photosVault`
is registered, `CODE_SIGN_ENTITLEMENTS` is wired into the Runner target, and
iCloud works.

If you ever change the bundle ID again, that pairing breaks: the new App ID
has no container, and every build fails with "provisioning profile doesn't
match the entitlements file's values". `xcodebuild -allowProvisioningUpdates`
does not create containers; only Xcode's UI or the developer portal does.
Re-register before building: open `ios/Runner.xcworkspace` → Runner target →
Signing & Capabilities → **+ Capability** → **iCloud** → tick **iCloud
Documents** → **+** under Containers.

Unregistered, the app still builds and runs — the iCloud row reads "This
build of the app isn't signed for iCloud" with its switch disabled, a state
it's written to handle.

## Screenshots

**Photo Library**
<img src="screenshot-photos.png" alt="Photo Library" width="200">

**Collections**
<img src="screenshot-collections.png" alt="Collections" width="200">

**Media Types & Utilities**
<img src="screenshot-utilities.png" alt="Media Types & Utilities" width="200">
