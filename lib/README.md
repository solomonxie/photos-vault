# lib

```text
main.dart ── runApp(App())
        ▼
app.dart:App — CupertinoApp + dark Material bridge (Settings is Material)
        │ home:
        ▼
viewer/LibraryScreen
```

Subfolders:

- [`viewer/`](viewer/README.md) — screens & navigation; start here for the UI
- [`storage/`](storage/README.md) — local sqlite asset-record store
- [`photos/`](photos/README.md) — manual add + bundled demo assets
- [`upload/`](upload/README.md) — fan-out upload of derivatives to S3
- [`settings/`](settings/README.md) — S3 backup target config + secure storage
- [`l10n/`](l10n/README.md) — ARB strings + generated localization bindings
