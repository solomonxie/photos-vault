# Photo backup to a bucket you own

Photos Vault is a Flutter app (iOS first, Android backlog) that backs up Photos/Videos to your own bucket — AWS S3, Tencent COS or Alibaba Cloud OSS — with thumbnail-first browsing and storage tiering via your bucket's own Lifecycle Rules. Localized (English, Mandarin) from the start.

Design: `docs/design/DESIGN.md`
UI/UX: `docs/design/UIUX-DESIGN.md`
Plan: `docs/design/IMPLEMENTATION_PLAN.md`

## Setup

```
./scripts/bootstrap-flutter.sh   # clones Flutter SDK locally into .tools/, no system install
.tools/flutter/bin/flutter run
```

Or, if you already have Flutter installed system-wide: `flutter run`.

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
it lives on the developer account, not in the repo. `iCloud.com.solomonxie.photosVault`
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
