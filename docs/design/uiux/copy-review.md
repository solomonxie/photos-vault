# Copy review — all 511 strings, nothing applied yet

Read `lib/l10n/app_en.arb` end to end. Grouped by what is actually wrong,
worst first. **Nothing here is applied** — mark up the "proposed" column and
the changes go in (plus `app_zh.arb`, which has the same problems).

---

## 1. Strings that are about to become lies

These describe the cloud-only private album. The offline-native change
([hidden-backup/STORAGE.md](../hidden-backup/STORAGE.md)) makes every one of
them false. They have to move with that change, not before it.

| key | current | after |
|---|---|---|
| `vaultNoBucket` | "With no bucket set up, hidden photos stay on this phone, **unencrypted**." | encrypted either way; the bucket is a *copy*, not the safe |
| `privateAlbumBackupNoBucket` | "Until you add one, hidden photos stay on this phone and are **not encrypted**." | same, and it duplicates the row above — one of the two should go |
| `privateAlbumBackupStatusOff` | "No bucket yet, so these stay on this phone." | should read as a normal state, not a shortfall |
| `vaultNeedsNetwork` | "Hidden photos live in your bucket. Without a connection this album is empty." | no longer true — local is the default |
| `privateAlbumBackupExplainer` | "Nothing about it stays here — no file, no thumbnail, no record — so this album needs a connection" | becomes "nothing *readable* stays here" |
| `privateAlbumHowBullets` | bullets 6–8 ("this app becomes the only holder", "needs a connection", decoy bullets) | decoy bullets become bucket-only; the connection bullet goes |

---

## 2. Bugs, not taste

| key | current | problem | proposed |
|---|---|---|---|
| `libraryAddFilesResult` | `Added {picked} file(s), backed up {succeeded}.` | `file(s)` — the one place in 511 strings that dodges plurals instead of using ICU. Untranslatable; Chinese gets a literal "(s)". | `{picked, plural, one{Added 1 file} other{Added {picked} files}}, backed up {succeeded}.` |
| `settingsDraftsTitle` | `DRAFTS` | Caps baked into the string. The style already uppercases section headings (UIUX-DESIGN.md: 12px/600/UPPERCASE) — so English is shouted twice and Chinese, which has no case, silently loses the styling cue. | `Drafts`, uppercase in the `TextStyle` |
| `vaultPassphrasesHeading` | `PASSPHRASES` | same | `Passphrases` |
| `privateAlbumHowTitle` | `HOW THIS WORKS` | same | `How this works` |
| `backupQueueListHeading` | `IN THE QUEUE` | same, **and** byte-identical to the next row | `In the queue` |
| `analyzeQueueListHeading` | `IN THE QUEUE` | two keys, one string — one of them should be deleted | delete, use the other |
| `albumUseDefaultCover` | `Use Colour Cover` | British spelling in a US-English file that says Favorite, Analyze, Optimize, Color everywhere else | `Use Color Cover` |
| `storageFixSelected` / `storageOptimizeAction` | both `Optimize` | duplicate key | delete one |
| `settingsAppDataHint` | "…**Not sync between devices**, and never your bucket keys." | ungrammatical | "This isn't sync between devices, and never carries your bucket keys." |
| `personProfileBioEmpty` | "This person doesn't have **any bio**" | missing article, no full stop | "Nothing written here yet." |

---

## 3. One object, four names

A configured bucket is called four different things depending on the screen.
Pick one — **Cloud Bucket** is the one the headings already use.

| key | current | |
|---|---|---|
| `settingsAddButton` | Add **Cloud Bucket** | ✅ keep |
| `settingsDeleteConfirmTitle` | Remove this **backup target**? | internal vocabulary, leaks the class name |
| `settingsDeleteConnectionAction` | Delete **Connection** | third name |
| `settingsDeleteConfirmBody` | "just this app's saved **configuration** for it" | fourth, and "configuration" is dev-speak |

Proposed: *Remove this bucket?* / *Remove Bucket* / "This doesn't delete
anything already in the bucket — only what this app remembers about it."

Same problem, smaller: `collectionsSyncQueueRow` "Sync **Q**ueue" vs
`settingsSyncQueueRow` "Sync **q**ueue", and three rows named Sync Queue /
Backup Queue / Analyze Queue where the first two look like the same screen.

---

## 4. Written by an engineer, read by a person

| key | current | proposed |
|---|---|---|
| `settingsAiTodoNote` | "These keys **power** AI-recognized People and Events smart collections. Places (GPS-based) **doesn't** need them." | "Used for the People and Events collections. Places works from a photo's own location and needs no key." (also: the key is named `…TodoNote`) |
| `settingsAiKeyStrategySequential` / `…RoundRobin` | Sequential / Round Robin | "One key until it fails" / "Take turns" |
| `analyzeQueueFaceModelOff` | "Face model: off — **falling back to** general image matching, which is much weaker." | "Face matching is off. Photos are compared as whole pictures instead, which gets it wrong more often." |
| `bucketPreviewOpenExternally` | Open **Externally** | "Open in…" (what iOS calls it) |
| `storageIssueOptimizableFormat` | Optimizable format | "Could be smaller" |
| `libraryHideStillInPhotos` | "…— the **removal was declined**." | "…— you didn't allow it to be removed." |
| `settingsRemoveAllAppDataBody` | "**You will first be prompted to** export your app data to a local folder before everything is deleted." | "You'll be offered a copy to save first. Then everything goes." |
| `vaultHeldUpload` | "{count} waiting for this album to be open" | "{count} can't upload until you open this album" |
| `settingsLengthHint` | "…Check for **a bad paste**." | "…Check the paste." |
| `settingsBackupFormatFolderNote` | 3 sentences explaining internal folder naming and a *future* tier | cut. It answers a question no user asked and promises a roadmap |
| `analyzeReviewAccept` / `analyzeReviewDismiss` | Keep / **No thanks** | mismatched pair — "Keep" / "Discard" |
| `faceGroupNotScanned` | "…**Run Analyze Now.**" | points at a button on another screen; either link it or say "It'll be looked at on the next pass." |
| `smartCollectionsCardLabel` | Tap to Analyze | a label that is an instruction — "Not analyzed yet" |
| `peopleAiAnalysisRow` | Find People with AI Analysis | "Find people with AI" |
| `privateAlbumBackupRecentlyDeleted` | "…until you empty **its** Recently Deleted." | ambiguous *its* — "…until you empty Recently Deleted **in Photos**." |

---

## 5. Raw API names in the form

`settingsSecretIdLabel` "SecretId", `settingsSecretKeyLabel` "SecretKey",
`settingsAccessKeySecretLabel` "AccessKey secret", `settingsPrefixLabel`
"Key prefix".

These are ugly **and correct** — they're what Tencent's and Alibaba's
consoles print, and a user copying from a console is matching labels. Leave
them. Worth one hint line saying so: "Named as your provider's console names
it."

---

## 6. Not copy — product questions

- **`genderMale` / `genderFemale` are the only two options.** A profile
  field with exactly two values and no way to leave it blank or say
  anything else. `personProfileNotSet` exists for other fields. This will
  be wrong for real people in the user's own library.
- **`personProfileWrongPasscode` "Incorrect passcode."** — the private
  album is built on there being no such thing as a wrong passcode, and
  says so in the README. Two screens apart, the same app ships both ideas.
  See [relationships-vs-rim.md](../relationships-vs-rim.md#1-the-lock-on-a-person-contradicts-the-lock-on-an-album).
- **Title Case vs sentence case** is decided per-string rather than per-role.
  `detailInfoNoLocation` "No Location" and `detailInfoNoEvent` "No Event"
  are Title Case *values*, next to `personProfileNotSet` "Not set". Apple's
  rule: Title Case for buttons and menu items, sentence case for everything
  else. About 20 strings would move.
