# 03 Vault & backup: findings

Scope: `lib/vault/`, `lib/backup/`, plus the callers that decide hidden-photo state (`viewer/private_album_gate.dart`, `viewer/private_album_screen.dart`, `photos/library_custody.dart`, `upload/backup_coordinator.dart`, `settings/app_data_removal.dart`).
This was a read-only review and nothing was run. Device evidence comes from a copy of `/tmp/pv_pull2/photos_vault.db` (`/tmp/pv_review03/`): 127 hidden rows across 3 passcode hashes, and 4 adopted `manual:vault-*` rows. No key, hash or passcode values are recorded here.

## P0

**1. Every hidden photo's row, its reversible passcode hash and its carrier key leave the gate in every app-data copy.** CONFIRMED
`backup/app_snapshot.dart:217-218, 259-303` (export has no hidden filter); `backup/local_vault.dart:183-193` (zip in Documents); `ios/Runner/Info.plist:45,98` (`UIFileSharingEnabled`, `LSSupportsOpeningDocumentsInPlace`); `Info.plist:55` (iCloud folder `IsDocumentScopePublic`); `storage/passcode_hash.dart:8`; `backup/change_log.dart:65-91`
- `export()` writes every hidden record in full:
  - `passcodeHash`, which is unsalted `sha256(4 digits)`. All 3 device hashes reverse in 10,000 tries.
  - `createdAt`, lat/long, tags, captions.
  - `uploads[].key` and `derivatives`, i.e. the carrier's exact bucket key.
  - person and album memberships.
- The change log (whole row before and after, last 5000 in the zip) keeps hidden rows even after a "permanent" delete.
- Destinations:
  - the daily zip in Documents, visible in the Files app and over USB
  - the raw `.db` copies (AppSupport, in the device backup)
  - the public iCloud Drive folder
  - `app-data/` in the bucket (never pruned)
  - pre-deletion copies, which are still written when the user picks "remove including hidden"
- Scenario: someone holding the unlocked phone opens Files → Photos Vault → the zip → `library.json`. They count the hidden photos, read their dates and places, and reverse the codes. Typing a code opens the album in the app, because the master key is already in the keychain.
- In the bucket, `uploads` labels which objects are carriers and groups them by album. That undoes the decoy for anyone holding the bucket.
- The README accepts "date, name" in the snapshot. It does not cover the Files-app gate bypass, the reversible codes or the carrier labelling. DESIGN.md "What's wrong today #5" lists this exact problem.
- Fix:
  - Leave hidden rows out of `export()`, the change log (trigger `WHEN NEW.passcode_hash IS NULL`) and the raw copies. If they have to be restorable, seal them under the album key as `hidden_note` and person `sealed` rows already are.
  - Replace `passcodeHash` with an HMAC under a keychain-held key.

**2. Plaintext hidden originals and thumbnails sit in a directory that iOS backs up.** CONFIRMED (code + DB)
`photos/library_custody.dart:300-322` (copy-out to the `getApplicationSupportDirectory()` root); `vault/filed_photos.dart:235-242` (`hidden_<base>.<ext>`, same root); `vault/store.dart:101-109` (only `vault/` is excluded)
- Hidden originals now stay on the phone as plain files. They are written to the AppSupport root, which iOS includes in the device/iCloud backup, under telling names (`hidden_…`, `<localId>-IMG_1234.HEIC`).
- `thumbnail_cache.dart:160-167` itself says AppSupport "would ride into the owner's own iCloud backup".
- Hiding never removes the existing plaintext `thumbnails/photo_*.jpg`. `ensureFor` only deletes it if it is called again, and `needingThumbnails` skips rows that already have a path. Device: **8 of 127 hidden rows still have `thumbnail_path`**.
- Fix: keep hidden plain files under `vault/plain/` (backup-excluded, neutral names), and move them on hide and back on un-hide. Call `ThumbnailCache.remove` in `hideIntoPrivateAlbum`, and add a one-time sweep for hidden rows that still have a thumbnail.

**3. Hidden photos show outside the gate in Favorites and on person pages.** CONFIRMED (path); device has 0 hidden favourites, people DB not checked
`viewer/favorites_screen.dart:35-40`; `viewer/person_page_screen.dart:63-67`; `viewer/person_avatar_picker.dart:43-47`
- `listAll()` includes hidden rows (`storage/asset_record_store.dart:1590`). These three screens filter only `!isDeleted`, while home and `album_screen.dart:117` also filter `passcodeHash`.
- Hiding does not clear `isFavorite` or person memberships (`private_album_gate.dart:567-569`).
- Scenario: favourite a photo or tag a face, then hide the photo. It still opens from Favorites or the person's page with no code. These screens are outside `PrivacyShield`, so it also shows in the app-switcher snapshot.
- Fix: one `isVisibleInLibrary(r)` predicate (`!isDeleted && !isHidden && passcodeHash == null`) used by every library-side screen.

**4. Since 9d98f57 nothing writes `index.bin`, so a new phone cannot open hidden photos even with the passphrase.** CONFIRMED (path); bucket not checked
- Writers: `writeAlbum` / `keepIndex` run only from `HiddenBucketScan` (manual "Find in bucket", and only when something is found), `HiddenMigration` (old names) and `HiddenRemoval._unlist` (filed entries).
- The filing step that used to publish the index was removed (`git show 51e2fbf`, `9d98f57`), and `emptyIndex` has no caller.
- What fails on a new phone:
  - The salt, verifier and hint of a passphrase set under the current model exist only in this phone's keychain.
  - On a new phone, `showVaultSetupSheet` → `VaultKeys.add` mints a **new salt** (`keys.dart:115`), so typing the old passphrase derives a key that opens nothing. The doc comment at `passphrase_sheet.dart:1-7` says the opposite.
  - "Add passphrase" takes its candidates only from the bucket's index (`private_album_screen.dart:1349-1357`), and there may be none.
- Also false: "every install writes one, so its presence says nothing" (`bucket.dart:134-136`, vault README). `index.bin` now exists only in the buckets of people who use hidden albums.
- Partly mitigated: the keychain uses the default accessibility (not `ThisDeviceOnly`, `settings/secure_store.dart:13`), so an encrypted iCloud *device* restore brings the master key back. Restoring from the bucket only, which is the app's promise, does not.
- Fix:
  - Publish an index (an empty section is fine) on `VaultKeys.add` and at the first launch with a bucket, for every install.
  - In setup, try every known or bucket entry with `unlockEntry` before minting a new salt.
  - Fallback: build a `PassphraseEntry` from a carrier header's `masterSalt`, and verify it by opening that carrier.

## P1

**5. HiddenMigration deletes the old name in every bucket even where the copy was skipped.** CONFIRMED (path), PLAUSIBLE (trigger)
`vault/hidden_migration.dart:52-58, 70-73, 102-107`
- `sizeOf(from) == null` (a timeout as well as a 404, see 02 #20) skips that target, and only the still's copy is required.
- Afterwards, `_ops.delete` removes every old key, including the `.mov`, on **every** target, directly rather than through `PendingDeletes`, and ignores the results.
- Scenario: a filed Live Photo with only a bucket copy. The HEAD for its `.mov` times out, the still migrates, and the old `.mov` is deleted. The motion is gone for good, and `hasMotion` points at a key that doesn't exist.
- With 2 buckets, a timeout on B deletes B's copy, and B never gets the new name.
- Fix: track the copy per (pair, target) and delete an old key on a target only after a HEAD of the new key there matches its size. Treat unknown as "keep".

**6. An adopted filed photo keeps its index entry, so a deleted or un-hidden photo comes back.** CONFIRMED (device: 4/4 adopted rows)
`vault/filed_photos.dart:106-110, 124`; `vault/hidden_removal.dart:70-99`; `private_album_screen.dart:680, 586-600, 397-401`; `upload/object_keys.dart:56-57`
- `adopt` stores the **relative** index key as `destinationKey` with no `backedUpHash`. A later change check re-uploads the photo under `hiddenBaseName(localId)`.
- Device: all 4 `manual:vault-*` rows have `original_key = originals/<A>`, while `derivative_target` names a different `photos-vault/originals/<B>`. That is two carriers per photo.
- Delete (`_delete` passes `records` only):
  - Nothing unlists `<A>`.
  - `remoteKeyFor` returns the held `<B>`, so the `<A>` carrier stays in the bucket.
  - The entry then has no row (`_entriesWithoutRows`), and tapping its tile re-adopts the deleted photo.
- Un-hide (`_removeManyFromAlbum`) has the same gap. The un-hidden photo reappears in the album, and re-adopting it upserts the **same** `localId`, which re-hides the library row.
- Fix:
  - `adopt`: record the resolved per-target key, `backedUpHash` and a `derivative_target` row.
  - Delete and un-hide: unlist every index entry matching `_keysOf(record)`, and queue deletes for both the record's key and the held keys.
  - One-time repair for existing adopted rows.

**7. A torn local index write is pushed to every bucket.** PLAUSIBLE
`vault/store.dart:141-147` (in-place `writeAsBytes`); `vault/bucket.dart:197-203, 234-246`; `vault/album_index.dart:194-196`
- `keepIndex` rewrites a 2.1 MB file in place. If the app is killed mid-write while the `unpublished` flag is set (an offline edit earlier), `currentIndex` returns the short file and `pushIndex` PUTs it to every bucket.
- That wipes every album's listing and, if the cut falls inside the header, every passphrase entry.
- The next `writeSection` sees a short index and fills the other 31 slots with random bytes.
- Fix: write to a temp file and `rename`. Refuse to push or merge any index whose length is not `indexBytes`.

**8. Fresh-install restore loses metadata when it takes longer than 10 s.** PLAUSIBLE
`viewer/library_screen.dart:793-800`; `backup/app_snapshot.dart:308`; `icloud_backup.dart`, `bucket_backup.dart` `restoreIfFreshInstall`
- The restore is capped at 10 s and then keeps running. Meanwhile `_scanRecentThenAll` inserts rows for every library photo.
- The fresh-install check already passed, so the import runs, but it is add-only and skips every existing `localId`.
- Result on a cold reinstall: captions, tags, favourites, locations and upload state (the whole library is re-uploaded) are lost for all photos still in Photos.
- Also: iCloud is tried first, and if it returns anything the bucket is never asked, even when the bucket's copy is newer.
- Fix: hold the scan until the restore finishes (show progress), or merge on import (fill empty fields, take derivative state). Pick the newer `exportedAt` across destinations.

**9. "Remove All App Data" with hidden kept orphans un-backed-up hidden photos in plaintext.** CONFIRMED (path)
`settings/app_data_removal.dart:91-95, 183-191`
- A hidden photo that isn't fully backed up keeps its plaintext file (`_onlyCopies`), but its row is wiped. Under the current model it has no local carrier (`keepCarrierLocally: false`) and no index entry.
- Nothing lists it any more, and it sits in plaintext in the backed-up container. The dialog says hidden photos are "kept, encrypted".
- Fix: before the wipe, build and store carriers for un-backed-up hidden photos (`putCarrier` + index entry + `setUnsent`). Otherwise refuse the wipe until they are backed up.

**9b. Un-hiding can upload the plain photo over its own carrier key, and leaves the `.mov` under the carrier name as an orphan.** CONFIRMED (device), lead from step 04
`viewer/private_album_screen.dart:586-600`; `viewer/private_album_gate.dart:380-399` (`resetBackupAfterUnhide`); `upload/backup_coordinator.dart:69-81, 272-280` (`safeFileName` with `previousKey`)
- How it happens:
  - `_removeManyFromAlbum` clears `passcodeHash` **first**, so `canUpload` turns true at once.
  - `resetBackupAfterUnhide` only then clears `destinationKey` and the upload rows, after several awaits (keychain, `heldKeysOf`, `DeferredDeletes.add`).
  - It **returns early and clears nothing** when `sourcePath` is null or the file is missing (`:385`).
  - Any upload in that window, or any later upload in the early-return case, reads `previousKey` = the carrier key. `safeFileName` keeps its stem, so the plain file goes to `originals/<carrierStem>.<ext>`.
  - Still carriers are always `.jpg`, so a plain JPEG lands on **the same key and overwrites the carrier**. A HEIC lands beside it, and `_leftovers` / `superseded` then queue the carrier for deletion.
  - The motion half follows the same path to `<carrierStem>.mov`.
- Device `photo:EA10C64A…`:
  - Its own ordinary base is `20261006162802_30d63754…` (matches its thumbnail and live keys).
  - Its `original` points at `20250616032353_1237bd5a….jpg`. That stem is no record's ordinary name (checked against all 4514 localIds), and its date falls in the 2012–2026 decoy range. That fits a hidden base name.
  - `.jpg` was written 2026-10-11 16:07:19 (7.5 MB, plain `_exif.jpg` source). `.mov` was written 16:07:39 (3.9 MB).
  - The `livePhoto` key was later moved to the ordinary base (21:27:17). So **`<carrierStem>.mov` is an unreferenced orphan holding the plain motion**, which is 02 #4's re-offered object.
  - The carrier objects were replaced, not kept. The change log for this row has been pruned, so the exact trigger (race vs early return) can't be read from the device.
- Impact:
  - Any other album index or device listing that carrier key now gets a plain JPEG, which `openCarrier` rejects. Its hidden copy is gone.
  - The plain photo sits under a carrier-shaped, decoy-dated name.
  - `DeferredDeletes` drops the carrier delete as "held by the photo", so the leftover `.mov` is never cleaned up.
- Fix:
  - Reset the derivative state and upload rows **before** clearing `passcodeHash`, in one transaction, and do it even when the file is missing (keep the old keys only for the deferred delete).
  - `safeFileName` must never reuse a stem that `fitsProtocol` as a hidden name for a record with `passcodeHash == null`. Always use `ordinaryBaseName` after an un-hide.
  - One-time repair: rows whose key stem ≠ `ordinaryBaseName` and matches no other record. Queue the unreferenced `<stem>.mov` for review rather than auto-delete.

## P2

**10. Hidden notes are never backed up.** CONFIRMED
`backup/app_snapshot.dart:181-223`: `hidden_note` isn't exported. Notes are lost on reinstall or a new phone; only the raw local `.db` copies hold them. Export the sealed rows as they are, the way person `sealed` rows go.

**11. `FiledPhotos.adopt` marks the photo backed up with no live check.** PLAUSIBLE
`filed_photos.dart:75, 105-124`
- The only check is `!isUnsent(still)`. `isUnsent(motionKey)` isn't checked, and the local carriers are deleted.
- A carrier the bucket lost (cf. Oct 13) is never re-sent, because `isFullyBackedUp` is true and `HiddenBackup` skips it.
- Fix: HEAD every target before writing `uploaded`, otherwise leave it `pending`.

**12. `sendBackToBucket` deletes the only local carrier after checking one bucket.** PLAUSIBLE
`gallery.dart:266-270`
- `thumbnailPrefix` returns on the first target that answers. With 2 buckets, B may lack the carrier.
- Fix: require `!isAbsent` on every target (a HEAD per target).

**13. Whole carriers are downloaded through Dart `http` into memory, with no timeout.** CONFIRMED
`vault/bucket.dart:118-132, 316-372`
- Affected: `object`, `fetch`, `loadIndex`, and `thumbnailPrefix` (a 64 KB range read, which is fine).
- A hidden video (filed or bucket-only) is pulled as `bodyBytes` on the UI isolate. `VaultCache.read/write` (`cache.dart:79, 106`) then runs CTR over it on the UI isolate (2 GB video pool).
- This breaks the native-transfer rule, and the album open (`currentIndex`) can hang with no timeout. Cross-ref 02 #7.
- Fix: `S3Downloader` to a file, decrypt in an isolate, and add a `.timeout` on index reads.

**14. A permanent delete can leave the carrier in the bucket.** PLAUSIBLE
`hidden_removal.dart:103, 133-141`
- `_loadTargets` returns `[]` on a keychain error. Filed `sentKeys` then produce zero tasks (unlike `deletionTasksFor`, which keeps a wildcard), and the rows and index entry are already gone.
- "Find in bucket" re-adds the photo.
- Fix: use target-less wildcard tasks, as `deletionTasksFor` does, or fail the delete.

**15. Bucket restore reads only the first listing page of the never-pruned `app-data/`.** PLAUSIBLE (long-term)
`bucket_backup.dart` `_latestSnapshotIn` (`listing.page`)
- After about 1000 objects (roughly 2.5 years of dailies), the newest archives are on later pages, and a restore picks a stale one.
- Fix: page through, or list with a start-after for the current year.

## P3

16. The index section MAC covers only the ciphertext, not the IV or tag (`album_index.dart:218-226`). It is integrity-only, but cheap to fix. The comment says "section × 16" while the code has 32. A slot collision (`tag[0] % 32`, about 9% for 3 albums) makes `HiddenBucketScan` rebuilds of two albums evict each other in turn.
17. The ring saves an album key for **every code typed**, wrong ones included (`keys.dart:234-245`). The keychain JSON grows, and `HiddenBackup` runs a `forPasscodeHash` query per entry. Only add a code to the ring once it has records or entries. Also, the keychain accessibility is the default, not the `ThisDeviceOnly` that DESIGN.md:488 states. Decide which, and fix the code or the doc.
18. PBKDF2 at 600k iterations runs synchronously on the UI isolate (`keys.dart:116, 137`, from the sheet buttons). That is a visible freeze. Use `Isolate.run`.
19. `BackupExclusion` is set only when `vault/` is created, and the result is ignored (`store.dart:103-108`). If it failed once, it is never retried. `BackupExclusionChannel.swift:18` says Dart sets it every open.
20. Docs drift:
    - DESIGN threat model "imaging the phone: nothing is there to find" and "no database row".
    - `_loadFromBucket` comment "a hidden photo's record is deleted the moment its carrier is confirmed".
    - Both predate the ordinary-row model.
21. `VaultBucket.fetch` reports `absent: true` with zero targets (`bucket.dart:335`). If the keychain read fails during `HiddenRestore`, a Live Photo is restored as a still (`hidden_restore.dart:54`).

## Step-02 lead (carriers mistaken for photos): vault side

- Carriers of current hidden rows are `referenced`, so `BucketFlags.detect` skips them before any probe.
- At risk:
  - Off-protocol carriers (v1 or old names). `HiddenMigration` renames them only while their album is open, 20 per run, so they wait in the bucket as `offProtocol` and hit 02 #1 and #3.
  - #6's orphaned `<A>` carriers, which are protocol-named and unreferenced. A failed probe there just skips them (`bucket_flagged.dart:278`), which is safe.
- Vault-side reads are safe:
  - `HiddenBucketScan` skips on a failed probe.
  - `rename` returns `needsAlbum` for an unknown salt.
  - `inspect` throws on a failed read.
- The gaps are `canReformat` and `rename` / `isCarrier` (02 #1 and #3).

## Improvement suggestions

- **One "library-visible" predicate** and one "hidden" predicate (`passcodeHash != null || isHidden`), used everywhere. #3 and 02 #23 are both drift between ad-hoc filters.
- **Hidden data has one home.** Plain files, the vault store and caches all go under the backup-excluded `vault/`. Snapshots carry hidden rows only sealed. The passcode tag is keyed, not `sha256`.
- **Publish `index.bin` unconditionally** (a fixed-size empty index on first bucket contact). This makes the decoy claim true and keeps passphrase recovery working.
- **Tri-state bucket answers** in the vault, as in 02: `sizeOf` and `thumbnailPrefix` stand for present / absent / unknown, and "unknown" never deletes or drops a local copy (#5, #12, #21).
- **Atomic file writes** for `index.bin`, the unsent markers and carriers (`putCarrierBytes`).
- Tests: hidden rows excluded from `export()`, Favorites and person pages; HiddenMigration with one HEAD failing; delete and un-hide of an adopted row; a torn index.

## Checked and fine

- AES-256-CTR with a random 16 B IV per encryption (carrier sections, cache, thumbnails, index, outbox names). There is no IV reuse, and the nonce only names objects.
- Encrypt-then-MAC: the carrier header is MAC'd with each section. MAC, locator and verifier compares use constant-time `bytesMatch`.
- PBKDF2 uses `kCCPRFHmacAlgSHA256 = 3`, 600k iterations, a 16 B salt. HKDF follows RFC 5869. The gate has no "wrong code" path.
- Carrier and decoy work (`CarrierBuilder`, `buildDecoyJpeg`, opens) runs in `Isolate.run`. Decoding goes through `decodePhoto`. Decoys are drawn only from non-hidden rows.
- Hidden photos never go up in the clear: `canUpload` and `_resolveUploadPath` return null without a ring key, and `_keepCarrierLocally` refuses the plaintext path.
- `_leftovers` retires siblings of the same video-ness only, so a Live carrier's `.mov` is safe.
- Hiding retracts existing plain bucket copies through `PendingDeletes`. Un-hiding defers carrier deletes until the plain copy is in every bucket.
- App switcher: `PrivacyShield` plus a native cover while a private screen is mounted. Everything above the library pops on pause.
- No logging of codes, keys or hidden names anywhere in `vault/`, `backup/` or the gate screens.
- `snapshot_index.csv` and `SnapshotSummary` exclude hidden rows.
- Remove All App Data seals against auto-restore, and `latestArchiveName` prefers the pre-deletion copy.
- `VaultStore` / `VaultCache` file names are HMACs under the album key. The cache has a TTL and LRU per pool.
