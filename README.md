# Back Your Own Photos

Flutter app (iOS + Android) that backs up Photos/Videos to your own S3 bucket, with thumbnail-first browsing and storage tiering via your bucket's own Lifecycle Rules.

Design: `docs/design/photo-backup-app.md`
Plan: `docs/design/photo-backup-app-plan.md`

## Setup

```
./scripts/bootstrap-flutter.sh   # clones Flutter SDK locally into .tools/, no system install
.tools/flutter/bin/flutter run
```

Or, if you already have Flutter installed system-wide: `flutter run`.
