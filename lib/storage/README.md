# storage

Local `sqflite` store for per-asset backup state — source of truth for what's
been uploaded, so a restart or killed background task resumes without
re-scanning from scratch.

```text
AssetRecordStore.upsert(localId, contentHash, platform, sourceType, sourcePath)
  │ opens/reuses db                              asset_record_store.dart:_open()
  ▼
existing = getByLocalId(localId)
  │ row ──► AssetRecord                          asset_record.dart:AssetRecord
  ├─ found, sourcePath unchanged ──► return existing
  ├─ found, sourcePath changed   ──► UPDATE source_path/updated_at
  │                                  existing.withSourcePath()   asset_record.dart
  └─ not found ──► INSERT row ──► new AssetRecord(...)

getByLocalId() / listAll() route every row through:
  _healed(record)                                asset_record_store.dart:_healed()
    │ manualFile record whose sourcePath no longer exists on disk
    ▼ re-resolve by filename under _appSupportDirectory()
    UPDATE source_path if the healed path exists; else return unchanged
```

- `asset_record.dart` — the `AssetRecord` model (immutable, `_copyWith`-based
  `withX()` helpers) and the `DerivativeKind`/`UploadStatus` enums.
- `asset_record_store.dart` — the sqlite table, all reads/writes, and the
  stale-path healing above.
- `private_album.dart` / `private_album_store.dart` — passcode-gated hidden
  folders (Utilities' "Hidden" row); a join table over `asset_record`, same
  shape as `album_store.dart`, plus a `moved` flag per row (moved assets are
  also `setHidden(true)` by the caller; copied ones stay visible in the main
  library too). See `../viewer/private_album_gate.dart` and DESIGN.md.
- `passcode_hash.dart` — SHA-256 hashing shared by private albums (the hash
  doubles as the album id) and person-profile locks.

`asset_record.db` also carries a small `app_state` key/value table for flags
about the library as a whole (currently just "have the demo photos been
seeded"). They belong here rather than in secure storage because an iOS
Keychain item **survives an uninstall** and this database doesn't — a flag
that outlives its records leaves a reinstalled app sure it has already done
something to data that's gone.
