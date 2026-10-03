# Bucket import: implementation plan

See `DESIGN.md` for why, `UIUX_DESIGN.md` for what it looks like.

## Phase 0: Done
- [x] T0.1 `scripts/import-to-bucket.sh`: upload folders, JPEG posters, stills to HEIC, videos as-is
- [x] T0.2 `BucketImport` + Cloud Settings "Import from Bucket" row, en/zh strings, filename-date test

## Phase 1: Naming and carrier v2
- [ ] T1.1 Name builders: ordinary `date_hex`, hidden `date_nonce+tag`, `nameKey` derivation, `isMine(name, nameKey)` — see `lib/vault/object_key.dart`, `lib/vault/keys.dart` — depends: none
- [ ] T1.2 Carrier v2: real date, width, height, video flag inside the encrypted thumbnail section; v1 still opens — see `lib/vault/carrier.dart` — depends: none
- [ ] T1.3 Tests: tag accepts own names, rejects other PIN/passphrase and ordinary names; v1 and v2 round trip — depends: T1.1, T1.2

## Phase 2: Use the new names
- [ ] T2.1 Ordinary uploads pick the new name and store it in `destinationKey` — see `lib/upload/backup_coordinator.dart`, `lib/upload/signing.dart` — depends: T1.1
- [ ] T2.2 Filing builds the carrier under a hidden name and writes it into the index entry — see `lib/vault/hidden_filing.dart`, `lib/vault/carrier_upload.dart` — depends: T1.1, T1.2
- [ ] T2.3 Replace `vaultCarrierKey(record)` call sites with the stored key; un-hide and removal unchanged otherwise — see `lib/vault/hidden_removal.dart`, `lib/vault/hidden_restore.dart` — depends: T2.2

## Phase 3: Bucket listing in the db
- [ ] T3.1 `bucket_object` table + incremental listing in the cloud sync, off the UI isolate, skipped when unchanged — see `lib/storage/`, `lib/upload/backup_verifier.dart` — depends: none
- [ ] T3.2 `BucketImport` reads the table instead of listing; imports only objects that do not fit the protocol shape and are not carriers — depends: T3.1

## Phase 4: Hidden album scan
- [ ] T4.1 `HiddenBucketScan`: tag check over unclaimed names, ranged GET of the v2 header, build `IndexEntry`, `writeAlbum` — see `lib/vault/` — depends: T1.3, T3.1
- [ ] T4.2 "Find hidden photos in bucket" in the private album menu — see `lib/viewer/private_album_screen.dart` — depends: T4.1

## Phase 5: Flagged items
- [ ] T5.1 `FlaggedItem` model + detectors: off-protocol media, suspected carrier (APP7 sniff), unreferenced legacy name, orphan thumbnail — depends: T3.1
- [ ] T5.2 Fixes: rename-and-import (copy, HEAD-verify, delete), restore-to-hidden (locator match, rename to tag name, index), remove orphan, regenerate thumbnail — depends: T5.1, T4.1
- [ ] T5.3 Flagged Items page merging Optimize Storage, chips, select mode, menu badge, en/zh strings — see `lib/viewer/storage_optimization_screen.dart`, `lib/viewer/library_screen.dart` — depends: T5.1
- [ ] T5.4 Hook fixes into the page — depends: T5.2, T5.3

## Phase 6: Close out
- [ ] T6.1 Full tests, format, analyze, release build, size check (`du -sh Runner.app`)
- [ ] T6.2 Docs: `lib/upload/README.md`, `lib/vault/README.md`, `docs/design/uiux/storage.md`
