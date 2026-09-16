# viewer

The whole UI: one scrollable Library page plus every screen it navigates to.
No tab bar — matches Photos' single-page IA.

```text
LibraryScreen                                          library_screen.dart
  │ CustomScrollView
  │
  ├─ day-grouped grid: assetGridSlivers()               asset_grid.dart
  │     renders AssetTile + StatusDot per asset          asset_grid.dart
  │     tap tile ──► DetailScreen                        detail_screen.dart
  │                    swipe-down-to-dismiss viewer + info panel (below image)
  │                    Edit ──► crop/rotate  PhotoEditScreen  photo_edit_screen.dart
  │                          └─ AI Touch Up  ../photos/ai_touch_up_queue.dart
  │                             (background; result filed by createDerivedAsset)
  │     hold tile ──► selection mode + batch bar (tag / place / event / date)
  │
  ├─ "Media Types" section
  │     Photos / Videos row ──► MediaTypeScreen(isVideo)  media_type_screen.dart
  │                                reuses assetGridSlivers() + DetailScreen
  │
  ├─ "Collections" → Places / Events rows ──► AssetGroupScreen  asset_group_screen.dart
  │     live groups of AssetRecord.location / .event (set per photo in DetailScreen)
  │     Events' "AI Suggestions" ──► SmartCollectionScreen  smart_collection_screen.dart
  │
  ├─ "Collections" → People row ──► PeopleScreen            people_screen.dart
  │     list of named Person profiles (../photos/person_store.dart)
  │     tap a person ──► PersonPageScreen                   person_page_screen.dart
  │                         their tagged photos + a chevron to:
  │                       PersonProfileScreen                person_profile_screen.dart
  │                         bio fields (passcode+hint lock over them),
  │                         relationships ──► PersonGraphScreen  person_graph_screen.dart
  │                         location history
  │
  └─ "Utilities" section
        Import Photos      ──► (no push) ManualAddService.pickAndEnqueue()
        Favorites          ──► FavoritesScreen             favorites_screen.dart
        Hidden             ──► passcode sheet, then:        private_album_gate.dart
                                PrivateAlbumScreen            private_album_screen.dart
        Recently Deleted   ──► RecentlyDeletedScreen        recently_deleted_screen.dart
        Backup Status      ──► BackupScreen                 backup_screen.dart
        S3 Settings        ──► ../settings/settings_screen.dart
```

Every list-grid screen above (Library, MediaType, Favorites, PrivateAlbum,
PersonPage, RecentlyDeleted) shares `asset_grid.dart`'s `assetGridSlivers()` /
`AssetTile` / `TileAction`, and pushes into the same `DetailScreen` with its
own `onDelete`/`onToggleFavorite` callbacks — the only thing that differs
per screen is which `AssetRecord` filter it applies and which actions it
offers. `asset_picker_screen.dart`'s multi-select grid is the shared
"pick from the full library" flow behind Private Albums' Move/Copy and
People's "Add Photos".

Every pick-a-value field (location, event, tag, school, person) goes through
`search_picker_sheet.dart` — a drop-down sheet over the current page, not a
push. `person_picker_sheet.dart` is the same sheet with "New Person…" wired
to `PersonStore.create`.

Edits never overwrite: `PhotoEditScreen` and the AI queue both hand their
bytes to `../photos/derived_asset.dart`, which files a new library item
carrying the source's date/description/tags/place/event/people.

`BackupScreen` reads local upload-status counts only (`../storage`) — it
doesn't talk to S3.

The grid tiles' "Hide" action, and Utilities' "Hidden" row, both go through
`private_album_gate.dart`'s passcode sheet (`../storage/private_album_store.dart`)
rather than a plain hidden flag — see DESIGN.md's "Private Albums" section.
