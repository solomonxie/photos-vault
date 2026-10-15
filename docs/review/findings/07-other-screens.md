# 07 Other screens

Scope: `lib/viewer/` minus step 06 files. Flagged Items (`flagged_items_screen`, `flagged_action_screen`, `flagged_copy`), `recently_deleted_screen`, `delete_confirmation`, `safety_screen`, `analyze_queue_screen`, people/person/profile/face screens, `album_screen`, `favorites_screen`, `asset_group_screen`, `asset_picker_screen`, `private_album_screen`, `private_album_gate`, `photo_edit_screen`, `resize_photos`, `ask_ai_screen`, `search_picker_sheet`, `built_in_album`. Callees read where they decide behaviour. Read-only; nothing run.

Counts: P0 4 · P1 8 · P2 12 · P3 11.

## P0

**1. Hidden and binned photos show outside the gate on Favorites, person pages, avatars and People counts.** CONFIRMED (extends 03 #3)
- Unfiltered (only `!isDeleted` or nothing):
  - `favorites_screen.dart:35-40`
  - `person_page_screen.dart:63-67`
  - `person_avatar_picker.dart:43-47`
  - `person_avatar.dart:58-60` draws `avatarLocalId`/`firstTaggedLocalId` with no visibility check (People list, profile, graph)
  - `people_screen.dart:112-116` counts and `firstPhoto` include hidden and binned members
  - `face_group_screen.dart:208-214`, `person_picker_sheet.dart:88-92` can make a hidden photo's face the avatar
- Filtered correctly: home `_activeOf` (`library_screen.dart:1309-1311`), `album_screen.dart:117-123`, `asset_picker_screen.dart:57-61`. Places, Videos and Recently Added get pre-filtered `_active` lists.
- Scenarios:
  - Favourite a photo, then hide it. It still opens from Favorites with no code. The home Favorites card counts N and the screen shows N+1.
  - People list says "Alice 12" while her page shows 10, which gives away 2 hidden photos.
- Fix:
  - Add one `isVisibleInLibrary(r)` predicate (`!isDeleted && !isHidden && passcodeHash == null`) on the store, plus `getVisibleByLocalIds`, and use it on every screen listed.
  - `PersonAvatar` falls back to the placeholder when the record isn't visible.

**2. Safety page "Check Now" gives away the hidden-photo count.** CONFIRMED
- `safety_screen.dart:107-116` leaves hidden rows out of its counts on purpose (see the comment there).
- `backup_verifier.dart:384-387` `reconcile()` counts every non-binned record, hidden carriers included. The page then shows `safetyCheckAllPresent(check.present)` (`safety_screen.dart:253-261`).
- Scenario: the phone row says "4387 photos" and the check says "all 4514 confirmed", so anyone holding the phone learns there are 127 hidden photos.
- Fix: `reconcile` skips `passcodeHash != null || isHidden` rows when it fills `present`, `expected` and `missingLocalIds`. Check hidden rows on a separate path whose numbers aren't shown here.

**3. Edits inside a person's sealed set are written to the open set in plaintext.** CONFIRMED
- The calls pass no namespace or keys, so the store falls back to `passcodeHash = openNamespace` (`person_store.dart:740, 829, 962`):
  - `person_profile_screen.dart:256` (`addHistoryEntry`)
  - `:259-280` (`PersonHistoryDetailScreen` is given no namespace or keys)
  - `person_history_detail_screen.dart:52-55` (`_persist` runs on every Notes keystroke)
  - `person_profile_screen.dart:556-563` (`addLocation`)
  - `:422-431, 463-466` (add/remove relationship)
- Rows are written with `ConflictAlgorithm.replace` keyed by id.
- Scenario: unlock a person's set, open a sealed job entry and type in Notes. The row is rewritten with `passcode_hash=''` and decrypted content. It now shows in the open profile and in the CSV export.
  - Removing a sealed relationship deletes the open-set row instead, so it looks as if nothing happened.
- Fix: thread a required `PersonScope(namespace, keys)` through every profile write, remove the store's `openNamespace` defaults so the compiler finds every call site, and add a regression test.

**4. Deleting a person leaves their hidden folder unopenable for good.** CONFIRMED (path)
- The folder's code is `person:<id>:<digits>` (`private_album_gate.dart:288`). `person_profile_screen.dart:722-748` deletes the person, and the id was a random UUID kept nowhere else.
- The photos stay hidden from the library, still take space, and their carriers stay in the bucket. No screen can reach them again.
- The dialog only says "If this person has a hidden folder…", so it relies on the user's caution (see the safe-by-default rule).
- Fix: check live before deleting. Hash `person:<id>:0000…9999` in `Isolate.run` against the distinct `passcode_hash` values; if a folder exists, block the delete until it is emptied. Alternative: tombstone the person id.

## P1

**5. Hiding deletes the plain bucket copy before the encrypted copy is up.** CONFIRMED (no gate), PLAUSIBLE (how long the window lasts)
- `private_album_gate.dart:669-677` → `_retractFromBuckets` (`:419-446`) queues `PendingDeletes` for every plain key right after `takeOutMany`.
- `PendingDeletes.drain` only checks that the key is no longer referenced. Nothing waits for the carrier.
- Un-hide is guarded the other way round (`pending_deletes.dart:276+`, carriers held until the plain copy lands). Hide has no such guard.
- The carrier uploads through `hiddenBackup?.run()`, "otherwise when it is next opened".
- Scenario: hide 50 photos, the drain runs, the carrier upload fails or waits. Until it lands, the only copy is a plaintext file in the app container (03 #2), which goes if the phone or app is lost.
- Fix: hold hide-retractions keyed by localId and release them only when that target holds the carrier, mirroring the un-hide guard.

**6. "Move to Library" iterates the live selection Set while the user can still toggle it.** CONFIRMED (code path)
- `private_album_screen.dart:667-670` passes `_selectedIds` itself to `_removeManyFromAlbum`, which awaits inside a `for` over it (`:586-604`).
- `_toggleSelected` (`:663-665`, reached from a tile tap in select mode, `:916-918`) mutates that same Set in place.
- The button has no busy guard (`:1697-1705`).
- Scenarios:
  - A tap during the loop throws `ConcurrentModificationError`. Some photos are un-hidden, and `_reload`/`_exitSelectMode` never run.
  - A double tap runs `putBack` twice per photo (PLAUSIBLE: duplicate in Photos).
- Fix: `final ids = _selectedIds.toList()`, add a `_busy` flag that disables the bar, and make `_toggleSelected` copy-on-write like `_onSweep` already does.

**7. "Optimize in bucket" and "Re-format" overwrite bucket originals without confirmation.** CONFIRMED
- `solutionIsPermanent` (`flagged_copy.dart:71-75`) leaves out `optimizeRemote` and `reformat`. Every row starts ticked (`flagged_action_screen.dart:35, 84-91`).
- `bucket_flagged.dart:829-905` deletes the old key in every bucket.
- Cloud-only photos are in the same list, under copy that says "This iPhone keeps its full-quality original".
- Scenario: one tap on "Optimize · 300" replaces 300 originals with 2560px HEIF, including ones whose only copy anywhere was that bucket file.
- Fix: treat both actions as permanent and state the "no other copy" count in the confirmation. Give cloud-only rows their own action with accurate text, unticked by default.

**8. A queued fix acts on the record as it was when the page loaded.** CONFIRMED (locked), PLAUSIBLE (hidden)
- `flagged_action_screen.dart:37-40` hands the stored `job.flag.storage!.record` to the queue. `fix_queue.dart:739-746` uses it as is; the resume path (`:489-499`) re-reads it but checks neither lock nor `passcodeHash`. `storage_optimizer.dart:142-170` `_rewrite` has no guard either.
- Scenarios:
  - Open a row, Lock it, go back, Run. The locked file is re-encoded and replaced.
  - "Remove Duplicates" on a photo hidden since the scan bins a hidden row, which no bin path ever lists or purges.
- Fix: re-read in one batch (`getByLocalIds`) at enqueue and before each job. Drop the job if `!worthMeasuring(fresh)` or the record is locked or binned. `_rewrite` and `_replaceInLibrary` refuse such rows.

**9. Flagged Items never refreshes while open.** CONFIRMED
- The only listener is the fix queue (`flagged_items_screen.dart:81`). The "waiting for backups" hold reads upload state from the snapshot taken at load (`:225-229, 265-280`).
- Scenario: open the page while 40 uploads run. "Waiting for 40 backups" and the hidden Optimize rows stay after the uploads finish.
- Follow-on items (leftover copies, finish-optimize) only appear after a manual Rescan.
- Fix: re-run one scan, debounced, on queue finish and on library or upload change (step 04's `FlagScan`).

**10. Safety page shows the same "N of M backed up" under every bucket.** CONFIRMED
- `safety_screen.dart:357-368` uses one global `isFullyBackedUp` count for every row.
- Scenario: add a new, empty second bucket. Its row says "4387 of 4387 backed up", on the page meant to prove the copies exist.
- Fix: count per bucket from `allHoldings()`, in one query.

**11. Face group page lists and links hidden, binned and purged faces, and "Find more" seeds from everyone.** CONFIRMED, same as 05 #2/#3
- `face_group_screen.dart:103-124` and `:213-222`. See 05; not re-detailed here.

**12. A derived copy of a hidden photo is briefly an ordinary library record.** PLAUSIBLE
- `derived_asset.dart:56-77`, reached from `resizePhotos` in the private album (`private_album_screen.dart:777-852`) and from edit. `enqueueFile` upserts a plain `manual:<hash>` pending row first. `setHidden`/`setPasscodeHash` come several awaits later, after the `.mov` copy for Live Photos.
- Scenario: a library reload or upload refill in that window shows the photo in the main grid, or uploads it in the clear under its own name.
- Fix: pass `passcodeHash`/`isHidden` into `upsert` so the row is created hidden in one write.

## P2

13. **The action page can get stuck on finished items, and Run queues them again.** CONFIRMED. `flagged_action_screen.dart:56-66`: when the last item finishes with a photo open on top, `_closing` is set but nothing pops or redraws. `enqueue` doesn't skip resolved flags, so finished "Optimize in bucket" rows can be re-encoded. Fix: pop or `setState` when the page is back on top; make `enqueue` skip `isResolved`.
14. **Opening Flagged Items reads the library about 4× and the bucket index about 4× on the UI isolate.** CONFIRMED. `flagged_items_screen.dart:82-85, 169`, `storage_advice.dart:372, 413-418, 474`, `record_fixer.dart:82-92`. `_loadBucket` lists the whole index only to test whether it is empty. Fix: one scan in an isolate; `LIMIT 1` for the emptiness test.
15. **Rescan races the earlier loads.** CONFIRMED (path). The spinner tracks only 2 of the 5 loads (`flagged_items_screen.dart:214-219, 349`). Stale results can land last, and two record scans mutate rows at the same time (`record_fixer.dart:91, 140-145`). Fix: a generation token per load, and Rescan disabled until all five settle.
16. **The scan silently removes `bucket:` import rows.** CONFIRMED (path), PLAUSIBLE (impact). `record_fixer.dart:140-145` calls `store.remove` when another record, possibly a binned one, has the same file name. Tags, captions, albums and people go with it, and nothing asks. Fix: show it as a flag, or move the metadata to the twin first; only match live rows.
17. **Opening Recently Deleted purges entries.** CONFIRMED (path). `recently_deleted_screen.dart:56-78` → `asset_removal.dart:351-385` makes one Photos lookup per binned record, one after another, and runs again after every tap. With limited Photos access (04 #2), rows outside the selection count as gone and are purged with no prompt. Fix: purge only in the sync expiry run with full access, and batch the lookups.
18. **"Empty Recently Deleted" purges the bin as it is now, not the list on screen.** CONFIRMED (path). `recently_deleted_screen.dart:119-142` → `asset_removal.dart:251`. Background sync can bin rows while the page is open, and the dialog shows no count. Fix: purge the shown ids only, with the count in the title.
19. **Person-set switch keeps the old `_detail` until reload finishes.** PLAUSIBLE. `person_profile_screen.dart:296-302, 334-338`. A keystroke in that window saves one set's bio or traits into the other. Fix: clear state and disable editing during the load.
20. **N+1 queries on the face group page.** CONFIRMED (05 #16). `face_group_screen.dart:111-115, 213-222`.
21. **`PersonAvatar` queries `getByLocalId` on every rebuild.** CONFIRMED. `person_avatar.dart:58-59` creates the future in `build`, so every People-list `setState` re-queries each visible avatar. Fix: cache the future per `localId`, or pass records in from a batched read.
22. **Sync file I/O per record on the UI isolate.** CONFIRMED. `private_album_screen.dart:557-562` does `existsSync` + `lengthSync` per hidden record inside `setState`, on every reload (each delete or un-hide, return from the viewer). The comment says "best-effort" but gives no bound; CLAUDE.md says "one per record is a stall". Fix: async `stat` via `Future.wait`, or store the file size on the record.
23. **The crop/rotate screen decodes the full image twice and leaks the frame.** CONFIRMED. `photo_edit_screen.dart:55-66` uses `instantiateImageCodec` just to read the dimensions, and never disposes `frame.image` or the codec. `Image.memory(bytes)` (`:154, 253`) then decodes full size again with no `cacheWidth`, which is about 190 MB RGBA for a 48 MP photo. No try/catch, so a decode failure leaves the spinner up forever. Fix: `ImageDescriptor.encoded` for the size and dispose it; `ResizeImage` for the preview; catch and show `_error`.
24. **Resize in the private album defaults to permanent Replace.** CONFIRMED. `resize_photos.dart:153-157` makes "Replace" `isDefaultAction`. In the private album it goes to `HiddenRemoval.delete` (`private_album_screen.dart:798-805, 837-843`), which is permanent: no bin, and for bucket-side entries the original is deleted while the new copy exists only on the phone, not yet backed up. Fix: in the hidden case, defer the original's delete until the copy's carrier is confirmed in the bucket (same hold as #5), and don't make Replace the default there.

## P3

25. `_loadDuplicates` has no try/catch (`flagged_items_screen.dart:114-121`). One failure empties duplicates and cloud-only, so exact copies are offered Optimize instead of Remove.
26. Delete on a locked photo silently does nothing (`delete_confirmation.dart:251` returns `none`). Say that it's locked.
27. `AssetRemoval.deleteEverywhere` has no hidden guard (`asset_removal.dart:196-210`). Combined with #1, a hidden photo deleted from Favorites or a person page is binned where no purge or expiry ever reaches it.
28. Repeated per-build work: `flagged_action_screen.dart:328-333` computes the time estimate twice per row, and `flagged_items_screen.dart:494-499` recounts failures per group. Compute once when the data changes.
29. `person_page_screen.dart:62-67` and `person_avatar_picker.dart:43-47` load `listAll()` and filter the whole library for one person's photos, and repeat it after every favourite or delete. Use `getByLocalIds`.
30. `people_screen._addPerson` (`:516-534`): leaving the name blank deletes the person along with any relationships, places or sealed details already entered. Only drop the person if nothing else was written.
31. `_removeLocation` (`person_profile_screen.dart:568-571`) deletes with no confirmation; relationships, events and history all ask.
32. `people_screen._reload` reruns `findUnnamedFaces` over `listAll()` on every return from a person page (`:146-160`; see 05 #17).
33. `person_page_screen._findMore` (`:145-160`) builds a new `AiAnalysisStore` and `FaceIdentityService` each time, because `_openPerson` never passes them in.
34. In Favorites, the viewer's heart is wired to `_unfavorite` (`favorites_screen.dart:93`), so a heart tapped by mistake can't be undone from the viewer.
35. Album tag chips delete the tag on any tap, with no confirmation and no undo (`album_screen.dart:292`).

## Improvement suggestions

- One visibility predicate plus `listVisible()`/`getVisibleByLocalIds()` on `AssetRecordStore`, used by every screen, avatar and count (closes #1, #27, #29).
- A required `PersonScope(namespace, keys)` on every person-profile write (closes #3, #19).
- One "loses data" predicate replacing `solutionIsPermanent`, covering bucket deletes, Optimize in bucket, Re-format and Remove from Library. Its confirmation states how many rows have no other copy.
- Re-check each queued job against the live record (hidden, locked, binned, still the offered fix) in one batched read.
- One Flagged Items scan over one snapshot, run in an isolate and re-derived on queue finish and library/upload change (closes #9, #13–15 and the flicker).
- Recently Deleted opens read-only; purge and expiry live in sync only.
- A "carrier confirmed" gate shared by hide-retract and hidden resize-replace (#5, #24).

## Checked and fine

- `album_screen`, `asset_picker_screen` and the home-derived lists (Places, Videos, Recently Added) filter deleted, hidden and passcode rows.
- Private album delete and delete-album are confirmed with destructive styling. Delete-album un-hides through `putBack` and destroys nothing.
- `_freeUpSelected` checks each entry against the bucket before dropping the local copy. Recover leaves the album only once Photos has the photo. Cloud actions have a busy guard.
- `hideIntoPrivateAlbum` warns when there is no bucket, fetches cloud-only originals first, and un-hides on custody failure.
- `cached()` re-reads records on open, and `adviseOn`/`worthMeasuring`/`cloudOnly`/`duplicates` exclude hidden, locked and binned rows. `removeFromLibrary` verifies the bucket live.
- Removals from the phone go through the iOS delete prompt. `chooseDelete` offers "remove from device" only after a bucket HEAD.
- Bin paths `isInBin`/`emptyBin`/`expireBin`/`deletePermanently` exclude hidden and locked rows, and bucket deletes go through `PendingDeletes`.
- Safety page's own counts and restore drill exclude hidden rows. Check Now never deletes.
- Analyze queue page: list capped at 60, Rescan asks first, `_openById` refuses hidden rows.
- Profile export is per-namespace. Autofill writes to the caller's namespace, and nothing is accepted by default.
- The delete-person dialog is confirmed; navigation afterwards has no race.
- `_FaceCrop` decodes via `ResizeImage` and detaches its listeners. People reload uses batched `allMemberships`.
- Edit crop/rotate run in `Isolate.run`. Resize encodes natively, and a failed copy keeps its original.
- No `material.dart` and no `img.decodeImage` in scope.
- Out of scope, noted for step 09: Re-format downloads with Dart `http.get` (`bucket_flagged.dart:739`), which breaks the background-transfer rule.
