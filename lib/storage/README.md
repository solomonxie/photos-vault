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
