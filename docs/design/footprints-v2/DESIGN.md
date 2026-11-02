# Footprints v2

Interface: `UIUX_DESIGN.md` · Build: `IMPLEMENT_PLAN.md` · v1: `../travel-diary.md`

## Problem
Footprints (places, impressions, travel plans) lives only in one phone's
`travel.db`. A second phone and the extension never see it. Writing is manual:
photos are attached by hand, routes typed stop by stop. The screens are text
lists with no pictures, no search, no sense of when you were somewhere.

## Goals
- Places, impressions and plans sync through the cloud log, both ways, to
  every phone; the extension shows them read-only.
- A new impression offers the photos taken there that day.
- A travel plan can be drafted from photos: one stop per place per day.
- Visual, searchable screens (see `UIUX_DESIGN.md`).

## Non-goals
- Editing impressions or plans in the extension (read-only v2).
- Real road paths for legs (`MKDirections`): still straight lines.
- Sharing or exporting a plan.

## Decision: sync
Ride the existing per-device op log (`../cloud-sync/PROTOCOL.md`), three
entities from `travel.db`. Same capture triggers, same merge, same applier
pattern as albums.

| `e` | LWW | text (conflict-kept) | sets |
|---|---|---|---|
| `place` | `kind`, `lat`, `lng`, `parent_id`, `country`, `address`, `category`, `created_at`, `deleted_at` | `name`, `description` | — |
| `entry` | `place_id`, `kind`, `at`, `rating`, `created_at`, `deleted_at` | `title`, `text` | `tags`, `photos`, `people` |
| `route` | `starts`, `ends`, `created_at`, `deleted_at`, `stops` | `title`, `note`, `stops` | `photos`, `people` |

- `route.stops`: the whole ordered list as one JSON string
  (`[{place, arrived, note, mode, leg, review}]`, leg = to the next stop).
  Reordering is one value, so two devices never interleave half-lists; a
  concurrent edit is kept as a conflict, never silently lost.
- Stops and legs are captured by triggers on `stop`/`leg` that snapshot the
  route's whole list (`json_group_array`) inside the writer's transaction.
- Links (`link` rows) are OR-set members; a link to a hidden photo never
  leaves the phone (same filter as album members).
- A deleted row is `set deleted_at`; the applier deletes it here, with its
  stops and links.
- Entries save by upsert, links by diff, so an edit is `set`/`madd`/`mrem`,
  not a re-`add` that would trample a concurrent edit.
- The old pin-only `place` (`city`, `photos`) was never written by any
  phone; the extension now resolves country/city by walking `parent_id`.

## Decision: suggestions
- **Photos for an impression**: same day (local date) and within the place's
  reach (300 m pin, 1.5 km area, or the city/country by location name).
  One pass over the library's place groups, already in memory.
- **Draft plan**: photos in a date range → per day, GPS clusters (≤ 2 km,
  ≥ 3 photos) in time order → stops at the nearest saved place, else a new
  pin named by reverse geocoding. The user confirms before anything is saved.

## Data & integrations
- `travel.db` v4: no schema change for sync beyond capture tables
  (`sync_outbox`, `sync_flag`), which ride the existing backup blob.
- Cost: hundreds of places, thousands of entries — small next to photos.

## Risks
- A phone on an older build ignores the new entities (they're unknown `e`);
  its own travel edits wait in its outbox until updated. Harmless.
- `stops` conflicts have no resolve UI yet: the newer value shows, the
  other stays in `conflicts` for recovery.
