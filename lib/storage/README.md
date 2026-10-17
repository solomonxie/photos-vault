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

getByLocalId() / getByLocalIds() route every row through:
  _healed(record)                                asset_record_store.dart:_healed()
    │ a record whose sourcePath no longer exists on disk
    ▼ re-resolve by filename under _appSupportDirectory()
    UPDATE source_path if the healed path exists; else return unchanged
```

`listAll()`: cached per row; each read fetches `rev > last` (a trigger-kept
counter, not a clock), patches the sorted list, same instance when nothing
moved. Deletes go through `remove`/`removeMany`. The cache is per
instance: a delete through another `AssetRecordStore` (background sync,
demo seed) is not seen by the UI's until it restarts. `libraryDelta(a, b)` says
whether more than upload state moved between two results (`shape`), and
whether anything Flagged Items reads did (`flags`: all but `updatedAt` and
pending <-> uploading). `changesBetween(a, b)`: the records that moved
(before/after pairs, last 4,096 changes), so screens patch what they derive
instead of a full pass; null when it can't say (fresh read, rows lost).
`listOf(ids)`: records from the cache in grid order, no row read.
Album and people stores: `changeStamp()` moves with any write (change-log
mark plus connection).

- `asset_record.dart` — the `AssetRecord` model (immutable, `_copyWith`-based
  `withX()` helpers) and the `DerivativeKind`/`UploadStatus` enums.
- `asset_record_store.dart` — the sqlite table, all reads/writes, and the
  stale-path healing above.
- `album_store.dart` — albums and their memberships, in their own db file.
- Hidden photos are ordinary rows tagged with `passcode_hash`; their
  journals (`hidden_transition`, `hidden_note`) live in this db. See
  `../vault/` and `../viewer/private_album_gate.dart`.
- `passcode_hash.dart` — the passcode tag (HMAC under a Keychain key; the
  tag doubles as the album id) shared by private albums and person-profile
  locks, and the old `sha256` form still read for upgrade. See
  `../vault/passcode_tags.dart`.

`asset_record.db` also carries a small `app_state` key/value table for flags
about the library as a whole — whether a restore has already run, and
which private albums are kept off the network
Keychain item **survives an uninstall** and this database doesn't — a flag
that outlives its records leaves a reinstalled app sure it has already done
something to data that's gone.
