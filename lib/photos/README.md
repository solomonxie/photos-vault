# photos

Gets bytes onto disk and into `../storage` — for files the user picks
manually, and for the bundled demo assets that make the app immediately
tryable.

```text
ManualAddService.pickAndEnqueue()
  │ opens system file picker (file_picker)
  ▼ for each picked file
enqueueFile(path)
  │ sha256(file bytes) ──► localId = 'manual:$hash'
  ▼
copy into app-owned dir (path_provider), named `$hash.ext`
  │ no-op if already there — re-adding same content is idempotent
  ▼
AssetRecordStore.upsert(sourceType: manualFile, sourcePath: owned.path)
                                                ../storage/asset_record_store.dart

DemoAssetsService.addAll()
  │ for each assets/demo/*.jpg|mp4        (rootBundle)
  ▼
write bytes to scratch targetDirectory (OS temp dir — not persisted here)
  ▼
ManualAddService.enqueueFile(scratchPath)   ── same hash-named/dedup path as above
```

- `manual_add.dart` — file picker + hash-and-copy-in enqueue, shared by the
  manual "Add Files" flow and (T2.6) the share extension.
- `demo_assets_service.dart` — unpacks bundled demo photos/videos through
  `ManualAddService`; re-running `addAll()` after a demo item is deleted
  brings it right back (same content hash ⇒ same `localId`). Also seeds a
  demo Private Album (passcode `1234`) and three demo `Person` profiles with
  relationships/location history, same idempotent-by-fixed-id trick.
- `person.dart` / `person_store.dart` — named `Person` profiles (bio fields,
  tagged photos, relationships, location history) behind
  `../viewer/people_screen.dart`; see DESIGN.md's "People profiles" section.
