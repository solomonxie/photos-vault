import 'package:flutter/cupertino.dart';

import '../l10n/app_localizations.dart';
import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import 'asset_grid.dart';
import 'delete_confirmation.dart';
import 'detail_screen.dart';

class HiddenScreen extends StatefulWidget {
  const HiddenScreen({super.key, required this.assetRecordStore});

  final AssetRecordStore assetRecordStore;

  @override
  State<HiddenScreen> createState() => _HiddenScreenState();
}

class _HiddenScreenState extends State<HiddenScreen> {
  List<AssetRecord> _records = const [];

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final all = await widget.assetRecordStore.listAll();
    if (!mounted) return;
    setState(
      () => _records = all.where((r) => r.isHidden && !r.isDeleted).toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt)),
    );
  }

  Future<void> _unhide(AssetRecord record) async {
    await widget.assetRecordStore.setHidden(record.localId, false);
    await _reload();
  }

  Future<bool> _delete(AssetRecord record) async {
    if (!await confirmSoftDelete(context)) return false;
    await widget.assetRecordStore.softDelete(record.localId);
    await _reload();
    return true;
  }

  Future<void> _toggleFavorite(AssetRecord record) async {
    await widget.assetRecordStore.setFavorite(record.localId, !record.isFavorite);
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
      navigationBar: CupertinoNavigationBar(middle: Text(l10n.collectionsHiddenRow)),
      child: SafeArea(
        child: _records.isEmpty
            ? Center(child: Text(l10n.libraryHiddenEmpty, style: const TextStyle(color: CupertinoColors.systemGrey)))
            : CustomScrollView(
                slivers: assetGridSlivers(
                  context: context,
                  records: _records,
                  onTap: _open,
                  actionsFor: (r) => [
                    TileAction(icon: CupertinoIcons.eye, label: l10n.libraryUnhide, onPressed: () => _unhide(r)),
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
