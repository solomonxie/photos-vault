import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:intl/intl.dart';
import 'package:photo_manager/photo_manager.dart';

import '../l10n/app_localizations.dart';
import '../photos/photo_library_service.dart';
import '../storage/asset_record.dart';

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

/// Builds the day-grouped, newest-first square grid as a list of slivers —
/// embed directly in any `CustomScrollView`. Shared by the main Library
/// page and the Favorites/Hidden/Recently Deleted screens.
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
}) {
  final l10n = AppLocalizations.of(context)!;
  final grouped = <String, List<AssetRecord>>{};
  for (final r in records) {
    grouped.putIfAbsent(dayLabel(l10n, r.createdAt), () => []).add(r);
  }

  return [
    for (final entry in grouped.entries) ...[
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(
            entry.key,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 20),
          ),
        ),
      ),
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
        sliver: SliverGrid(
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            crossAxisSpacing: 8,
            mainAxisSpacing: 8,
          ),
          delegate: SliverChildBuilderDelegate(
            (context, i) => AssetTile(
              key: ValueKey(entry.value[i].localId),
              record: entry.value[i],
              onTap: () => onTap(entry.value[i]),
              onLongPress: onLongPress == null
                  ? null
                  : () => onLongPress(entry.value[i]),
              actions: actionsFor(entry.value[i]),
              selected: selectedIds?.contains(entry.value[i].localId),
            ),
            childCount: entry.value.length,
          ),
        ),
      ),
    ],
  ];
}

class AssetTile extends StatelessWidget {
  const AssetTile({
    super.key,
    required this.record,
    required this.onTap,
    required this.actions,
    this.selected,
    this.onLongPress,
  });

  final AssetRecord record;
  final VoidCallback onTap;
  final List<TileAction> actions;

  /// Given, replaces the long-press context menu (see `assetGridSlivers`).
  final VoidCallback? onLongPress;

  /// `null` outside multi-select mode; `true`/`false` while selecting (see
  /// `assetGridSlivers`' `selectedIds`).
  final bool? selected;

  /// The live local original first, then the OS library, and only then the
  /// app's own cached thumbnail — the cache is the *fallback*, for when
  /// there's no original left (cloud-only) or the live source can't be
  /// read. Preferring it would mean a stale cached path (they're absolute,
  /// and the app container's UUID changes on reinstall) blanking a tile
  /// whose real photo is right there.
  Widget _image() {
    if (record.localDeleted) return _cachedThumbnail();
    final path = record.sourcePath;
    if (path != null) {
      return Image.file(
        File(path),
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) => _cachedThumbnail(),
      );
    }
    if (record.sourceType == AssetSourceType.photoManager) {
      return PhotoManagerThumbnail(assetId: record.localId);
    }
    return _cachedThumbnail();
  }

  Widget _cachedThumbnail() {
    final thumbnail = record.thumbnailPath;
    if (thumbnail == null) return _placeholder();
    return Image.file(
      File(thumbnail),
      fit: BoxFit.cover,
      errorBuilder: (context, error, stackTrace) => _placeholder(),
    );
  }

  Widget _placeholder() => const ColoredBox(
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

    return AspectRatio(
      aspectRatio: 1,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (video)
              const ColoredBox(
                color: CupertinoColors.darkBackgroundGray,
                child: Icon(
                  CupertinoIcons.play_circle_fill,
                  color: CupertinoColors.white,
                  size: 28,
                ),
              )
            else
              _image(),
            if (record.localDeleted)
              const Positioned(
                top: 4,
                left: 4,
                child: Icon(
                  CupertinoIcons.cloud_fill,
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

  final String assetId;

  @override
  State<PhotoManagerThumbnail> createState() => _PhotoManagerThumbnailState();
}

class _PhotoManagerThumbnailState extends State<PhotoManagerThumbnail> {
  static final _cache = <String, Uint8List>{};

  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final cached = _cache[widget.assetId];
    if (cached != null) {
      setState(() => _bytes = cached);
      return;
    }
    final id = PhotoLibraryService.entityIdFrom(widget.assetId);
    if (id == null) return;
    try {
      final entity = await AssetEntity.fromId(id);
      final bytes = await entity?.thumbnailData;
      if (bytes == null || !mounted) return;
      _cache[widget.assetId] = bytes;
      setState(() => _bytes = bytes);
    } catch (_) {
      // Asset removed from the library since, or plugin unavailable in
      // tests — falls through to the placeholder below.
    }
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
