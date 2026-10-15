# 08 Settings, app shell, l10n — findings

Scope: `lib/settings/`, `lib/demo/`, `lib/app.dart`, `lib/main.dart`, `lib/l10n/*.arb`. I also read the callers and consumers that decide behaviour: `upload/background_sync.dart`, `upload/pending_deletes.dart`, `upload/backup_coordinator.dart`, `viewer/ask_ai_screen.dart`, `viewer/private_album_screen.dart`, `viewer/library_screen.dart` (privacy and demo rows), `photos/ai_chat.dart`, `scripts/release-ios.sh`, `Makefile`, and flutter_secure_storage 11.1.1 / darwin 0.4.2 and http 1.6.0 from the pub cache. I printed no secret values.

## P0

**1. If the database read fails, "Remove All App Data" deletes every imported or edited photo, including ones that exist nowhere else.** CONFIRMED (logic), PLAUSIBLE (trigger)
- `app_data_removal.dart:183-198`: `_onlyCopies` returns `const {}` when `listAll()` throws. The comment there says "Keeping everything is the safe way to be wrong". In fact an empty set means *keep nothing*.
- `run()` then calls `deleteOwnedFiles(keeping: {})` (`:122`). `_deleteOwnedOriginals` (`:276-290`) deletes every `<sha256>.<ext>` file in the support directory. That includes imports and edits that were never backed up, and the plaintext files of hidden photos that are only on this phone. The row snapshot taken before the wipe holds no pixels (`:171-176`).
- Scenario: the DB is locked or corrupt, a migration throws, or the disk is full → the user confirms the wipe → those photos are gone for good.
- Fix: return `null` on failure and skip `_deleteOwnedOriginals` entirely when the answer is unknown. Add a test where `listAll` throws.

## P1

**2. Keychain items are readable only while the phone is unlocked, so the background backup pass skips whenever the phone is locked.** CONFIRMED (code), PLAUSIBLE (how often iOS runs the task while locked)
- `secure_store.dart:16` and `demo_mode.dart:103` use `FlutterSecureStorage()` with no `IOSOptions`. Its default is `KeychainAccessibility.unlocked`, which is `kSecAttrAccessibleWhenUnlocked` (`apple_options.dart:72`, darwin `parseAccessibleAttr`). While the phone is locked, a read returns `errSecInteractionNotAllowed`, which reaches Dart as a `PlatformException`.
- `background_sync.dart:163` → `hasBackupTarget()` (`sync_engine.dart:115-121`) catches that error and returns `false`. `backgroundSkipReason` then ends the run. The BG processing task asks for external power (`BackgroundSync.swift:28`), which typically means overnight on the charger, with the phone locked. In that case nothing uploads, and nothing is logged or shown.
- Fix: `IOSOptions(accessibility: KeychainAccessibility.first_unlock)`. Keep it not-`ThisDeviceOnly`, so an encrypted device restore still brings the keys back (see 03 #4). Migrate existing items once in the foreground: read them, then delete, then write them again.

**3. When the bucket comes back, dormant pending deletes never run, including deletes of plaintext copies of hidden photos.** CONFIRMED
- `pending_deletes.dart:23-26` and `app_data_removal.dart:139-141` both promise: "re-add that bucket and they run". A task is keyed by `targetId`. But `BackupTargetsStore.add` always assigns a new `_uuid.v4()` (`backup_targets_store.dart:149-158`), and nothing maps an old id to the same provider/bucket/prefix. `drain` runs only the ids in `byId` (`pending_deletes.dart:207-220`).
- Scenario: the user removes the bucket (or runs "Remove All App Data"), then adds the same bucket again. The owed deletes stay dormant for good, so a hidden photo's plaintext copy stays in the bucket while the app shows a clean state. The same id mismatch leaves `derivative_target` rows under the old id.
- Fix: on `add`, reuse the id of a forgotten target with the same `(provider, bucket, prefix)`. Or re-key dormant tasks and `derivative_target` rows to the new id.

**4. In-app privacy and safety text says things the code doesn't do.** CONFIRMED
- `privacyBody` (`app_en.arb:249`, shown at `library_screen.dart:3206`) says "This app has no permission to delete from your bucket; only you do." The app deletes from the bucket via `PendingDeletes`, `BucketFixer`, the bucket browser and migrations (02 #18), and the setup guide asks for `s3:DeleteObject` (`docs/release/listing.md:115`). The same text says "Keys … are never included in a backup". With the default accessibility, Keychain items do go into encrypted device backups (see 03).
- `privateAlbumBackupExplainer` (`:974`) says "Nothing about a hidden photo is kept in the app's database, and nothing about it rides into your iCloud device backup." That contradicts 03 #1 (rows and passcode hashes in the DB and every app-data copy) and 03 #2 (plaintext files in a directory iOS backs up).
- `privateAlbumHowBullets` (`:1363`, shown at `private_album_screen.dart:1397`) is the Sep 21 model (49a3711) and was never updated after 1c77c44 (Sep 26) moved hidden photos onto the phone. It says:
  - "Nothing about a hidden photo is kept on this phone: no file, no thumbnail, no record. That's why this album needs an internet connection." The explainer on the same screen says the opposite.
  - "Nothing is ever deleted from your bucket unless you delete it yourself." Hiding deletes the plain copy (07 #5), and migration deletes old names (03 #5).
  - "Neither [passphrase nor code] is stored anywhere." A reversible code hash sits in the DB (03 #1), and the key ring saves an album key for every code typed (03 #17).
- `settingsAiTodoNote` (`:762`) says the keys are used for the "AI-recognized People collection". The only consumer of the keys is `AiAskService`, used by Ask AI and by profile autofill, which sends whole CV files. `settingsAiUsageWarning` ("sends photo data") is accurate. The conflict is with the store listing (05 #1), not with this screen.
- Fix: rewrite these four strings in both arb files to match the code, or fix the code (03 #1, #2) and keep the text. Add the copy to whatever checklist 05 #1's listing fix uses.

**5. A release build with `.env.demo` present ships the demo S3 secret and AI key, and any user can switch demo mode on.** PLAUSIBLE (`.env.demo` is absent now; the release path includes it by design)
- `scripts/release-ios.sh:24` and `Makefile:24` pass `--dart-define-from-file=.env.demo` to `build ipa --release`. `demo_seed.dart` puts `DEMO_S3_*` and `DEMO_AI_API_KEY` into `String.fromEnvironment` constants. Obfuscation doesn't hide string constants, so anyone with the IPA can extract them.
- Demo mode is a public button at the bottom of home (`library_screen.dart:2898-2908`). Uploads aren't gated on `DemoFlag` (the only gates are iCloud, photo library and background sync). So every user in demo mode shares one bucket. Their own imported files go up there, other users can browse them and delete any key, and the AI key is billed to the developer.
- Fix: don't pass demo defines to `release`/`archive`. If App Review needs a bucket, gate the seeding on a review-only path and use a key scoped to a read-only prefix.

## P2

**6. Bucket preview decodes full-size originals with no size cap.** CONFIRMED (code)
- `bucket_object_preview_screen.dart:113-121`: `Image.network(url)` with no `cacheWidth`/`cacheHeight`. A 48 MP original decodes to about 190 MB of RGBA, which then stays in `ImageCache`. Opening two or three originals can get the app killed for memory.
- Fix: pass `cacheWidth: (screenWidth * dpr * 2).round()` and evict on dispose, or show the thumbnail key and offer "Open externally" for the full original.

**7. In demo mode, startup can block the first frame on seeding.** PLAUSIBLE
- `main.dart:19` awaits `DemoMode.init()` before `runApp`. With the marker set, `DemoSeed().ensure()` (`demo_seed.dart:36-64`) opens the record DB (paying the rehome cost, 01 #6). If the `_doneKey` write never happened (a kill mid-seed), it also draws and encodes all 27 photos (960×720, 4 at a time) before anything paints.
- Fix: call `runApp` first, and seed behind `DemoMode.shown` with a loading state.

## P3

8. **90 unused l10n keys** in both arb files, for example `askAiNoKey`, `backupQueue*`, `cloudStatus*`, `settingsSync*`, `settingsCloud*`, `demoModeExitBody`, `vaultNoBucket`, `storageResultLocked`. The full list comes from comparing arb keys with `.identifier` uses under `lib/` (generated files excluded). Delete them, or wire up `askAiNoKey` (next item).
9. **Raw exception text shown to users, in English:** `ask_ai_screen.dart:90`, `ai_settings_screen.dart:318`, `bucket_object_preview_screen.dart:79`, `profile_autofill_screen.dart:122`, `profile_transfer_screen.dart:90,122,158`.
   - With no usable key, a zh user sees `No AI key configured.` (`ai_settings_store.dart:50`), while the localized `askAiNoKey` sits unused.
   - Offline, a Gemini call fails with `ClientException: …, uri=https://…?key=<API key>` (http 1.6.0 `exception.dart:17`, `ai_chat.dart:290-293`). That puts the API key on screen and in screenshots. This extends 05's P3 about the key in the URL.
   - Fix: map known errors to l10n strings and never interpolate the URI.
10. **AI Settings hides the keys of vendors that aren't allowed in this storefront, but edits the full list.** `_load` shows `usableKeys()` (`ai_settings_screen.dart:50`), while `moveKey` swaps neighbours by index in `listKeys()` (`ai_settings_store.dart:146-156`).
    - In the CN storefront, ↑/↓ can swap with an invisible key, so nothing visibly moves.
    - A stored OpenAI or Anthropic key can't be seen or removed there.
    - Fix: list every key, and mark the unusable ones as such.
11. **`AddBackupScreen._save` doesn't guard `store.add` or `removeMatching`** (`add_backup_screen.dart:417-425`). A keychain write error throws unhandled and leaves `_saving = true`, so the spinner sticks and the form stays disabled.
12. **The same bucket+prefix can be added twice.** There's no duplicate check in `add`. Every upload then goes twice to the same key. If one copy's upload failed, the other target's superseded-delete removes the object the first target's row still points at. Fix: reject a duplicate `(provider, bucket, prefix)`.
13. **Abandoned drafts keep the secret key in the Keychain indefinitely** (`s3_target_drafts_store.dart:47-79`). Drafts are saved before validation, typos included, and never age out. Fix: cap the list at around 3 and drop drafts older than 30 days.
14. **A bucket name containing dots** can't be reached over virtual-hosted HTTPS: the wildcard certificate doesn't cover it. The user gets "region detection error" (`add_backup_screen.dart:388-390`) instead of a clear message. Fix: validate the name before Save.
15. **Removing a bucket clears only the Keychain entry** (`settings_screen.dart:277-280`). Its `bucket_object`, `bucket_scan*` and `derivative_target` rows stay behind (see 01 #11).
16. **`main.dart` keeps test-only code in release builds.**
    - `screenshotRequest()` does a sync `existsSync`/`readAsStringSync` on `/tmp/pv-screenshot` before `runApp` (`:86-91`). It's harmless on a sandboxed phone, but gate it on `kDebugMode`.
    - `_reportJank` is marked TEMPORARY (`:66`).
17. **`AiSettingsStore.listKeys` writes `[]` to the Keychain on every read** when there's no key and no legacy slot (`:97-100`). It also doesn't catch a malformed JSON value, which throws through every AI screen.

## Improvement suggestions

- **One `SecureStore` options object:** set accessibility once, with an explicit decision on `first_unlock` vs `ThisDeviceOnly` per key class: bucket credentials, AI keys, vault master keys (see #2 and 03).
- **Stable target identity:** derive the target id from `(provider, bucket, prefix)` or remap on add. That fixes #3 and #12, and lets re-adding a bucket pick up its listing and `derivative_target` rows.
- **Treat in-app copy as part of the spec:** keep a short claims list (privacy page, hidden-album bullets, AI notes, store listing) next to the code it describes, and review it in the same PR (see #4 and 05 #1).
- **Ship no secrets in builds:** `release`/`archive` should fail if any `DEMO_*` define is set.

## Checked and fine

- S3 credentials, drafts, AI keys and vault keys go only through `SecureStore`, which is the Keychain. None of them are in `app_state`, sqlite, app-data snapshots, zips or bucket archives. No `print`/`debugPrint` in `lib/`, apart from the profile-only jank log.
- Demo mode uses `demo.`-scoped Keychain keys, a demo DB path and demo directories. Reset deletes only `demo.` keys.
- "Remove All App Data" clears every target, draft and AI key slot, including the legacy OpenAI slot. Credentials go last, after the copies.
- en and zh arb: 902 keys each, the same sets. The only identical values are brand and field names (`appTitle`, SecretId/SecretKey, the paste example).
- No hard-coded user-visible `Text('…')` literals besides the CupertinoApp title and numeric labels.
- No `material.dart`. The localization delegates exclude Material. Settings, demo and shell code do no image decode on the UI isolate; the demo draws on `Isolate.run`.
- Before the first frame: creating `tmp`, three method-channel calls (`AppStoreRegion.load`), and `DemoMode.init`, which is cheap when demo mode is off. LibraryScreen work is covered by 06.
- The access check uses a signed `ListObjectsV2` GET and surfaces the provider's error code. Region detection is an unsigned HEAD. Key prefixes are normalised. Secret fields are obscured, with no autocorrect or suggestions, and the paste buffer is cleared after parsing.
- The language picker and the CN-storefront locale resolution follow the documented order: app pick, then iOS per-app language, then storefront.
