import 'package:flutter/cupertino.dart';

import '../l10n/app_localizations.dart';
import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import 'asset_grid.dart';
import 'detail_screen.dart';

/// Media Types' "Photos" and "Videos" rows — same active-library set as the
/// main grid, filtered to one kind. Shares the Favorite/Hide/Delete actions
/// with [LibraryScreenState] rather than introducing a fourth variant.
class MediaTypeScreen extends StatefulWidget {
  const MediaTypeScreen({super.key, required this.assetRecordStore, required this.isVideo, required this.title});

  final AssetRecordStore assetRecordStore;
  final bool isVideo;
  final String title;

  @override
  State<MediaTypeScreen> createState() => _MediaTypeScreenState();
}

class _MediaTypeScreenState extends State<MediaTypeScreen> {
  List<AssetRecord> _records = const [];

  @override
  void initState() {
    super.initState();
    _reload();
  }

  bool _matches(AssetRecord r) {
    final path = r.sourcePath;
    final isVideo = path != null && isVideoPath(path);
    return isVideo == widget.isVideo;
  }

  Future<void> _reload() async {
    final all = await widget.assetRecordStore.listAll();
    if (!mounted) return;
    setState(
      () => _records = all.where((r) => !r.isDeleted && !r.isHidden && _matches(r)).toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt)),
    );
  }

  Future<void> _toggleFavorite(AssetRecord record) async {
    await widget.assetRecordStore.setFavorite(record.localId, !record.isFavorite);
    await _reload();
  }

  Future<void> _hide(AssetRecord record) async {
    await widget.assetRecordStore.setHidden(record.localId, true);
    await _reload();
  }

  Future<void> _delete(AssetRecord record) async {
    await widget.assetRecordStore.softDelete(record.localId);
    await _reload();
  }

  void _open(AssetRecord record) {
    Navigator.of(context).push(
      CupertinoPageRoute(
        builder: (_) => DetailScreen(
          records: _records,
          initialIndex: _records.indexOf(record),
          onDelete: _delete,
          onToggleFavorite: _toggleFavorite,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(middle: Text(widget.title)),
      child: SafeArea(
        child: CustomScrollView(
          slivers: assetGridSlivers(
            context: context,
            records: _records,
            onTap: _open,
            actionsFor: (r) => [
              TileAction(
                icon: r.isFavorite ? CupertinoIcons.heart_slash : CupertinoIcons.heart,
                label: r.isFavorite ? l10n.libraryUnfavorite : l10n.libraryFavorite,
                onPressed: () => _toggleFavorite(r),
              ),
              TileAction(icon: CupertinoIcons.eye_slash, label: l10n.libraryHide, onPressed: () => _hide(r)),
              TileAction(
                icon: CupertinoIcons.delete,
                label: l10n.libraryDeleteTooltip,
                isDestructive: true,
                onPressed: () => _delete(r),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
