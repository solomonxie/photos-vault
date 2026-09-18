# Bring Your Own Photos

Flutter app (iOS first, Android backlog) that backs up Photos/Videos to your own bucket — AWS S3, Tencent COS or Alibaba Cloud OSS — with thumbnail-first browsing and storage tiering via your bucket's own Lifecycle Rules. Localized (English, Mandarin) from the start.

Design: `docs/design/DESIGN.md`
UI/UX: `docs/design/UIUX-DESIGN.md`
Plan: `docs/design/IMPLEMENTATION_PLAN.md`

## Setup

```
./scripts/bootstrap-flutter.sh   # clones Flutter SDK locally into .tools/, no system install
.tools/flutter/bin/flutter run
```

Or, if you already have Flutter installed system-wide: `flutter run`.

### iCloud backup needs this app's own container registered once

Everything for it is here — `ios/Runner/Runner.entitlements`,
`ICloudDriveChannel.swift`, the Dart side. What's missing is one thing that
lives on the developer account rather than in the repo: an iCloud *container*
registered against this app's App ID.

The sibling apps each have one, which is what makes iCloud work in them:

```
REPLACE_WITH_YOUR_TEAM_ID.com.solomonxie.buildyourownbudget -> ['iCloud.com.solomonxie.buildyourownbudget']
REPLACE_WITH_YOUR_TEAM_ID.com.solomonxie.byopo             -> ['iCloud.com.solomonxie.byopo']
REPLACE_WITH_YOUR_TEAM_ID.com.solomonxie.novelman          -> ['iCloud.com.solomonxie.novelman']
REPLACE_WITH_YOUR_TEAM_ID.com.solomonxie.backYourOwnPhotos -> []          ← this app
```

(Read back out of the profiles in `~/Library/Developer/Xcode/UserData/Provisioning Profiles`.)

The empty array is why the app reports itself unentitled and the switch stays
off, and why adding `CODE_SIGN_ENTITLEMENTS` without doing this first breaks
*every* build with "provisioning profile doesn't match the entitlements
file's values". `xcodebuild -allowProvisioningUpdates` does not create
containers; only Xcode's UI or the developer portal does.

To register it: open `ios/Runner.xcworkspace` → Runner target → Signing &
Capabilities → **+ Capability** → **iCloud** → tick **iCloud Documents** → **+**
under Containers and accept `iCloud.com.solomonxie.backYourOwnPhotos`. Xcode
writes `CODE_SIGN_ENTITLEMENTS = Runner/Runner.entitlements` into the target
itself, which is the line deliberately left out of the project until then.

Until it's registered the app builds and runs as before, and the iCloud row
reads "This build of the app isn't signed for iCloud" with its switch
disabled — the state it's written to handle.

## Screenshots

**Photo Library**
<img src="screenshot-photos.png" alt="Photo Library" width="200">

**Collections**
<img src="screenshot-collections.png" alt="Collections" width="200">

**Media Types & Utilities**
<img src="screenshot-utilities.png" alt="Media Types & Utilities" width="200">
