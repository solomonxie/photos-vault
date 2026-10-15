# 09 Cross-cutting audit — findings

Scope: repo rules from `CLAUDE.md` across `lib/` and `ios/Runner`, `pubspec.yaml`, size budget, release scripts, test gaps, and patterns repeated across 01–08. Read-only. Sizes come from the existing `build/ios/Release-iphoneos/Runner.app` (Oct 14 16:27); nothing was rebuilt.

Counts: P0 0 · P1 1 · P2 3 · P3 5. Most rule violations were already filed in 01–08. They are cross-referenced in "Already filed", not re-filed.

## P1

**1. Fresh-install iCloud restore reads a file that isn't on the phone yet.** PLAUSIBLE
`ios/Runner/ICloudDriveChannel.swift:250-279` (`readLatest`, `readLatestBytes`, `readBytes`), `:222-231` (`latestFile`), `:199-203` (`list`); Dart side `lib/backup/icloud_backup.dart:199-215`.
- Each read calls `startDownloadingUbiquitousItem` and then `Data(contentsOf:)` straight away. The download is only *requested*. On a new phone the archive exists only in iCloud, so the read returns nil.
- `contentsOfDirectory` lists a file that isn't downloaded yet as the placeholder `.<name>.icloud`. `latestArchiveName` / `pathExtension == "zip"` don't match it, so the listing comes back empty even before the read.
- Scenario: a user with iCloud copy on and no bucket gets a new phone and installs the app. `restoreIfFreshInstall` finds nothing and returns 0. Tags, captions, albums and people are lost. This is the one case the iCloud copy exists for. With a bucket, the bucket fallback hides the problem.
- Fix: list with `NSMetadataQuery` (or map `.X.icloud` names back to `X`). Read through `NSFileCoordinator.coordinate(readingItemAt:)`, which blocks until the download finishes, with a timeout. Return "downloading" instead of nil so Dart can retry.

## P2

**2. The daily app-data copy is built three times on the UI isolate, at `paused`.** CONFIRMED (code), PLAUSIBLE (impact)
`lib/viewer/library_screen.dart:544-551` → `local_vault.dart:186`, `icloud_backup.dart:98`, `bucket_backup.dart:130-147`; `snapshot_archive.dart:123-137`.
- Each destination runs its own `snapshots.export()` and `jsonEncode` of every row plus up to 5000 change-log entries. Each then runs `indexCsv` (twice in the bucket path, `:131-132`) and a pure-Dart `ZipEncoder` deflate, all on the main isolate. The three run concurrently.
- With tens of thousands of records that is several O(library) passes plus a deflate of a multi-MB JSON. When the user comes straight back, the first frames after `resumed` stall. iOS may also suspend the process mid-work, so the bucket `http.put` (no timeout, `bucket_backup.dart:141`) doesn't land. `recordSuccess` is then skipped and the whole thing repeats on the next `paused`.
- Fix: one export per pause, shared by all three destinations. Encode and zip it in `Isolate.run`. Wrap the work in a `beginBackgroundTask` (via the existing BackgroundSync channel) and put `.timeout` on the PUT.

**3. Size headroom is down to ~1 MB, and growth comes from the Dart snapshot.** CONFIRMED
- The current `Runner.app` is 32,260 KB (31.5 MiB; `du -sm` says 32). Against the 33 MB budget, `make size` would report "1 MB spare".
- `App.framework/App` is 8.14 MiB against the 7.7 MB baseline in `CLAUDE.md`, +0.45 MB in about two weeks of feature commits. `Runner` (plugin code) is 2.8 MB against 2.7.
- At this rate the budget is gone in a month. Nothing on the release path enforces it: `make release` → `check` → `scripts/release-ios.sh:37` only prints `du -sh`, and `make size` is never called.
- Fix: run `make size` from `release` and fail over budget. Run one `--analyze-size` build to find out what grew. Candidates to cut are in the dependency table below (`aws_*` and `uuid` on the Dart side; the 400 KB 1024px icon in `Assets.car`).

**4. Delete-safety tests run against a hand-written fake, and the real store's schema upgrades have no test.** CONFIRMED
- `test/support/fake_asset_record_store.dart` (564 lines, `implements AssetRecordStore`) re-implements `keyHeldByOthers`, `targetsHolding`, `listAll` and others in Dart. It is used by `pending_deletes_test`, `bucket_flagged_test`, `storage_optimizer_test`, `app_data_removal_test`, `photo_library_service_test` and 47 other files.
- The real SQL (`asset_record_store.dart:869-881`, a UNION over `derivative_target` and four key columns) is never run against those scenarios. `keyHeldByOthers` appears in no test outside the fake.
- `asset_record_store.dart:66-77` is at schema `version: 19`. No test opens a v1..v18 database and upgrades it; only `person_store` and `ai_analysis_store` have migration tests. 01 #10 (the v16 `_adoptExistingUploads` no-op) is exactly what such a test would have caught.
- Scenario: a SQL change to `keyHeldByOthers` (a column added, `except` semantics changed) passes every delete test, because the tests exercise the fake. The bucket then loses originals, as in the Oct 13 incident.
- Fix: a shared contract test suite run against both the fake and the real store (sqflite_common_ffi, already a dev dependency). Add an upgrade test that builds each historical schema and checks that `onUpgrade` gives the same `sqlite_master` as `onCreate`. See test list #1–#2.

## P3

**5. Release symbols live only under the gitignored `build/`.** CONFIRMED
`scripts/release-ios.sh:27`, `Makefile:55,68`. `flutter clean` or `rm -rf build` deletes every shipped build's symbols, and crash reports from obfuscated builds are then unreadable. `make build` also writes to the flat `build/symbols`, overwriting it each time. Fix: copy `$SYMBOLS` to a durable place outside `build/`, keyed by build number (for example next to the `.xcarchive` in `~/Library/Developer/Xcode/Archives`).

**6. `make archive` evaluates `date` twice.** CONFIRMED
`Makefile:66-68`: `--build-number=$$(date …)` and `--split-debug-info=build/symbols/$$(date …)` are separate calls. Across a minute boundary the symbols directory no longer matches the build number. Fix: `BUILD=$$(date …); … $$BUILD` once, as `release-ios.sh` does.

**7. Gallery's isolate fallback also catches errors thrown by the work itself.** PLAUSIBLE
`lib/vault/gallery.dart:170-176`.
- `on ArgumentError` is meant for "closure not sendable" (test doubles). `RangeError` is a subclass of `ArgumentError`, and so is `cipher.dart:235-236`.
- A truncated carrier over 1 MB can make `_locatorMatches` / `sublistView` (`carrier.dart:327-334`) throw `RangeError` in the isolate. The fallback then re-runs `readAsBytesSync` + MAC + decrypt of the whole file on the UI isolate, and that throws again uncaught.
- Fix: decide sendability once, at construction, or catch only the send failure. Validate `payload.length >= header.length` in `openCarrier`.

**8. `LocalVault` directory scans are sync with no bound note at the call site.** CONFIRMED
`lib/backup/local_vault.dart:273-275, 304-308, 322-333`. `listSync`/`statSync` run on the UI isolate. `localCopies` stats inside the sort comparator: 2·n·log n stats. This is bounded by 7-day retention plus 3 pre-deletion sets (about 20 files), so it is cheap. The CLAUDE.md rule still wants the bound stated where it happens. Fix: stat once into a map, or use `list()`/`stat()`, or add the bound comment.

**9. `cupertino_icons`, `path_provider_platform_interface` and the Android-only plugin halves are fine, but `uuid` is a whole package for `v4()`.** CONFIRMED
7 call sites, all `const Uuid().v4()` (`backup_targets_store.dart:153`, `ai_settings_store.dart:97,130`, `s3_target_drafts_store.dart:59`, `album_store.dart:265`). Eight lines with `Random.secure()` replace it. Small win, zero risk.

## Already filed (rule violations found by grep, not re-filed)

| Rule | Site | Filed as |
|---|---|---|
| Sync I/O on UI isolate | `private_album_screen.dart:561` | 07 #22 |
| | `sync_engine.dart:516` | 02 #26 |
| | `storage_optimizer.dart:845,855`, `asset_removal.dart:408` | 04 #18 |
| | `main.dart:88-89` (screenshot hook) | 08 #16 |
| Dart `http` for bodies | `backup_verifier.dart:307-340`, `original_restore.dart:126-136`, `bucket_flagged.dart:738` | 02 #7 |
| | `vault/bucket.dart:118-132, 316-372` | 03 #13 |
| Decode on UI / full size | `detail_screen.dart:2369` (info panel), `photo_edit_screen.dart:55-66`, bucket preview | 06 #19, 07 #23, 08 #6 |
| PBKDF2 on UI isolate | `keys.dart:116,137` | 03 #18 |
| N+1 | `name_migration.dart:52-58` (`healPrefixes`), `bucket_flagged.dart:854,955` | 02 #13 |
| | `face_group_screen.dart:111-115,213-222` | 05 #16 / 07 #20 |
| | `profile_transfer.dart:41-63` | 05 #26 |
| | `person_avatar.dart:58` (query per build) | 07 #21 |
| O(library) per build/open | `library_screen` reload, layout | 01 #4, 06 #7, #11, #22 |
| | Flagged Items 4× `listAll` | 07 #14 |
| | person page / avatar picker `listAll` | 07 #29, #32 |
| Native thread safety | `FaceEmbedder.swift:33` lazy model | 05 |

## Systemic causes (one structural fix each)

1. **No single visibility predicate.** Every screen filters `listAll()` itself, and each one forgets a different column: `passcodeHash`, `isHidden`, `deletedAt` or `bucket:`. Instances: 03 #3, 05 #2, 07 #1, #2, #11, #27, 02 #23. → **Fix:** `AssetRecordStore` exposes `libraryVisible()` / `hidden(hash)` / `binned()` backed by one SQL `WHERE` (or a view). Raw `listAll` becomes private to the store, sync and backup. Add a lint/grep check in `make check` for `listAll(` under `lib/viewer/`.
2. **A cached or remembered answer is trusted for a destructive act.** Listing, page-load snapshot, swap file, or a selection read at tap time. Instances: 02 #5, #9, #10, #16, #17, #18, 03 #5, #12, 04 #8, #9, 07 #6, #8, #18. → **Fix:** one delete gateway per side. `BucketOps.deleteGuarded(target, key, keep:)` does a live HEAD of the keeper with matching size/ETag and refuses if any record or pending upload holds the key. `LibraryCustody.deleteOriginals(ids)` re-proves backup live just before the PhotoKit call. Every caller (BucketFixer, NameMigration, HiddenMigration, the browser, the optimizer, the bin purge) goes through them, and no other code may DELETE.
3. **"Unknown" collapses into "absent", "empty" or "false".** `catch (_) { return null; }` at I/O boundaries feeds decisions to delete, import or mark gone. Instances: 02 #1, #3, #11, #20, 03 #21, 04 #2, 05 #8, 07 #25, 08 #1. → **Fix:** a tri-state `Probe<T> = present(T) | absent | unknown` (as `CopyProof` already does) for bucket HEAD/size, Photos lookups, DB reads in destructive flows and keychain reads. Rule: `unknown` never deletes, never imports, never marks gone.
4. **Detector and fixer are separate code with separate predicates.** An item is "fixed" yet re-offered, or offered yet refused. Instances: 02 #4, 04 #3, #5, 07 #9, #13, #15, #25. → **Fix:** each flag kind is one object with `detect(record, ctx)`, `fix(record)` and `stillApplies` run live before acting. "Done" means the detector no longer reports it, checked after the fix. That is also the single-scan design PLAN 04 asks for: one scan produces the flags, and the fix queue consumes the objects.
5. **Multi-step work kept in memory or written non-atomically.** A kill or a second run in parallel corrupts it. Instances: 03 #7, #8, 04 #4, #5, #6, 05 #6, 06 #1, 07 #15, 01 #3. → **Fix:** (a) a durable step journal (sqlite table) for swaps, hide/unhide, migrations and restore, with idempotent steps replayed on launch; (b) `writeAtomic(path, bytes)` (temp + rename) used for every file the app reads back; (c) one `SingleFlight`/coalescing helper for `reload`, scans and rescans.
6. **Every screen recomputes the library on the UI isolate.** Instances: 01 #4, 06 #7, 07 #14, #29, #32, 02 #13, finding #2 above. → **Fix:** a `LibraryIndex` built once per change in `Isolate.run`: visible, favourites, videos, by-day, by-person, by-key, duplicates. Screens and Flagged Items read from it and never call `listAll`.
7. **Bodies over Dart `http` with no timeout.** Instances: 02 #7, 03 #13, finding #2. → **Fix:** one `BucketReader` that downloads to a file through `background_downloader` (`S3Downloader` already exists). Small JSON and index reads go through one `http` wrapper with a mandatory `.timeout`.
8. **In-app claims drift from code.** Instances: 05 #1, 08 #4, 03 #20. → **Fix:** a claims list next to the code (08 suggestion), and grep it in review.

## Dependencies

Size figures are rough AOT/native estimates; nothing was measured per package. Confirm with one `--analyze-size` build.

| Package | Used by | Est. cost | Keep / replace |
|---|---|---|---|
| `photo_manager` | camera roll, thumbnails (9 files) | large native + Dart | Keep (core) |
| `background_downloader` (+ `connectivity_plus`) | `s3_uploader.dart` | ~300 KB native | Keep (rule requires it) |
| `video_player` | viewer, Live Photos | AVFoundation plugin, small | Keep |
| `sqflite` | all stores | small (system sqlite) | Keep |
| `flutter_secure_storage` | `secure_store.dart`, demo | small | Keep. Could be own Keychain channel (~60 lines), low value |
| `image` | `image_pipeline`, editor, crops, decoy, export, demo | large if decoders leak; held down by `decodePhoto` | Keep; `encodeWebP`/`encodePng` keep two encoders alive. Use native `ImageEncodeChannel` for export and edit to drop them |
| `aws_signature_v4` + `aws_common` | `signing.dart`, `s3_listing`, `s3_connectivity`, `s3_object_delete` | pulls `built_value`, `built_collection`, `http2`, `json_annotation`, `os_detect`, `logging`, `mime`; estimate 300–600 KB AOT | **Replace**: SigV4 presign + header signing is ~120 lines on `crypto` (already a dependency). Best Dart-side size win |
| `http` | S3 control calls, AI, app-data | small | Keep |
| `crypto` | HMAC/SHA (6 files) | small | Keep |
| `ffi` (+ `objective_c.framework` 208 KB via `path_provider_foundation` 2.6) | `cipher.dart` CommonCrypto | 208 KB native | Keep `ffi`. `path_provider` (16 call sites, 4 functions) could be a 15-line channel and would drop `objective_c.framework` |
| `archive` | snapshot zip, `.docx` text | moderate; only the zip codec is reachable | Keep, or ~100 lines over `dart:io` `ZLibCodec`. Low value |
| `file_picker` | manual add, profile import, snapshot file | plugin + 6 platform packages | Keep (UIDocumentPicker channel ~60 lines; medium value) |
| `share_plus` | 4 call sites | small | Optional: `UIActivityViewController` channel ~25 lines |
| `url_launcher` | 4 call sites | small | Optional: `UIApplication.open` channel ~10 lines |
| `geocoding` | `photo_location.dart` (CLGeocoder) | small | Optional: the app already has Swift channels; ~30 lines |
| `uuid` | 7 × `v4()` | small (+`fixnum`) | **Replace** (P3 #9) |
| `intl`, `flutter_localizations` | l10n | needed | Keep |
| `cupertino_icons` | `CupertinoIcons` (217 uses) | 15 KB after font subsetting | Keep |
| `path_provider_platform_interface` | demo path scoping | ~0 (already linked) | Keep |

Other size notes: `SFace.mlmodelc` weights are already int8 (`constexpr_affine_dequantize`, 44 int8 tensors), so there is no cheap win left there. `Icon-App-1024x1024@1x.png` is 400 KB, most of `Assets.car`'s 768 KB; a lossless/quantised re-export could save ~300 KB (PLAUSIBLE). The 57×57 icons are dead at iOS 15. `flutter: assets:` is only `demo/seed.json` (12.5 KB, justified in `pubspec.yaml`). Every release path has `--obfuscate --split-debug-info`.

## Test gaps: the 10 most valuable tests to add

Untested risky modules (no test file, no test imports): `upload/sync_engine.dart`, `upload/s3_object_delete.dart`, `upload/object_keys.dart`, `upload/lost_originals.dart`, `upload/signing.dart`, `vault/hidden_migration.dart` (only touched by `hidden_bucket_scan_test`), `vault/cache.dart`, `vault/gallery.dart` remote path, `backup/icloud_drive.dart` (native side).

1. **Store contract suite on real SQL**: `keyHeldByOthers`, `targetsHolding`, `uploadRows`, hidden/binned filters, run against both `FakeAssetRecordStore` and `AssetRecordStore`+ffi (finding #4, 02 #18).
2. **Schema upgrade test**: build each historical `asset_record_store` schema v1..v18, upgrade, and compare against `onCreate`. Covers 01 #10 adoption.
3. **AppDataRemoval with a throwing DB read**: nothing is deleted, the operation aborts (08 #1).
4. **HiddenMigration per-target skip**: copy fails or is skipped on target B, so the old name on B survives (03 #5).
5. **Hide / un-hide ordering**: the plain bucket copy is deleted only after the carrier PUT is confirmed (07 #5). Un-hide never uploads over the carrier key (03 #9b). `unhide_backup_reset_test` covers only the reset.
6. **Optimizer swap journal**: kill between the PhotoKit delete and the record update, plus two concurrent Finish Optimize jobs. Replay never prompts to delete the copies, and no swap is lost (04 #4–#6).
7. **Library reconcile under uncertainty**: a failed or limited lookup never marks gone (04 #2). A record back in Photos leaves the bin, and the purge never deletes its bucket copies (04 #1).
8. **Flag parity property test**: for every flag kind, `fix` then `detect` returns nothing, and an "unknown" probe yields no fix (02 #3, #4, #20; 07 #13).
9. **Visibility test**: Favorites, person page, face group, "who else looks like this", Ask AI and People counts never include hidden or binned records (03 #3, 05 #2, 07 #1). One test per entry point against a seeded hidden favourite.
10. **New-phone recovery**: `index.bin` is published on first bucket contact and opens with the passphrase on an empty install (03 #4). Fresh-install restore plus concurrent scan yields no duplicates and keeps metadata (03 #8, 04 #10). The iCloud cloud-only case (finding #1) needs a device check; it can't be unit-tested.

Covered already (good): `cipher_test`, `album_index_test`, `keys_test`, `carrier*_test`, `pending_deletes_test`, `deferred_deletes_test`, `asset_removal_test` (purge), `bucket_flagged_test` (removeOldCopy/replaceRemoteOriginal/healPrefixes, on the fake), `index_publish_test`, `hidden_restore_test`, `app_data_removal_test`.

## Checked and fine

- No `package:flutter/material.dart` import anywhere in `lib/`; `uses-material-design: false`.
- No `img.decodeImage`. Every decode goes through `decodePhoto` (`image_pipeline.dart:9-33`).
- Every `image` encode/resize is off the UI isolate: `detail_screen.dart:443` (`compute`), `photo_editor.dart:30` (`Isolate.run`), `face_crops.dart:63` (`compute`), `decoy.dart:130` and `demo_seed.dart:76,134` (`Isolate.run`).
- `record_fixer.dart:174,251,388`: sync reads, but inside `Isolate.run`.
- `checkpointedFile` (`asset_record_store.dart:1019`, `album_store.dart:112`, `ai_analysis_store.dart:489`, `person_store.dart:386`): one `existsSync` per call, so "one is free".
- Photo and carrier uploads all go through `background_downloader` (`s3_uploader.dart`; `vault/bucket.dart:345`). Dart `http` PUTs are only `index.bin` (fixed size) and app-data (finding #2).
- `bucket_ops.rangeReader` uses ranged GETs with a 20 s timeout.
- Loops with an awaited query that are bounded and documented: `pending_deletes.release` (`:322-325` note), `NameMigration.run` (`limit` 25), `photo_library_service` deleted-ids per change event, `backup_verifier.repair` per loss.
- `sync_engine.pendingAndFailed` is O(library) but is read on queue-drain or trickle events, not in `build`.
- Native channels (`VisionAnalysis`, `ImageEncode`, `ICloudDrive`, `DocumentText`, `StillVideo`) dispatch work off the platform thread.
- `SFace.mlmodelc` is already int8-quantised. `flutter_assets` holds only `seed.json`, the subsetted icon font, NOTICES and two engine shaders.
- `Makefile` `build`/`archive` and `release-ios.sh` all pass `--obfuscate --split-debug-info`.
- `.env.demo` is gitignored and absent. The shipping risk is filed as 08 #5.
