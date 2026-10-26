# App-data backup

Everything this app knows that isn't a photo — albums, people, tags,
captions, places, chats, writings and their pictures, faces — copied out and
put back. Never credentials: those are in the keychain, which outlives the
app on its own.

```text
                    app_snapshot.dart ── reads/writes the three stores
                            │
                    snapshot_index.dart ── the same library as CSV, for a person
                            │
                    snapshot_archive.dart ── one zip, every destination
                            │
        ┌───────────────────┼───────────────────┬──────────────────┐
        ▼                   ▼                   ▼                  ▼
  local_vault.dart    icloud_backup.dart   bucket_backup.dart  snapshot_file.dart
  app container       iCloud Drive         user's bucket       share sheet /
  7 days by age       latest 10            30 days daily,      Files picker
  no switch           switch               then 1 per month    two pills
                                           switch
```

**Two halves.** `library.json` (rows of the three main stores) rides in each
day's zip. Everything else — `conversations.db`, `words.db`, `ai_analysis.db`,
`words/media/` and `chats/voice/` — is too big for that: each goes up as a **blob**,
`blobs/<sha256>`, once, and the zip's `data-files.json` lists which blobs
make up that day (`data_files.dart`). A zip is written only after every blob
it names is confirmed there; a day whose blobs can't be gathered writes no
zip at all. Restore merges blobs into the live stores (`mergeDatabase`),
never replaces them. `sync_jobs.db` is left out on purpose: it's the upload
queue, rebuilt from the records.

| File | Does |
|---|---|
| `app_snapshot.dart` | the payload: export from / import into the three stores |
| `snapshot_index.dart` | `index.csv` — one row per photo, readable with no app at all |
| `snapshot_archive.dart` | zip it (with the index inside), name it (`YYYYMMDD.zip` daily, `<datetime>-<purpose>-photos-vault.zip` otherwise), read old names back, plan the bucket's thinning |
| `data_files.dart` | the blobs: copy, gzip, hash, list; fetch, verify and merge back |
| `change_log.dart` | SQLite triggers recording every row write; the "has anything changed" mark |
| `backup_schedule.dart` | the one gate: daily, only if changed, recorded after success |
| `local_vault.dart` | tier 1 — Files-visible zips (rows only), raw `.db` copies incl. chats and writings (daily and pre-deletion), before-operation copies; writings' pictures stay where they are |
| `icloud_backup.dart` | tier 2 — iCloud Drive, over `icloud_drive.dart`; blobs in `blobs/`, ones no kept zip names are dropped |
| `bucket_backup.dart` | tier 3 — `app-data/` in every configured bucket; blobs in `app-data/blobs/`, never deleted; dailies thinned |
| `snapshot_file.dart` | the manual door: export to a file, import one back |
| `icloud_drive.dart` | thin platform channel over the app's iCloud folder |

Tiers, cadence and retention and why they differ: `docs/design/UIUX-DESIGN.md`.

`index.csv` rides in every zip *and* sits loose in `app-data/` in each bucket
and in the iCloud folder, overwritten each time. Never read back by this app —
`library.json` beside it is what restores. It exists for the case where there
is no app: a bucket keyed by iOS asset identifiers is unsearchable, and
recovery starts with somebody in a web console who should not have to guess
which of thirty zips to download first. Hidden photos are excluded on purpose
(see `snapshot_index.dart`).

Both off-device destinations are **on unless turned off**. They were off by
default, which made the copy that makes a bucket legible the one thing the
user had to go and ask for — and a reinstall then found nothing to restore.
