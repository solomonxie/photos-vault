import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../storage/asset_record.dart';
import 'detail_screen.dart';

/// One long-press context-menu action offered on a grid tile (e.g.
/// Favorite/Unfavorite, Hide, Delete, Recover) — each screen that shows a
/// grid (Library, Favorites, Hidden, Recently Deleted) supplies its own set.
class TileAction {
  const TileAction({required this.icon, required this.label, required this.onPressed, this.isDestructive = false});

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
          child: Text(entry.key, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 20)),
        ),
      ),
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        sliver: SliverGrid(
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 4,
            crossAxisSpacing: 2,
            mainAxisSpacing: 2,
          ),
          delegate: SliverChildBuilderDelegate(
            (context, i) => AssetTile(
              key: ValueKey(entry.value[i].localId),
              record: entry.value[i],
              onTap: () => onTap(entry.value[i]),
              actions: actionsFor(entry.value[i]),
            ),
            childCount: entry.value.length,
          ),
        ),
      ),
    ],
  ];
}

class AssetTile extends StatelessWidget {
  const AssetTile({super.key, required this.record, required this.onTap, required this.actions});

  final AssetRecord record;
  final VoidCallback onTap;
  final List<TileAction> actions;

  @override
  Widget build(BuildContext context) {
    final path = record.sourcePath;
    final video = path != null && isVideoPath(path);

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
      child: GestureDetector(
        onTap: onTap,
        child: AspectRatio(
          aspectRatio: 1,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (video)
                const ColoredBox(
                  color: CupertinoColors.darkBackgroundGray,
                  child: Icon(CupertinoIcons.play_circle_fill, color: CupertinoColors.white, size: 28),
                )
              else if (path != null)
                Image.file(
                  File(path),
                  fit: BoxFit.cover,
                  errorBuilder: (context, error, stackTrace) =>
                      const ColoredBox(color: CupertinoColors.systemGrey5, child: Icon(CupertinoIcons.photo)),
                )
              else
                const ColoredBox(color: CupertinoColors.systemGrey5, child: Icon(CupertinoIcons.photo)),
              if (video)
                const Positioned(
                  top: 4,
                  right: 4,
                  child: Icon(CupertinoIcons.video_camera_solid, size: 14, color: CupertinoColors.white),
                ),
              if (record.isFavorite)
                const Positioned(
                  bottom: 4,
                  left: 4,
                  child: Icon(CupertinoIcons.heart_fill, size: 14, color: CupertinoColors.white),
                ),
              Positioned(bottom: 4, right: 4, child: StatusDot(record: record)),
            ],
          ),
        ),
      ),
    );
  }
}

class StatusDot extends StatelessWidget {
  const StatusDot({super.key, required this.record});

  final AssetRecord record;

  @override
  Widget build(BuildContext context) {
    final status = record.stateOf(DerivativeKind.original).status;
    final (icon, color) = switch (status) {
      UploadStatus.pending => (CupertinoIcons.clock, CupertinoColors.systemGrey),
      UploadStatus.uploading => (CupertinoIcons.cloud_upload, CupertinoColors.systemBlue),
      UploadStatus.uploaded => (CupertinoIcons.checkmark_circle_fill, CupertinoColors.systemGreen),
      UploadStatus.failed => (CupertinoIcons.exclamationmark_circle_fill, CupertinoColors.systemRed),
    };
    return Icon(icon, size: 14, color: color);
  }
}
