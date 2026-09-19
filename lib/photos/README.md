# photos

Gets bytes onto disk and into `../storage` — for files the user picks
manually, and for everything the app derives from them.

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
```

- `manual_add.dart` — file picker + hash-and-copy-in enqueue, shared by the
  manual "Add Files" flow and (T2.6) the share extension.
- `photo_editor.dart` — crop/rotate in pure Dart, off the calling isolate,
  re-encoded in the source's own format.
- `derived_asset.dart` — files edited bytes as a *new* library item carrying
  the source's date, description, tags, place, event, people and
  private-album membership. Every edit path (crop, rotate, AI touch-up) ends
  here, so the photo that was edited — and its backed-up copy — is never
  overwritten.
- `ai_image_edit_service.dart` / `ai_touch_up_queue.dart` — prompt + photo out
  to OpenAI/Google (the only configured vendors that return an image; others
  throw, so `runWithKeys` falls through to the next key), result back in as a
  derived asset. The queue outlives the screen that started the job.
- `person.dart` / `person_store.dart` — named `Person` profiles (bio fields,
  tagged photos, relationships, location history) behind
  `../viewer/people_screen.dart`; see DESIGN.md's "People profiles" section.
- `photo_library_change.dart` — parses one OS photo-library change
  notification into the asset ids that were created/updated/deleted, which
  `photo_library_service.dart`'s `applyChange` then touches *only those*.
  This is how the app keeps up with Photos while it's open: cost
  proportional to what changed, never to library size. The full `syncAll`
  scan is the backstop for changes made while the app wasn't listening.
- `photo_location.dart` — reverse-geocodes a photo's own GPS tag into a
  place name, so Places fills itself in. Run on view, one photo at a time:
  the OS geocoder is rate-limited per app, and it only ever fills an *empty*
  `AssetRecord.location` — a place the user typed is never overwritten.
- `library_metadata.dart` — the edits that belong to the photo rather than
  to this app, written to both the local record and the OS photo library:
  favourite and creation date, which is the whole list PhotoKit will accept.
  Caption/description/tags have no public write API on iOS and stay local.
- `on_device_vision.dart` / `on_device_analysis.dart` — face detection on
  the phone through Apple's Vision framework
  (`ios/Runner/VisionAnalysisChannel.swift`), run per photo from the
  viewer's People heading ("Find Faces"). Vision also classifies scenes;
  that half was tried against a real library and dropped, because the
  labels were wrong often enough that checking them cost more than typing
  the right tag. Tagging is `ai_vision_service.dart`'s job now.
- `thumbnail_cache.dart` — app-owned thumbnails. Stills are decoded here;
  videos (and anything `image` can't read) fall back to the photo
  library's own poster frame, which is what lets a video go cloud-only
  and still draw in the grid.
- `face_crops.dart` — cuts the detected faces out of a photo so each can be
  tapped and named. iOS finds faces for free but won't say whose they are,
  so the face is the question and the user is the answer.
- `library_scanner.dart` — the camera-roll re-read, on its own and out of
  sight. Not a row in the analyze queue and not configurable: nobody chose
  it and nobody pays for it, and a pause switch able to stop new photos
  arriving is one that breaks the app. One pass at a time, at most one
  every five minutes, forced on coming back from Photos.
- `asset_removal.dart` — the two ways a photo or video can go (cloud-only,
  or into Recently Deleted) and which of them a given asset is eligible
  for. One place, because that eligibility is a property of the photo, and
  every grid screen working it out for itself is how Favorites ended up
  offering a plain delete for something the library offered to keep.
  Also the third way, which isn't a choice: a photo with no bucket copy,
  no cached thumbnail and no file left anywhere is dropped outright rather
  than binned — Recently Deleted would only hold an empty tile with
  nothing to recover.
- `storage_advice.dart` / `storage_optimizer.dart` — what's costing space and
  what to do about it, behind `../viewer/storage_optimization_screen.dart`.
  The scan is metadata-only for camera-roll assets (`AssetEntity.fileSize`
  reads `PHAssetResource.fileSize`), so sizing a ten-year library pulls
  nothing down from iCloud. The two re-encode fixes rewrite the local copy
  in place — offered for backed-up assets alone, so the bucket still holds
  the full-quality original, and they leave `backedUpHash` matching the new
  local file so the next change check doesn't upload the shrunken one over
  it. Findings are filed in app state (`storage_scan_v1`) so the page opens
  on last time's answer rather than re-walking the library every visit.
