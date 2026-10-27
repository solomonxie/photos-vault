# Travel diary

Write about places, and string places into routes.

## Goals

- **Diary entry** at a place: dated, any length, Markdown (reuses `words_markdown.dart`).
- **Impression** of a place: one per visit (dated), so 2019 and 2025 can differ. Short text, optional rating, tags ("quiet", "go back").
- **Route**: an ordered list of places, each **leg** between two stops with its own commentary. Works at any scale: city to city (a trip), or point to point inside a city (a walk).
- Photos and people attach to all three; nothing is copied.

## Non-goals

- Trip planning, bookings, itineraries ahead of time.
- Sharing or publishing.
- Turn-by-turn navigation, offline map downloads.
- Profiles' "Places Lived" stays as it is (where someone lived, not travel).

## Model: `travel.db`

| table | columns |
|---|---|
| `place` | id, name, kind (`city` · `point`), lat, lng, parent_id (point → its city), country, created_at |
| `entry` | id, place_id, kind (`diary` · `impression`), at (day it's about), title, text, rating (1–5, impressions only), tags, created_at, updated_at |
| `route` | id, title, note (intro), starts, ends, created_at |
| `stop` | route_id, position, place_id, arrived (date, null), note (what happened here) |
| `leg` | route_id, position (from stop n to n+1), mode (walk · drive · train · flight · boat · other), note |
| `link` | owner_kind (entry · route), owner_id, target_kind (asset · person), target_id |

- A place is shared: three diary entries and two routes can all point at the same "Kyoto".
- A leg is keyed by its position, so reordering stops moves the legs with them; a leg whose stops changed is kept and flagged for review, never dropped silently.
- Indexes: `entry(place_id, at)`, `stop(route_id, position)`, `stop(place_id)`, `link(owner_kind, owner_id)`, `link(target_kind, target_id)`.
- One query per screen; links fetched in one batch and grouped in Dart (no N+1).

## Map: native MapKit, no package

- `MKMapView` in a `UiKitView` platform view, with `MethodChannel` `byo.photos/map`: set pins, a polyline, camera; it sends back pin taps and long-press coordinates.
- Search: `MKLocalSearch` (cities and points, autocomplete as you type).
- Thumbnails for lists: `MKMapSnapshotter` renders off the main thread, cached as JPEG under `Caches/map_snapshots/`.
- Cost: about 0 MB, because MapKit ships with iOS. `flutter_map` plus tiles would add around 1–2 MB and need a tile server. That matters: the size budget is 25 MB and the app is at 24.9.
- Legs are straight lines; flights are drawn as great-circle arcs. Walking and driving paths via `MKDirections` come later (phase 3).

## Adding a place

1. **Search** by name (MapKit).
2. **Long-press** the map.
3. **From a photo**: the detail screen gets "Write about this place", which uses the photo's GPS. It needs no location permission and is the most natural way in for past trips.
4. **Here**: current location. This adds a When-In-Use location prompt, but only the first time it's tapped.

A new point finds its city by reverse geocoding its locality (`geocoding`, already a dependency) and attaches to it, creating the city if needed.

## Screens

- **Places** (Library → More) becomes Travel; the photo groups by place stay, as the Photos tab:
  - Segmented control: Places · Routes · Photos (today's place groups).
  - Places: map on top with every place pinned, and a list below grouped by country, then city.
  - Routes: cards with a map snapshot, title and dates, newest first.
- **Place page**:
  - Small map at the top.
  - Impressions, one per visit, newest first, with rating.
  - Diary entries, newest first.
  - Photos taken there: matched by the photo's location name for a city, and attached by hand for a point.
  - Points within this city; routes that pass through.
- **Entry editor**: title, date (defaults to today), Markdown text, plus photos and people chips.
- **Route page**:
  - Full map with numbered pins and the polyline.
  - Below it, a vertical timeline: stop, then leg (mode icon and commentary), then stop, and so on.
  - Tapping a stop or leg pans the map to it.
- **Route editor**:
  - Add a stop by search, an existing place, a long-press or photos.
  - Drag to reorder.
  - Each leg has a mode picker and a note.

## Connects to the rest of the app

- **Photos:** a photo detail with GPS shows "Write about this place", or "Diary for Kyoto (3)" when entries exist.
- **People:** the profile gains a "Travels" section listing the routes and entries that person is linked to.
- **Change log:** linking a person to a route or entry writes a line to that person's change log, as imports already do.

## Backup

- `travel.db` joins `DatabaseHome.names`, so it's in the daily snapshot and restored on a fresh install. Every write moves the change mark.
- Tests prove both.
- Map snapshots are a regenerable cache and are knowingly excluded.
- Photos and people are linked by id, and those are already backed up.

## Performance

- No map work in `build`: pins are sent to native in one batch when the data changes, not per frame.
- The list of places is computed once per reload and kept in a field.
- Snapshot rendering and file reads are async, never on the UI isolate.
- Expected volume is hundreds of places and thousands of entries: small next to the photo library.

## Phases

1. Places, impressions and diary entries; native map and search; "Write about this place" from photos. Backup.
2. Routes: stops, legs, the route page and editor; the "Travels" section on profiles.
3. Suggestions:
   - Draft a route from photos: GPS clusters by day become stops in time order, for the user to confirm.
   - `MKDirections` paths for walk and drive legs.

## Open questions

- Can an entry belong to a route without a place (e.g. a day on the train)? Proposed: an entry may point at a leg instead of a place.
