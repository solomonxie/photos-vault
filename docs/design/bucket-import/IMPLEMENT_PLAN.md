# Bucket import: implementation plan

See `DESIGN.md` for why, `UIUX_DESIGN.md` for what it looks like.

## Phase 0: Done
- [x] T0.1 `scripts/import-to-bucket.sh`: upload folders, JPEG posters, stills to HEIC, videos as-is
- [x] T0.2 `BucketImport` + Cloud Settings "Import from Bucket" row, en/zh strings, filename-date test

## Phase 1: Naming and carrier v2
- [ ] T1.1 Name builders: ordinary `date_hex`, hidden `date_nonce+locator`, `isMine(name, macKey)` - see `lib/vault/object_key.dart`, `lib/vault/keys.dart` - depends: none
- [ ] T1.2 Carrier v2: header nonce, 8-byte locator, real date/size/video flag inside the encrypted thumbnail section; v1 still opens - see `lib/vault/carrier.dart` - depends: none
- [ ] T1.3 Carrier recogniser: JPEG prefix parse, MP4 top-level box walk (ranged 8-byte reads), header checks (version, lengths vs size, salt on our list) - see `lib/vault/jpeg_segments.dart`, `lib/vault/mp4_boxes.dart` - depends: T1.2
- [ ] T1.4 Tests: own names accepted, other PIN/passphrase and ordinary names rejected, v1 and v2 round trip, recogniser rejects stray APP7/free - depends: T1.1, T1.2, T1.3

## Phase 2: Use the new names
- [ ] T2.1 Ordinary uploads pick the new name and store it in `destinationKey` - see `lib/upload/backup_coordinator.dart`, `lib/upload/signing.dart` - depends: T1.1
- [ ] T2.2 Filing builds the carrier under a hidden name and writes it into the index entry - see `lib/vault/hidden_filing.dart`, `lib/vault/carrier_upload.dart` - depends: T1.1, T1.2
- [ ] T2.3 Replace `vaultCarrierKey(record)` call sites with the stored key - see `lib/vault/hidden_removal.dart`, `lib/vault/hidden_restore.dart` - depends: T2.2

## Phase 3: Bucket listing in the db
- [ ] T3.1 `bucket_object` table + incremental listing in the cloud sync, off the UI isolate, skipped when unchanged - see `lib/storage/`, `lib/upload/backup_verifier.dart` - depends: none
- [ ] T3.2 `BucketImport` reads the table, imports only off-protocol non-carrier objects - see `lib/upload/bucket_import.dart` - depends: T3.1

## Phase 4: Hidden album scan
- [ ] T4.1 `HiddenBucketScan`: locator check over unclaimed protocol names, v2 header ranged GET, `IndexEntry`, `writeAlbum` - see `lib/vault/` - depends: T1.4, T3.1
- [ ] T4.2 "Find hidden photos in bucket" in the private album menu - see `lib/viewer/private_album_screen.dart` - depends: T4.1

## Phase 5: Flagged items
- [ ] T5.1 `FlaggedItem` model + detectors: off-protocol name, orphan thumbnail, missing thumbnail - depends: T3.1
- [ ] T5.2 Rename fix: classify with the recogniser, S3 copy, HEAD-verify, delete; hidden-format name from header for v2 carriers with a known salt; ordinary name otherwise; import record - depends: T1.3, T5.1
- [ ] T5.3 Re-format fix: only for verified non-carrier stills; download, convert via backup format, upload, verify, delete; size warning - depends: T5.1
- [ ] T5.4 Remove orphan / regenerate thumbnail - depends: T5.1
- [ ] T5.5 Flagged Items page replacing Optimize Storage: chips, select mode, menu badge, en/zh strings - see `lib/viewer/storage_optimization_screen.dart`, `lib/viewer/library_screen.dart` - depends: T5.1
- [ ] T5.6 Wire fixes into the page - depends: T5.2, T5.3, T5.4, T5.5

## Phase 6: Hide a cloud-only photo
- [ ] T6.1 Replace the refusal with: confirm, download, normal carrier build, verify, retract the plain copy; any failure keeps the cloud copy - see `lib/viewer/private_album_gate.dart` - depends: T2.2

## Phase 7: Close out
- [ ] T7.1 Full tests, format, analyze, release build, size check (`du -sh Runner.app`)
- [ ] T7.2 Docs: `lib/upload/README.md`, `lib/vault/README.md`, `docs/design/uiux/storage.md`
