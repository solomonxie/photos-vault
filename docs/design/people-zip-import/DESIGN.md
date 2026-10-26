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
| Choosing | Two steps. People: tick whose profiles to add/update. Photos: only people already in People (after step 1); Import tick (default on), Hide tick (default off), tap to preview and untick photos |
| Hiding | Ticked-hidden people go to their own hidden folder, one code for all (the hide card); originals only, no HEIF step |
| Packaging | Whole people per zip, ~500 MB parts; import them one after another |

## Zip format

```
people.csv              same columns as Export to CSV (name required)
photos/<name>/<file>    folder name = that person's `name`
```

- `people.csv` optional. Folders never create people: a folder whose name
  isn't in People is shown greyed, its photos not loadable.
- Matched to existing people by name, case-insensitive (as CSV import).
- Unknown files and folders are skipped and counted.

## Flow

1. More → Developer Options → Import People Zip → file browser.
2. Choose People (only if the zip has profiles): tick who to add or update;
   new / already here; conflicts resolved. Import N People, or Skip to Photos.
3. Choose Photos: people in People now; photo count, Import and Hide ticks,
   Select All. Tap → their photos, tap to leave one out. Ambiguous names
   pick an existing person (no New Person here).
4. Any Hide ticked → hide card once (code).
5. Progress on the page; the run finishes even if the page is left.
   - Profiles: `ProfileTransfer.write`.
   - Visible photo: `enqueueFile(isArchived: true)` (archived as written,
     never in the grid) → tagged to the person.
   - Hidden photo: `enqueueFile` born hidden under
     `personAlbumCode(personId, code)` → plain-file custody; never tagged,
     never in counts, faces or the grid.
6. Done: "X people, Y photos (Z hidden)". Re-importing the same zip is a
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

## Archived photos off the phone

- Suggestions → Albums → "Archived on This iPhone": archived, fully backed
  up, not locked or hidden. Opens the Remove from iPhone action (same live
  bucket check as every removal); they stay in Archive, shown from the bucket.

## CSV `mode` column

Per row, how it meets a profile already here:

| `mode` | Effect |
|---|---|
| empty | File values win; lists only grow; First met / Last seen only widen |
| `all` | Profile becomes the row: empty cells clear, lists (fields, groups, jobs, education, places, tags) hold only what the row lists |
| `conflict` | Row wins where values differ; nothing removed; dates set as given |
| `skip` | Existing wins; row fills blanks and adds new items only |

- One group per name across an import (rows join the same group).
- Undated zip photos take their person's Last seen (else First met), never
  the import day; photos dated only by import never count as first met /
  last seen.

## Merging people with hidden folders

- A person's folder code is `person:<id>:<digits>`; merging can't re-key it without the digits, and they're never guessed.
- `merge` records the gone id as an alias of the kept one (`person_alias`); aliases carry through later merges.
- Opening the kept person's folder with digits: each alias folder under the same digits moves into the kept one's (`AliasFolders.fold`, `HiddenTransition.moveRecord`). Same digits → one folder.
- A photo that can't move (adopted by an older build, or only in a bucket) leaves its alias folder open after the kept one.
- Batch Unhide and the delete guard include aliases.

## Person change history

- `person_change` (people.db): every change to a person's open profile, kept for good; the backup change log keeps only its newest 5,000 of everything.
- Written by triggers on the person tables, so no write path is missed. Rows under a code are never logged.
- Edits to one field within 2 minutes coalesce (the profile saves per keystroke).
- Merge mutes the triggers while rows move, then carries the gone person's history over and adds a `merged` entry.
- Former names = `name` (old value) and `merged` entries: shown as "Also known as" on the profile; People search matches them.
- Deleting a person deletes their history.

## Faces

- No analyze queue. `FaceAnalyzer` looks at the photo opened, or a batch picked (Select → More → Analyze Faces), one at a time in the background; opening another queues it, never cancels.
- Grid: a face badge beside the cloud on photos with faces.
- Face cutoff lowered from 0.4% to 0.1% of the frame; photos found empty under the old cutoff are looked at again.

## Conversations

- Chat history (QQ, WeChat, SMS, iMessage, WhatsApp, Messenger, Instagram) extracted on the Mac (`tools/chats`) into `.jsonl`, one message per line: `person`, `source`, `chat`, `at` (local, no zone), `from_me`, `sender`, `text`, `kind`. One-to-one chats only. A `.zip` of `.jsonl` files works too; several files at once.
- More → Developer Options → Import Chat History. Parsed off the UI isolate; a review row per name with its message count and date range.
- Attaches to people already here only, never creates one. One exact same-name person → attached by default (orange); similar or shared names wait for a choice; a name matching nobody is greyed and skipped unless pointed at someone (Change Name… or a candidate).
- `conversations.db`, table `message`, primary key sha256 of `chat|at|from_me|text`: re-importing adds nothing. Written in transactions of 1,000.
- Merge moves a person's messages to the kept one; delete forgets them.
- First met moves back to a person's earliest message, never forward. Driven by a `span_pending` flag set when their messages change (import, merge), cleared after an import or merge and on opening People: no scan per launch.
- Last seen is never written from photos or chats: shown as the latest of the date set by hand, other events, newest visible photo and newest message (`knownDates`), so removing a photo moves it back. Dates written that way by older builds are dropped once (exact photo/message time, no notes or tags).
- Profile → Conversations (n): bubbles, day separators, newest at the bottom, pages of 200 loaded on scrolling up; search within the person; chat label when they have several.
