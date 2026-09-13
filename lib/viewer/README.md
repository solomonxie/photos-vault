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
  └─ "Utilities" section
        Import Photos      ──► (no push) ManualAddService.pickAndEnqueue()
        Favorites          ──► FavoritesScreen             favorites_screen.dart
        Hidden             ──► HiddenScreen                hidden_screen.dart
        Recently Deleted   ──► RecentlyDeletedScreen        recently_deleted_screen.dart
        Backup Status      ──► BackupScreen                 backup_screen.dart
        S3 Settings        ──► ../settings/settings_screen.dart
```

Every list-grid screen above (Library, MediaType, Favorites, Hidden,
RecentlyDeleted) shares `asset_grid.dart`'s `assetGridSlivers()` /
`AssetTile` / `TileAction`, and pushes into the same `DetailScreen` with its
own `onDelete`/`onToggleFavorite` callbacks — the only thing that differs
per screen is which `AssetRecord` filter it applies and which actions it
offers.

`BackupScreen` reads local upload-status counts only (`../storage`) — it
doesn't talk to S3.
