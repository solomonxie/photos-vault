# UI/UX mockups — Photos Vault

Every surface drawn as it is built today. `../UIUX-DESIGN.md` carries the
style rules and the reasoning; these files carry the pictures.

Glyphs follow the `uiux` skill (`references/notation.md` + `text-figma.md`):
`─●` on · `○─` off · `[ A | B ]` segmented · `[[ x ]]` primary · `[ x ]`
secondary · `( x )` text button · `›` pushes · `⟳` working · `←` annotation ·
`!` destructive · `·` disabled · `[brackets]` = OS-owned surface.

## Screen map

```
 launch
   │
   ▼
 LibraryScreen ── one page: day grid, then collections, then utilities
   │  + add files ──▶ [Files picker · OS]
   │  🔍 search ──▶ filters the grid in place
   │  tile ──▶ DetailScreen ──▶ [Edit ▸ Crop | Rotate | AI Touch Up]
   │                        └──▶ [Share ▸ Original | Export As…]
   │  hold tile ──▶ selection mode (bar at the bottom)
   │  Albums ──▶ AlbumScreen · FavoritesScreen · AssetGroupScreen
   │  People (More) ──▶ PeopleScreen ──▶ PersonPageScreen
   │                                      └─▶ PersonProfileScreen
   │                                            ├─▶ PersonHistoryDetail
   │                                            └─▶ PersonGraphScreen
   │  Places / Events ──▶ AssetGroupScreen
   │  Events (AI Suggestions) ──▶ SmartCollectionScreen
   └─ Utilities
        Cloud Settings ──▶ SettingsScreen ──▶ BucketBrowser ─▶ (deeper)
        │                        └─▶ [AddS3Backup]   └─▶ ObjectPreview
        Backup Queue ──▶ BackupQueueScreen
        Analyze Queue ──▶ AnalyzeQueueScreen
        AI Settings ──▶ AiSettingsScreen ──▶ [AddKey sheet]
        Hidden ──▶ [PrivateAlbumGate] ──▶ PrivateAlbumScreen
        Recently Deleted ──▶ RecentlyDeletedScreen
        Optimize Storage ──▶ StorageOptimizationScreen
```

## Files

| File | Covers |
|---|---|
| `library.md` | the one page: grid, search, collections, utilities, selection |
| `detail.md` | media viewer, info panel, edit and share menus |
| `people.md` | people list, person page, profile, history, graph |
| `collections.md` | albums, favorites, groups, smart collections, hidden, deleted |
| `cloud.md` | Cloud Settings, add bucket, bucket browser |
| `queue.md` | sync queue sheet |
| `storage.md` | optimize storage: problem filters, per-photo fixes, batch |
| `ai.md` | AI settings and AI touch-up |
| `components.md` | tiles, rows, scrubber, section chrome |
