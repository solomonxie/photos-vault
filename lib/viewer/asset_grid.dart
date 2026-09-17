import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:intl/intl.dart';
import 'package:photo_manager/photo_manager.dart';

import '../l10n/app_localizations.dart';
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
}) => AssetTile(
  key: ValueKey(record.localId),
  record: record,
  extent: extent,
  onTap: () => onTap(record),
  onLongPress: onLongPress == null ? null : () => onLongPress(record),
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
}) {
  Widget cached() {
    final thumbnail = record.thumbnailPath;
    if (thumbnail == null) return placeholder();
    return Image.file(
      File(thumbnail),
      fit: BoxFit.cover,
      errorBuilder: (context, error, stackTrace) => placeholder(),
    );
  }

  if (record.localDeleted) return cached();
  final path = record.sourcePath;
  if (path != null) {
    return Image.file(
      File(path),
      fit: BoxFit.cover,
      errorBuilder: (context, error, stackTrace) => cached(),
    );
  }
  final libraryId = PhotoLibraryService.libraryIdOf(record);
  if (record.sourceType == AssetSourceType.photoManager && libraryId != null) {
    return PhotoManagerThumbnail(assetId: libraryId);
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
    this.onLongPress,
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
          color: CupertinoColors.systemGrey5,
          child: Icon(CupertinoIcons.photo),
        );

  @override
  Widget build(BuildContext context) {
    final tile = GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: _tile(),
    );
    if (onLongPress != null) return tile;
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
            assetImage(record, placeholder: _placeholder),
            if (record.localDeleted)
              const Positioned(
                top: 4,
                left: 4,
                child: Icon(
                  CupertinoIcons.cloud_fill,
                  size: 14,
                  color: CupertinoColors.white,
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

/// Marks only not-yet-backed-up tiles — a light dotted ring, bottom-right —
/// synced tiles get no badge at all, so a fully backed-up library reads as
/// clean instead of every tile carrying a green checkmark.
class StatusDot extends StatelessWidget {
  const StatusDot({super.key, required this.record});

  final AssetRecord record;

  @override
  Widget build(BuildContext context) {
    final status = record.stateOf(DerivativeKind.original).status;
    if (status == UploadStatus.uploaded) return const SizedBox.shrink();
    return const SizedBox(
      width: 14,
      height: 14,
      child: CustomPaint(painter: _DottedRingPainter()),
    );
  }
}

/// Loads and caches a camera-roll asset's thumbnail bytes on demand —
/// `photoManager` records carry no `sourcePath`, only the id needed to
/// resolve one via `photo_manager`. See IMPLEMENTATION_PLAN.md T2.1.
class PhotoManagerThumbnail extends StatefulWidget {
  const PhotoManagerThumbnail({super.key, required this.assetId});

  /// The *library's* id for the asset (`PhotoLibraryService.libraryIdOf`),
  /// not this app's `localId` — for a photo that left the library and came
  /// back, they name different things.
  final String assetId;

  @override
  State<PhotoManagerThumbnail> createState() => _PhotoManagerThumbnailState();
}

/// The OS library's own thumbnail for a `photoManager` asset, cached for
/// the session. `null` when the asset is gone from the library, or the
/// plugin isn't there (tests).
Future<Uint8List?> photoManagerThumbnailBytes(String assetId) async {
  final cached = _thumbnailBytes[assetId];
  if (cached != null) return cached;
  try {
    final entity = await AssetEntity.fromId(assetId);
    final bytes = await entity?.thumbnailData;
    if (bytes != null) _thumbnailBytes[assetId] = bytes;
    return bytes;
  } catch (_) {
    return null;
  }
}

final _thumbnailBytes = <String, Uint8List>{};

class _PhotoManagerThumbnailState extends State<PhotoManagerThumbnail> {
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final bytes = await photoManagerThumbnailBytes(widget.assetId);
    if (bytes == null || !mounted) return;
    setState(() => _bytes = bytes);
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    if (bytes == null) {
      return const ColoredBox(color: CupertinoColors.systemGrey5);
    }
    return Image.memory(
      bytes,
      fit: BoxFit.cover,
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
