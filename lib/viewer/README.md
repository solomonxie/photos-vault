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
  │
  ├─ "Media Types" section
  │     Photos / Videos row ──► MediaTypeScreen(isVideo)  media_type_screen.dart
  │                                reuses assetGridSlivers() + DetailScreen
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

`BackupScreen` reads local upload-status counts only (`../storage`) — it
doesn't talk to S3.

The grid tiles' "Hide" action, and Utilities' "Hidden" row, both go through
`private_album_gate.dart`'s passcode sheet (`../storage/private_album_store.dart`)
rather than a plain hidden flag — see DESIGN.md's "Private Albums" section.
