# Footprints v2 — build

## Phase 1: Sync
Everything else is per-device until this lands; the extension reads it.

- [x] T1.1 Capture on `travel.db` (place, entry, route, stop/leg snapshot, link); entry upsert, link diff — see `lib/photos/travel_store.dart`, `lib/sync/capture.dart` — depends: none
- [x] T1.2 Translate travel rows → ops; private photo links filtered — see `lib/sync/translate.dart`, `lib/sync/log_sync.dart` — depends: T1.1
- [x] T1.3 Bootstrap queues travel; applier writes travel rows — see `lib/sync/bootstrap.dart`, `lib/sync/apply.dart` — depends: T1.2
- [x] T1.4 CloudSync wiring (app + BG task); PROTOCOL.md entity table — see `lib/sync/cloud_sync.dart`, `lib/main.dart` — depends: T1.3
- [x] T1.5 Extension: places tree from `parent_id`; impressions + plans on place page — see `extension/src/model.ts`, `extension/src/app.ts` — depends: T1.2

## Phase 2: Suggestions
Need only local data; independent of each other.

- [x] T2.1 Same-day nearby photos in the impression editor — see `lib/viewer/travel_entry_editor.dart` — depends: none
- [x] T2.2 Draft plan from photos: clusterer + preview sheet — see `lib/photos/`, `lib/viewer/route_list_view.dart` — depends: none

## Phase 3: Screens
- [x] T3.1 Library section hero + On This Day — see `lib/viewer/library_screen.dart` — depends: none
- [x] T3.2 Places: map sheet, flags, thumbnails, search, sort/filter — see `lib/viewer/places_screen.dart` — depends: none
- [x] T3.3 Place page: cover, rating, visits, swipe actions — see `lib/viewer/place_screen.dart` — depends: none
- [x] T3.4 Impressions: thumbnails, year groups, search; reading view photos first — see `lib/viewer/footprints_screens.dart` — depends: none
- [x] T3.5 Route page day dividers + stop photo strips — see `lib/viewer/route_screen.dart` — depends: none
- [x] T3.6 Empty-state buttons; delete Undo toast — depends: T3.2–T3.5
- [x] T3.7 Tests, build, install — depends: all
