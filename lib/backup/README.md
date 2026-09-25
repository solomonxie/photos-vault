# App-data backup

Everything this app knows that isn't a photo — albums, people, tags,
captions, places — copied out and put back. Never credentials: those are in
the keychain, which outlives the app on its own.

```text
                    app_snapshot.dart ── reads/writes the three stores
                            │
                    snapshot_archive.dart ── one zip, every destination
                            │
        ┌───────────────────┼───────────────────┬──────────────────┐
        ▼                   ▼                   ▼                  ▼
  local_vault.dart    icloud_backup.dart   bucket_backup.dart  snapshot_file.dart
  app container       iCloud Drive         user's bucket       share sheet /
  7 days by age       latest 10            never deleted       Files picker
  no switch           switch               switch              two pills
```

| File | Does |
|---|---|
| `app_snapshot.dart` | the payload: export from / import into the three stores |
| `snapshot_archive.dart` | zip it, name it (`YYYYMMDD.zip` daily, `<datetime>-<purpose>-photos-vault.zip` otherwise), read old names back |
| `change_log.dart` | SQLite triggers recording every row write; the "has anything changed" mark |
| `backup_schedule.dart` | the one gate: daily, only if changed, recorded after success |
| `local_vault.dart` | tier 1 — Files-visible zips, raw `.db` copies, before-operation copies |
| `icloud_backup.dart` | tier 2 — iCloud Drive, over `icloud_drive.dart` |
| `bucket_backup.dart` | tier 3 — `app-data/` in every configured bucket |
| `snapshot_file.dart` | the manual door: export to a file, import one back |
| `icloud_drive.dart` | thin platform channel over the app's iCloud folder |

Tiers, cadence and retention and why they differ: `docs/design/UIUX-DESIGN.md`.
