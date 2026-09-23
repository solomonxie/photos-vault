# viewer

The whole UI: one scrollable Library page plus every screen it navigates to.
No tab bar — matches Photos' single-page IA.

```text
LibraryScreen                                          library_screen.dart
  │ AssetGridView  (CustomScrollView + anchor + scrubber)  asset_grid_view.dart
  │
  ├─ day-grouped grid: assetGridSlivers()               asset_grid.dart
  │     one sliver over a flat row list: PhotoGridSliver  photo_grid_sliver.dart
  │       geometry (sections, offsets, dates)            photo_grid_layout.dart
  │     renders AssetTile + StatusDot per asset          asset_grid.dart
  │     right-edge month scrubber: DateScrubber          date_scrubber.dart
  │     tap tile ──► DetailScreen                        detail_screen.dart
  │                    swipe-down-to-dismiss viewer + info panel (below image)
  │                    video ──► VideoControls            video_controls.dart
  │                    live photo / GIF ──► motion_playback.dart
  │                       hold · loop · freeze, one setting for both
  │                       live_photo_view.dart · gif_view.dart
  │                    Edit ──► crop/rotate  PhotoEditScreen  photo_edit_screen.dart
  │                          └─ AI Touch Up  ../photos/ai_touch_up_queue.dart
  │                             (background; result filed by createDerivedAsset)
  │     hold tile ──► selection mode + batch bar (tag / place / event / date)
  │
  ├─ "Collections" → Places / Events rows ──► AssetGroupScreen  asset_group_screen.dart
  │     live groups of AssetRecord.location / .event (set per photo in DetailScreen)
  │     Events' "AI Suggestions" ──► SmartCollectionScreen  smart_collection_screen.dart
  │
  ├─ "Collections" → People row ──► PeopleScreen            people_screen.dart
  │     named Person profiles, then the faces nobody has named yet
  │       (../photos/ai_analysis_store.dart's stored face boxes)
  │     "+" ──► a new Person straight into PersonProfileScreen, name focused;
  │             left unnamed, it is dropped rather than kept as an empty row
  │     tap a person ──► PersonPageScreen                   person_page_screen.dart
  │                         their tagged photos + a chevron to:
  │                       PersonProfileScreen                person_profile_screen.dart
  │                         tap the avatar ──► PersonAvatarPicker  person_avatar_picker.dart
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
        Optimize Storage   ──► StorageOptimizationScreen   storage_optimization_screen.dart
                                filter chips per problem, a card per photo
                                carrying its own fix; Select ⇒ batch
        Backup Status      ──► BackupScreen                 backup_screen.dart
        S3 Settings        ──► ../settings/settings_screen.dart
```

`scroll_stop_guard.dart` sits over all of it (mounted in `app.dart`): a
touch that lands on a still-moving page stops it and never opens the row
underneath. Flutter gives that away for a fling but not for a bounce
settling back — the case you hit at the end of every long scroll.

Every list-grid screen above (Library, Favorites, PrivateAlbum, PersonPage,
RecentlyDeleted, Album, AssetGroup) mounts `asset_grid_view.dart`'s
`AssetGridView` — the grid plus the two things that make a decade-deep
library usable: it opens scrolled to the *newest* photo (the grid reads
oldest-first, so every screen sorts ascending), and it carries the
right-edge date scrubber. They share `asset_grid.dart`'s
`assetGridSlivers()` / `AssetTile` / `TileAction`, and push into the same
`DetailScreen` with their own `onDelete`/`onToggleFavorite` callbacks — the only thing that differs
per screen is which `AssetRecord` filter it applies and which actions it
offers. `asset_picker_screen.dart`'s multi-select grid is the shared
"pick from the full library" flow behind Private Albums' Move/Copy and
People's "Add Photos".

`asset_grid.dart`'s `StatusDot` is the tile's bottom-right badge and the
answer to "where does this photo actually live?" — a filled cloud when
only the bucket has it, a dotted ring when the bucket doesn't have it yet,
nothing when both do. The top-left corner says what *kind* of thing it is
(GIF, Live Photo) and the top-right that it's a video, which is why the
cloud moved out of that chain: a cloud-only Live Photo was losing its own
marker to it.

`built_in_album.dart` holds the two cards the library makes itself,
Favourites and Videos: no row in the album table, and a gradient + glyph
cover rather than the newest photo in them. An album somebody made is
*about* its contents; these two are about a property, and the newest video
in the library says nothing about "Videos" that the label doesn't. It also
stops the pair re-skinning themselves every time a photo is taken. A photo
can still be chosen for either — hold one on the Favourites or Videos grid
and "Use as Album Cover"; the same action on the photo that already *is*
the cover puts the colour back. The choice is filed in app state, since
these two have no album row to hang a `coverLocalId` on.

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

The grid is **one** sliver, not one per day. `photo_grid_layout.dart` flattens
the library into fixed-height rows (a day header, then rows of three) and
precomputes each day's offset, so "what's at scroll offset X" and "where does
this day start" are binary searches rather than walks. `photo_grid_sliver.dart`
is a `RenderSliverFixedExtentBoxAdaptor` that reads its offsets from there —
Flutter's own `SliverVariedExtentList` re-walks its whole item list several
times per frame, which is fine for hundreds of rows and hopeless for the tens
of thousands ten years of photos come to. That exact geometry is also what lets
`AssetGridView` jump straight to the newest photo and `date_scrubber.dart`
label itself with the month under the handle.
