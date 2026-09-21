# lib

```text
main.dart ── runApp(App())
        ▼
app.dart:App — CupertinoApp + dark Material bridge (Settings is Material)
        │           over every page: viewer/scroll_stop_guard.dart
        │ home:
        ▼
viewer/LibraryScreen
```

Subfolders:

- [`viewer/`](viewer/README.md) — screens & navigation; start here for the UI
- [`storage/`](storage/README.md) — local sqlite asset-record store
- [`photos/`](photos/README.md) — manual add, editing, on-device analysis
- [`upload/`](upload/README.md) — fan-out upload of derivatives to S3
- [`backup/`](backup/README.md) — app-data snapshot: local, iCloud Drive, bucket
- [`settings/`](settings/README.md) — S3 backup target config + secure storage
- [`vault/`](vault/README.md) — hidden photos as encrypted carriers in the bucket
- [`l10n/`](l10n/README.md) — ARB strings + generated localization bindings
