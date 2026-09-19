import 'package:flutter/cupertino.dart';

import '../photos/library_metadata.dart';
import '../l10n/app_localizations.dart';
import '../photos/asset_removal.dart';
import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import 'asset_grid.dart';
import 'asset_grid_view.dart';
import 'delete_confirmation.dart';
import 'detail_screen.dart';
import 'private_album_gate.dart';
import 'zoom_page_route.dart';

/// Grid screen for a fixed list of records — used to drill into one
/// People/Events group from [SmartCollectionScreen].
class AssetGroupScreen extends StatefulWidget {
  const AssetGroupScreen({
    super.key,
    required this.title,
    required this.records,
    required this.assetRecordStore,
  });

  final String title;
  final List<AssetRecord> records;
  final AssetRecordStore assetRecordStore;

  @override
  State<AssetGroupScreen> createState() => _AssetGroupScreenState();
}

class _AssetGroupScreenState extends State<AssetGroupScreen> {
  late List<AssetRecord> _records = widget.records;

  Future<void> _toggleFavorite(AssetRecord record) async {
    final value = !record.isFavorite;
    await setFavoriteEverywhere(widget.assetRecordStore, record, value);
    setState(
      () => _records = [
        for (final r in _records)
          r.localId == record.localId ? r.withFavorite(value) : r,
      ],
    );
  }

  Future<void> _hide(AssetRecord record) async {
    final hidden = await hideIntoPrivateAlbum(
      context,
      assetRecordStore: widget.assetRecordStore,
      records: [record],
    );
    if (!hidden) return;
    setState(
      () => _records = _records
          .where((r) => r.localId != record.localId)
          .toList(),
    );
  }

  /// Deleting is the same decision on every screen: keep the cloud copy
  /// and free the space, or bin it. See `../photos/asset_removal.dart`.
  late final AssetRemoval _removal = AssetRemoval(
    store: widget.assetRecordStore,
  );

  Future<bool> _delete(AssetRecord record) async {
    final outcome = await deleteAsset(
      context,
      record: record,
      removal: _removal,
    );
    if (!outcome.leftTheList || !mounted) return false;
    setState(
      () => _records = _records
          .where((r) => r.localId != record.localId)
          .toList(),
    );
    return true;
  }

  void _open(AssetRecord record) {
    Navigator.of(context).push(
      ZoomPageRoute(
        builder: (_) => DetailScreen(
          records: _records,
          initialIndex: _records.indexOf(record),
          assetRecordStore: widget.assetRecordStore,
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
        child: AssetGridView(
          records: _records,
          onTap: _open,
          actionsFor: (r) => [
            TileAction(
              icon: r.isFavorite
                  ? CupertinoIcons.heart_slash
                  : CupertinoIcons.heart,
              label: r.isFavorite
                  ? l10n.libraryUnfavorite
                  : l10n.libraryFavorite,
              onPressed: () => _toggleFavorite(r),
            ),
            TileAction(
              icon: CupertinoIcons.eye_slash,
              label: l10n.libraryHide,
              onPressed: () => _hide(r),
            ),
            TileAction(
              icon: CupertinoIcons.delete,
              label: l10n.libraryDeleteTooltip,
              isDestructive: true,
              onPressed: () => _delete(r),
            ),
          ],
        ),
      ),
    );
  }
}
