# People zip import

Bring a whole people archive (profiles + each person's photos) in at once,
optionally straight into each person's hidden folder.

## Problem

- Two retired projects hold the data: `life-logs` (601 contacts from
  Contacts/QQ/SMS, relationships) and `relation-tree` (210 people, ~20k
  photos, 2.6 GB).
- CSV import covers profiles only; photos would be one share at a time,
  untagged, and visible in the grid.

## Decisions (confirmed 2026-10-22)

| Question | Decision |
|---|---|
| Who is in the CSV | People with real contact: messaged, notes, birthday, or photos; unnamed SMS threads (a phone number as the name) left out — 471 |
| Contact details | All, as profile fields: phones, emails, QQ, aliases, addresses, first/last contact, relation to me; QQ/school groups as Groups |
| Where visible photos live | App only (backed up to the bucket), never Apple Photos |
| In the library grid | No: imported straight into Archive; shown on the person's page and in Archive |
| Choosing | Per person: Import tick (default on) and Hide tick (default off); tap a person to preview their photos and untick any |
| Hiding | Ticked-hidden people go to their own hidden folder, one code for all (the hide card); originals only, no HEIF step |
| Packaging | Whole people per zip, ~500 MB parts; import them one after another |

## Zip format

```
people.csv              same columns as Export to CSV (name required)
photos/<name>/<file>    folder name = that person's `name`
```

- `people.csv` optional: folders alone create people by name.
- Matched to existing people by name, case-insensitive (as CSV import).
- Unknown files and folders are skipped and counted.

## Flow

1. People ⋯ → Import People Zip → file browser.
2. Preview: each person with photo count (selected/total), new or already here, Import and Hide ticks; Select All / Deselect All. Tap → their photos, tap to leave one out.
3. Any Hide ticked → hide card once (code).
4. Progress on the page; the run finishes even if the page is left.
   - Profiles: `ProfileTransfer.write`.
   - Visible photo: `enqueueFile` → archived → tagged to the person.
   - Hidden photo: `enqueueFile` born hidden under
     `personAlbumCode(personId, code)` → plain-file custody; never tagged,
     never in counts, faces or the grid.
5. Done: "X people, Y photos (Z hidden)". Re-importing the same zip is a
   no-op per photo (content hash ids).

## Not doing

- No new dependency: `archive` is already in; entries are streamed one at
  a time from the file, never the whole zip in memory.
- No face analysis of hidden photos (as for every hidden photo).
- No per-person codes: one code, entered once.
- No HEIF conversion on import: the archive's photos are already small JPEGs.

## The data

`~/Downloads/people-export/build.py` (outside the repo: private data) →
`out/people.csv` (471) and `out/people-photos-NN-of-06.zip` (208 people,
20,024 photos, whole people per ~500 MB part).

## First met / last seen

- CSV columns `firstmet`, `lastseen` ↔ the profile's two fixed rows (First
  met, Last seen). Import only widens: earlier First met, later Last seen.
- Built from the earliest / latest record per person: life-logs contact
  dates and relationships, SMS (by phone), QQ logs, WeChat logs; photo EXIF
  only when nothing else dates someone. Source kept as a "First record" /
  "Last record" field.
- People sorts by Last seen (default), First met, Most photos or Name;
  undated last. Fallbacks: earliest/latest event or tagged photo. One
  grouped query for the dates, no per-person reads.
