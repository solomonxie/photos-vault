import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:intl/intl.dart';
import 'package:photo_manager/photo_manager.dart';

import '../l10n/app_localizations.dart';
import '../photos/thumbnail_cache.dart';
import '../photos/photo_library_service.dart';
import '../storage/asset_record.dart';
import 'photo_grid_layout.dart';
import 'photo_grid_sliver.dart';

/// One long-press context-menu action offered on a grid tile (e.g.
/// Favorite/Unfavorite, Hide, Delete, Recover) — each screen that shows a
/// grid (Library, Favorites, Hidden, Recently Deleted) supplies its own set.
class TileAction {
  const TileAction({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.isDestructive = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final bool isDestructive;
}

String dayLabel(AppLocalizations l10n, DateTime dt) {
  final now = DateTime.now();
  final date = DateTime(dt.year, dt.month, dt.day);
  final today = DateTime(now.year, now.month, now.day);
  final diff = today.difference(date).inDays;
  if (diff == 0) return l10n.libraryToday;
  if (diff == 1) return l10n.libraryYesterday;
  return DateFormat.yMMMd().format(dt);
}

/// Builds the day-grouped square grid as slivers — embed directly in any
/// `CustomScrollView`, or let [AssetGridView] do it for you. Shared by the
/// main Library page and the Favorites/Hidden/Recently Deleted screens.
///
/// [records] read oldest-first, newest at the bottom, like Photos; every
/// screen sorts that way before calling.
List<Widget> assetGridSlivers({
  required BuildContext context,
  required List<AssetRecord> records,
  required void Function(AssetRecord) onTap,
  required List<TileAction> Function(AssetRecord) actionsFor,

  /// Multi-select mode: non-null shows a checkmark overlay per tile (checked
  /// iff its `localId` is in the set) instead of the normal favorite/status
  /// badges — `onTap` is expected to toggle membership rather than open the
  /// detail viewer while this is set. `null` (the default) is plain
  /// single-tap browsing, unchanged.
  Set<String>? selectedIds,
  String? markedId,

  /// Long-press behaviour. Given, holding a tile calls this (Photos' "hold
  /// to start selecting") instead of opening the [actionsFor] context menu
  /// — the actions then belong on the selection's own action bar.
  void Function(AssetRecord)? onLongPress,

  /// The precomputed geometry, when the caller needs it for itself (the
  /// date scrubber, jumping to the newest photo). Computed from the screen
  /// width when omitted.
  PhotoGridLayout? layout,

  /// Identifies the grid's sliver render object, so a caller can ask the
  /// viewport where the grid starts.
  Key? gridKey,

  /// See [PhotoManagerThumbnail.onMissing].
  void Function(AssetRecord)? onMissing,

  /// See [AssetTile.onSelectDragUpdate].
  void Function(Offset globalPosition)? onSelectDragUpdate,
  VoidCallback? onSelectDragEnd,
}) {
  final l10n = AppLocalizations.of(context)!;
  final grid =
      layout ??
      PhotoGridLayout.of(
        records: records,
        width: MediaQuery.sizeOf(context).width,
      );
  if (grid.isEmpty) return const [];

  return [
    PhotoGridSliver(
      key: gridKey,
      layout: grid,
      delegate: SliverChildBuilderDelegate((context, index) {
        final row = grid.rowAt(index);
        if (row.isHeader) {
          return _DayHeader(
            label: dayLabel(l10n, grid.sections[row.section].day),
          );
        }
        return Padding(
          padding: EdgeInsets.only(
            left: grid.horizontalPadding,
            right: grid.horizontalPadding,
            bottom: grid.spacing,
          ),
          child: Row(
            children: [
              for (var i = 0; i < grid.crossAxisCount; i++) ...[
                if (i > 0) SizedBox(width: grid.spacing),
                SizedBox(
                  width: grid.tileExtent,
                  child: i < row.recordCount
                      ? _tileFor(
                          grid.records[row.firstRecord + i],
                          extent: grid.tileExtent,
                          onTap: onTap,
                          onLongPress: onLongPress,
                          actionsFor: actionsFor,
                          selectedIds: selectedIds,
                          markedId: markedId,
                          onMissing: onMissing,
                          onSelectDragUpdate: onSelectDragUpdate,
                          onSelectDragEnd: onSelectDragEnd,
                        )
                      : const SizedBox.shrink(),
                ),
              ],
            ],
          ),
        );
      }, childCount: grid.rowCount),
    ),
  ];
}

Widget _tileFor(
  AssetRecord record, {
  required double extent,
  required void Function(AssetRecord) onTap,
  required void Function(AssetRecord)? onLongPress,
  required List<TileAction> Function(AssetRecord) actionsFor,
  required Set<String>? selectedIds,
  required String? markedId,
  required void Function(AssetRecord)? onMissing,
  required void Function(Offset globalPosition)? onSelectDragUpdate,
  required VoidCallback? onSelectDragEnd,
}) => AssetTile(
  key: ValueKey(record.localId),
  record: record,
  extent: extent,
  onTap: () => onTap(record),
  onLongPress: onLongPress == null ? null : () => onLongPress(record),
  onMissing: onMissing == null ? null : () => onMissing(record),
  onSelectDragUpdate: onSelectDragUpdate,
  onSelectDragEnd: onSelectDragEnd,
  actions: actionsFor(record),
  selected: selectedIds?.contains(record.localId),
);

class _DayHeader extends StatelessWidget {
  const _DayHeader({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
    child: Align(
      alignment: Alignment.bottomLeft,
      child: Text(
        label,
        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 20),
      ),
    ),
  );
}

/// The best image available for [record]: the live local original first,
/// then the OS library, and only then the app's own cached thumbnail —
/// [placeholder] when none of them resolves.
///
/// The cache is the *fallback*, for when there's no original left
/// (cloud-only), or the live source can't be read — a stale absolute path
/// (the app container's UUID changes on reinstall), or an original in a
/// format the engine can't decode (HEIC). Preferring it would blank a tile
/// whose real photo is right there.
Widget assetImage(
  AssetRecord record, {
  required Widget Function() placeholder,
  BoxFit fit = BoxFit.cover,
  int? thumbnailSize,
  bool fittedThumbnail = false,
  VoidCallback? onMissing,
}) {
  Widget cached() {
    final thumbnail = record.thumbnailPath;
    if (thumbnail == null) return placeholder();
    return Image.file(
      File(thumbnail),
      fit: fit,
      errorBuilder: (context, error, stackTrace) => placeholder(),
    );
  }

  if (record.localDeleted) return cached();
  final path = record.sourcePath;
  if (path != null) {
    return Image.file(
      File(path),
      fit: fit,
      // Decoded to the size it is drawn at, not the size it was shot at.
      // Without this a grid of manually-added photos decodes a dozen
      // 12 MP originals into full-resolution bitmaps — tens of megabytes
      // each, held by the image cache, for a 95-point square.
      cacheWidth: thumbnailSize,
      errorBuilder: (context, error, stackTrace) => cached(),
    );
  }
  final libraryId = PhotoLibraryService.libraryIdOf(record);
  if (record.sourceType == AssetSourceType.photoManager && libraryId != null) {
    return PhotoManagerThumbnail(
      assetId: libraryId,
      fit: fit,
      size: thumbnailSize,
      fitted: fittedThumbnail,
      placeholder: placeholder,
      onMissing: onMissing,
    );
  }
  return cached();
}

/// The same sources [assetImage] draws, most-preferred first, as image
/// providers — for a caller that needs the pixels themselves (cropping to a
/// face box) rather than a widget. Empty when nothing resolves.
///
/// More than one because the preferred source can still fail to *decode*
/// (an HEIC original), and the cached thumbnail behind it is a JPEG this
/// app wrote.
Future<List<ImageProvider>> assetImageProviders(AssetRecord record) async {
  final providers = <ImageProvider>[];
  if (!record.localDeleted) {
    final path = record.sourcePath;
    if (path != null) providers.add(FileImage(File(path)));
    final libraryId = PhotoLibraryService.libraryIdOf(record);
    if (path == null &&
        record.sourceType == AssetSourceType.photoManager &&
        libraryId != null) {
      final bytes = await photoManagerThumbnailBytes(libraryId);
      if (bytes != null) providers.add(MemoryImage(bytes));
    }
  }
  final thumbnail = record.thumbnailPath;
  if (thumbnail != null) providers.add(FileImage(File(thumbnail)));
  return providers;
}

class AssetTile extends StatelessWidget {
  const AssetTile({
    super.key,
    required this.record,
    required this.extent,
    required this.onTap,
    required this.actions,
    this.selected,
    this.marked = false,
    this.onLongPress,
    this.onMissing,
    this.onSelectDragUpdate,
    this.onSelectDragEnd,
  });

  final AssetRecord record;

  /// Side of the square tile, in logical pixels.
  ///
  /// Sized outright rather than an `AspectRatio` filling whatever it's
  /// given: the long-press context menu lays its preview out inside a
  /// `FittedBox`, which offers unbounded constraints, and an `AspectRatio`
  /// handed those throws — so the menu never opened at all.
  final double extent;
  final VoidCallback onTap;
  final List<TileAction> actions;

  /// Given, replaces the long-press context menu (see `assetGridSlivers`).
  final VoidCallback? onLongPress;

  /// `null` outside multi-select mode; `true`/`false` while selecting (see
  /// `assetGridSlivers`' `selectedIds`).
  final bool? selected;

  /// The one tile a screen is *about* — the face you tapped to open a
  /// group, say. Drawn with a ring so it is findable in a grid of
  /// near-identical photos, where "the one you came from" is otherwise
  /// indistinguishable from the forty it gathered.
  final bool marked;

  /// See [PhotoManagerThumbnail.onMissing].
  final VoidCallback? onMissing;

  /// Where the finger is, while it is still down from the hold that
  /// started selecting — or dragged sideways across the grid once it has.
  /// Reported in global coordinates: which tile that is, is a question for
  /// whoever owns the grid, not for one tile in it.
  final void Function(Offset globalPosition)? onSelectDragUpdate;
  final VoidCallback? onSelectDragEnd;

  /// Last resort when no image resolves. A video gets the dark play-glyph
  /// tile rather than the grey photo one — for a manually-added file
  /// there's no frame to decode, so this *is* its tile.
  Widget _placeholder() => record.isVideo
      ? const ColoredBox(
          color: CupertinoColors.darkBackgroundGray,
          child: Icon(
            CupertinoIcons.play_circle_fill,
            color: CupertinoColors.white,
            size: 28,
          ),
        )
      : const ColoredBox(
          // Dark, like everything around it. A light grey square in a dark
          // grid reads as a flash of white where a photo should be — which
          // is exactly what a photo deleted over in Photos looked like.
          color: CupertinoColors.darkBackgroundGray,
          child: Icon(
            CupertinoIcons.photo,
            color: CupertinoColors.systemGrey,
            size: 24,
          ),
        );

  @override
  Widget build(BuildContext context) {
    final tile = GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      // The hold that starts selecting has already won the arena, so every
      // move after it comes here rather than to the scroll view — which is
      // what lets one unbroken gesture hold, then sweep across the grid.
      onLongPressMoveUpdate: onSelectDragUpdate == null
          ? null
          : (details) => onSelectDragUpdate!(details.globalPosition),
      onLongPressEnd: onSelectDragEnd == null
          ? null
          : (_) => onSelectDragEnd!(),
      // Once selecting, a sideways drag across tiles picks them up too.
      // Horizontal only: up and down still belong to the grid, which has a
      // library to scroll through.
      onHorizontalDragUpdate: selected == null || onSelectDragUpdate == null
          ? null
          : (details) => onSelectDragUpdate!(details.globalPosition),
      onHorizontalDragEnd: selected == null || onSelectDragEnd == null
          ? null
          : (_) => onSelectDragEnd!(),
      child: MetaData(
        // What [onSelectDragUpdate]'s reader hit-tests for: the tile under
        // the finger identifies itself, so nobody has to reconstruct the
        // grid's geometry from a scroll offset.
        metaData: record,
        behavior: HitTestBehavior.opaque,
        child: _tile(),
      ),
    );
    // No actions, no menu. A grid can exist where a long press has
    // nothing to offer — picking faces in or out of a group is one — and
    // `CupertinoContextMenu` asserts rather than degrading, so every tile
    // on such a screen would fail to build.
    if (onLongPress != null || actions.isEmpty) return tile;
    return CupertinoContextMenu(
      actions: [
        for (final action in actions)
          CupertinoContextMenuAction(
            isDestructiveAction: action.isDestructive,
            trailingIcon: action.icon,
            onPressed: () {
              Navigator.of(context).pop();
              action.onPressed();
            },
            child: Text(action.label),
          ),
      ],
      child: tile,
    );
  }

  Widget _tile() {
    final video = record.isVideo;

    return SizedBox.square(
      dimension: extent,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Videos draw their poster frame like any other tile — the OS
            // library hands one back for them too, and a black square with
            // a play glyph told you nothing about which video it was.
            // Aspect-fit, not the square crop the OS would give by
            // default: `cover` on the tile crops it back to a square
            // anyway, and asking this way means the viewer opening on top
            // of this tile already has the whole picture in memory to put
            // up on its first frame. 200 on the long edge leaves the short
            // edge about where the old 150 square was.
            assetImage(
              record,
              thumbnailSize: 200,
              fittedThumbnail: true,
              placeholder: _placeholder,
              onMissing: onMissing,
            ),
            if (marked)
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: CupertinoColors.activeBlue,
                        width: 3,
                      ),
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
              ),
            if (record.isGif)
              const Positioned(
                top: 4,
                left: 4,
                child: Text(
                  'GIF',
                  style: TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.w700,
                    color: CupertinoColors.white,
                  ),
                ),
              )
            else if (record.isLivePhoto)
              const Positioned(
                top: 4,
                left: 4,
                child: Icon(
                  CupertinoIcons.smallcircle_circle,
                  size: 14,
                  color: CupertinoColors.white,
                ),
              ),
            if (video)
              const Positioned(
                top: 4,
                right: 4,
                child: Icon(
                  CupertinoIcons.video_camera_solid,
                  size: 14,
                  color: CupertinoColors.white,
                ),
              ),
            if (record.isFavorite)
              const Positioned(
                bottom: 4,
                left: 4,
                child: Icon(
                  CupertinoIcons.heart_fill,
                  size: 14,
                  color: CupertinoColors.white,
                ),
              ),
            Positioned(bottom: 4, right: 4, child: StatusDot(record: record)),
            if (selected != null) ...[
              if (selected!) const ColoredBox(color: Color(0x662E7DFF)),
              Positioned(
                top: 4,
                right: 4,
                child: Icon(
                  selected!
                      ? CupertinoIcons.checkmark_circle_fill
                      : CupertinoIcons.circle,
                  color: selected!
                      ? CupertinoColors.activeBlue
                      : CupertinoColors.white,
                  size: 20,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The tile's bottom-right badge, which is where "where does this photo
/// actually live?" is answered.
///
/// Two states, and they can't both be true: a filled cloud for a photo
/// that is only in the bucket now, and a light dotted ring for one not
/// backed up yet. A photo in both places gets nothing at all, so a library
/// that is fully synced and fully on the device reads as clean instead of
/// every tile carrying a checkmark.
///
/// The cloud took this corner rather than the top-left one it used to
/// share with GIF and Live Photo: those say what *kind* of thing the photo
/// is, and a cloud-only Live Photo was losing its marker to the chain. It
/// also can't collide with the ring — cloud-only means the original is up
/// there, so the ring would never draw for one.
class StatusDot extends StatelessWidget {
  const StatusDot({super.key, required this.record});

  final AssetRecord record;

  @override
  Widget build(BuildContext context) {
    if (record.localDeleted) {
      return const Icon(
        CupertinoIcons.cloud_fill,
        size: 14,
        color: CupertinoColors.white,
        // White on a white photo is nothing at all, and this is the badge
        // somebody scans a grid for.
        shadows: [Shadow(color: Color(0x99000000), blurRadius: 3)],
      );
    }
    final status = record.stateOf(DerivativeKind.original).status;
    if (status == UploadStatus.uploaded) return const SizedBox.shrink();
    return const SizedBox(
      width: 14,
      height: 14,
      child: CustomPaint(painter: _DottedRingPainter()),
    );
  }
}

/// The square at the end of the roll that adds photos. Shaped like a tile
/// because it stands where one would: same size, same corners, and the plus
/// where the picture would be.
class AddPhotosTile extends StatelessWidget {
  const AddPhotosTile({super.key, required this.extent, required this.onTap});

  final double extent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: SizedBox.square(
      dimension: extent,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: ColoredBox(
          color: CupertinoColors.systemGrey5.darkColor,
          child: Icon(
            CupertinoIcons.add,
            size: extent * 0.32,
            color: CupertinoColors.systemGrey,
          ),
        ),
      ),
    ),
  );
}

/// Loads and caches a camera-roll asset's thumbnail bytes on demand —
/// `photoManager` records carry no `sourcePath`, only the id needed to
/// resolve one via `photo_manager`. See IMPLEMENTATION_PLAN.md T2.1.
class PhotoManagerThumbnail extends StatefulWidget {
  const PhotoManagerThumbnail({
    super.key,
    required this.assetId,
    this.fit = BoxFit.cover,
    this.size,
    this.fitted = false,
    this.placeholder,
    this.onMissing,
  });

  /// Ask for the whole photo rather than a square crop of it — see
  /// [photoManagerThumbnailBytes]. What a full-screen stand-in wants; a
  /// grid tile wants the crop.
  final bool fitted;

  /// How the thumbnail is fitted. A grid tile covers its square; the
  /// viewer, which shows this while the full-size original is still being
  /// exported, has to *contain* — the same photo drawn cover then contain
  /// visibly jumps when the real one arrives.
  final BoxFit fit;

  /// Longest edge to ask the OS for, in pixels. A grid tile is happy with
  /// the default; standing in for a full-screen photo is not, and a 200px
  /// thumbnail blown up to the screen then replaced is the blur-then-snap
  /// everybody notices.
  final int? size;

  /// The *library's* id for the asset (`PhotoLibraryService.libraryIdOf`),
  /// not this app's `localId` — for a photo that left the library and came
  /// back, they name different things.
  final String assetId;

  /// Called once when the library turns out not to have this asset at all.
  /// The grid is where a deleted photo is *noticed* — long before the next
  /// full scan — so it's the grid that says so.
  final VoidCallback? onMissing;

  /// What to draw with nothing to draw yet. A grid tile's light grey is
  /// right in a grid and wrong full-screen, where for one frame it is a
  /// white flash between the photo you tapped and the photo you opened.
  final Widget Function()? placeholder;

  @override
  State<PhotoManagerThumbnail> createState() => _PhotoManagerThumbnailState();
}

/// The OS library's own thumbnail for a `photoManager` asset, cached for
/// the session. `null` when the asset is gone from the library, or the
/// plugin isn't there (tests).
Future<Uint8List?> photoManagerThumbnailBytes(
  String assetId, {
  int? size,
  bool fitted = false,
}) async {
  // Asked for and found missing once already. Without this, every rebuild
  // of a tile whose photo is gone is two platform round trips that can
  // only fail, and a library with a screenful of them stutters on every
  // scroll.
  if (_knownMissing.contains(assetId)) return null;
  final key = _thumbnailKey(assetId, size, fitted);
  final cached = _thumbnailBytes.remove(key);
  if (cached != null) return _thumbnailBytes[key] = cached;
  try {
    final entity = await AssetEntity.fromId(assetId);
    final bytes = size == null
        ? await entity?.thumbnailData
        : await entity?.thumbnailDataWithOption(
            thumbnailOption(size, fitted: fitted),
          );
    if (bytes != null) {
      _remember(key, bytes);
      if (fitted) _rememberFitted(assetId, size!, bytes);
    }
    return bytes;
  } catch (_) {
    return null;
  }
}

/// PhotoKit's default content mode is *aspect fill*, so asking for a
/// square gets a square — a centre crop of the photo. Fine behind a grid
/// tile drawn `cover`, and wrong anywhere the whole photo is meant to be
/// visible: drawn `contain` the crop shows as a square picture that jumps
/// to the real framing the moment the original arrives. [fitted] asks for
/// aspect-fit instead, so a stand-in is the same picture, same shape.
///
/// And the size asked for is the size that comes back. PhotoKit's default
/// delivery is *opportunistic*, which calls back twice — a degraded
/// thumbnail first, the real render after — and the plugin answers on the
/// first callback and ignores the second. So every request here, at any
/// size, was quietly being served the degraded one. `highQualityFormat`
/// calls back once, with the image that was actually asked for.
String _thumbnailKey(String assetId, int? size, bool fitted) {
  if (size == null) return assetId;
  return fitted ? '$assetId@${size}f' : '$assetId@$size';
}

/// Whether the OS library has no such asset any more — the difference
/// between a thumbnail that didn't come back this time (iCloud, throttling,
/// a busy device) and a photo that was deleted over in Photos. Only the
/// second is worth acting on, and only the entity itself can tell them
/// apart.
Future<bool> photoManagerAssetMissing(String assetId) async {
  if (_knownMissing.contains(assetId)) return true;
  try {
    if (await AssetEntity.fromId(assetId) != null) return false;
    _knownMissing.add(assetId);
    return true;
  } catch (_) {
    // Couldn't ask — no plugin, no permission. Assume it's still there.
    return false;
  }
}

/// Assets the library has already said it doesn't have. Only ever grows
/// by one entry per deleted photo, and is dropped whole by
/// [clearThumbnailCaches] — which a re-scan is what would put one back.

/// What's already in memory for [assetId], preferring the size asked for
/// but taking any other over nothing: the grid has usually just drawn this
/// photo smaller, and one frame of a smaller thumbnail is invisible next to
/// the alternative, which is an empty rectangle.
/// A [fitted] caller falls back only to other fitted sizes, though — the
/// square crops in the cache are the jump it exists to avoid.
Uint8List? cachedThumbnailBytes(
  String assetId, {
  int? size,
  bool fitted = false,
}) {
  final exact = _thumbnailBytes[_thumbnailKey(assetId, size, fitted)];
  if (exact != null) return exact;
  if (fitted) return _fittedThumbnails[assetId]?.bytes;
  return _thumbnailBytes[assetId];
}

final _knownMissing = <String>{};

/// The OS's thumbnail bytes for this session, most recently used last.
///
/// Capped, and that is the whole point: unbounded, this grew by one JPEG
/// per tile ever scrolled past — hundreds of megabytes down a real
/// library, which iOS answers by squeezing the app until it stalls.
///
/// Generous, for the opposite reason: an evicted tile has to go back to
/// PhotoKit when it scrolls into view again, which is a blank square and
/// a round trip. At roughly 20 KB a tile this is ~40 MB and a hundred
/// screenfuls, so ordinary scrolling back and forth never re-fetches and
/// only a long sweep through the library drops anything.
const _thumbnailCacheEntries = 2000;
final _thumbnailBytes = <String, Uint8List>{};

void _remember(String key, Uint8List bytes) {
  _thumbnailBytes.remove(key);
  _thumbnailBytes[key] = bytes;
  while (_thumbnailBytes.length > _thumbnailCacheEntries) {
    _thumbnailBytes.remove(_thumbnailBytes.keys.first);
  }
}

/// Everything held in memory for thumbnails, dropped. Called when iOS says
/// it is short of memory — the alternative to handing some back is being
/// killed, and every one of these is re-fetchable from the library.
/// Puts bytes in the session cache as if the OS had just answered with
/// them. A widget test has no photo library to ask, and the alternative is
/// asserting on a placeholder, which every wrong answer also draws.
@visibleForTesting
void rememberThumbnailBytes(String assetId, Uint8List bytes, {int? size}) =>
    _remember(_thumbnailKey(assetId, size, false), bytes);

void clearThumbnailCaches() {
  _thumbnailBytes.clear();
  _fittedThumbnails.clear();
  _knownMissing.clear();
}

/// The largest aspect-fit thumbnail seen for an asset, whatever size asked
/// for it. The grid draws one of these per tile, which is what lets the
/// viewer put the right picture up on its first frame instead of an empty
/// rectangle while a bigger one renders.
final _fittedThumbnails = <String, ({int size, Uint8List bytes})>{};

/// A full-screen stand-in is megapixels, not kilobytes — a handful of
/// them is already more memory than every grid tile on screen. Enough to
/// cover a swipe either way through the viewer, and no more.
const _fittedCacheEntries = 12;

void _rememberFitted(String assetId, int size, Uint8List bytes) {
  final held = _fittedThumbnails.remove(assetId);
  if (held != null && held.size >= size) {
    _fittedThumbnails[assetId] = held;
    return;
  }
  _fittedThumbnails[assetId] = (size: size, bytes: bytes);
  while (_fittedThumbnails.length > _fittedCacheEntries) {
    _fittedThumbnails.remove(_fittedThumbnails.keys.first);
  }
}

class _PhotoManagerThumbnailState extends State<PhotoManagerThumbnail> {
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    // Whatever is in memory goes up on the first frame; the right size
    // arrives over it.
    _bytes = cachedThumbnailBytes(
      widget.assetId,
      size: widget.size,
      fitted: widget.fitted,
    );
    _load();
  }

  /// A *different photo in the same place*: an album cover whose newest
  /// photo just left, a person's avatar reassigned, a tile reused down the
  /// grid. The element is kept and [initState] does not run again, so
  /// without this the widget goes on drawing the photo it first loaded.
  @override
  void didUpdateWidget(PhotoManagerThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.assetId == widget.assetId &&
        oldWidget.size == widget.size &&
        oldWidget.fitted == widget.fitted) {
      return;
    }
    // Whatever is already in memory for the new one, then the right size
    // over it — the same two steps as a fresh mount. Null until it lands
    // is correct: a placeholder beats the wrong photo.
    _bytes = cachedThumbnailBytes(
      widget.assetId,
      size: widget.size,
      fitted: widget.fitted,
    );
    _load();
  }

  Future<void> _load() async {
    final bytes = await photoManagerThumbnailBytes(
      widget.assetId,
      size: widget.size,
      fitted: widget.fitted,
    );
    if (bytes == null) {
      if (await photoManagerAssetMissing(widget.assetId)) {
        widget.onMissing?.call();
      }
      return;
    }
    if (!mounted || identical(bytes, _bytes)) return;
    setState(() => _bytes = bytes);
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    if (bytes == null) {
      return widget.placeholder?.call() ??
          const ColoredBox(color: CupertinoColors.systemGrey5);
    }
    return Image.memory(
      bytes,
      fit: widget.fit,
      errorBuilder: (context, error, stackTrace) => const ColoredBox(
        color: CupertinoColors.systemGrey5,
        child: Icon(CupertinoIcons.photo),
      ),
    );
  }
}

class _DottedRingPainter extends CustomPainter {
  const _DottedRingPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xE6FFFFFF)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round;
    final rect = Rect.fromCircle(
      center: size.center(Offset.zero),
      radius: size.width / 2 - 1,
    );
    const dashCount = 8;
    const sweep = 2 * math.pi / dashCount;
    for (var i = 0; i < dashCount; i++) {
      canvas.drawArc(rect, i * sweep, sweep * 0.5, false, paint);
    }
  }

  @override
  bool shouldRepaint(_DottedRingPainter oldDelegate) => false;
}
