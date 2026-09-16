import 'dart:io';

import 'package:flutter/cupertino.dart';

import '../l10n/app_localizations.dart';
import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import 'asset_grid.dart';

/// Multi-select grid over the active library (not deleted, not hidden) —
/// pops with the selected records, or `null` on cancel. Shared by Private
/// Albums' "Move/Copy from Library" (T6.4) and People's "Add Photos" (T7.3);
/// each caller decides what selecting means (move, copy, tag to a person).
class AssetPickerScreen extends StatefulWidget {
  const AssetPickerScreen({
    super.key,
    required this.title,
    required this.assetRecordStore,
    this.excludeIds = const {},
  });

  final String title;
  final AssetRecordStore assetRecordStore;

  /// Already-included ids — left out of the picker entirely (e.g. already in
  /// this private album / already tagged to this person).
  final Set<String> excludeIds;

  @override
  State<AssetPickerScreen> createState() => _AssetPickerScreenState();
}

class _AssetPickerScreenState extends State<AssetPickerScreen> {
  List<AssetRecord> _records = const [];
  final Set<String> _selected = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final all = await widget.assetRecordStore.listAll();
    if (!mounted) return;
    setState(
      () => _records =
          all
              .where(
                (r) =>
                    !r.isDeleted &&
                    !r.isHidden &&
                    r.passcodeHash == null &&
                    !widget.excludeIds.contains(r.localId),
              )
              .toList()
            ..sort((a, b) => a.createdAt.compareTo(b.createdAt)),
    );
  }

  void _toggle(AssetRecord record) {
    setState(() {
      if (!_selected.add(record.localId)) _selected.remove(record.localId);
    });
  }

  void _confirm() {
    final chosen = _records
        .where((r) => _selected.contains(r.localId))
        .toList();
    Navigator.of(context).pop(chosen);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(widget.title),
        trailing: _selected.isEmpty
            ? null
            : CupertinoButton(
                padding: EdgeInsets.zero,
                onPressed: _confirm,
                child: Text(l10n.privateAlbumPickerAddButton(_selected.length)),
              ),
      ),
      child: SafeArea(
        child: _records.isEmpty
            ? Center(
                child: Text(
                  l10n.privateAlbumPickerEmpty,
                  style: const TextStyle(color: CupertinoColors.systemGrey),
                ),
              )
            : CustomScrollView(
                slivers: _pickerSlivers(
                  context: context,
                  records: _records,
                  selected: _selected,
                  onToggle: _toggle,
                ),
              ),
      ),
    );
  }
}

List<Widget> _pickerSlivers({
  required BuildContext context,
  required List<AssetRecord> records,
  required Set<String> selected,
  required void Function(AssetRecord) onToggle,
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
        padding: const EdgeInsets.symmetric(horizontal: 2),
        sliver: SliverGrid(
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 4,
            crossAxisSpacing: 2,
            mainAxisSpacing: 2,
          ),
          delegate: SliverChildBuilderDelegate(
            (context, i) => _PickerTile(
              key: ValueKey(entry.value[i].localId),
              record: entry.value[i],
              selected: selected.contains(entry.value[i].localId),
              onTap: () => onToggle(entry.value[i]),
            ),
            childCount: entry.value.length,
          ),
        ),
      ),
    ],
  ];
}

class _PickerTile extends StatelessWidget {
  const _PickerTile({
    super.key,
    required this.record,
    required this.selected,
    required this.onTap,
  });

  final AssetRecord record;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final path = record.sourcePath;
    return GestureDetector(
      onTap: onTap,
      child: AspectRatio(
        aspectRatio: 1,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (record.isVideo)
              const ColoredBox(
                color: CupertinoColors.darkBackgroundGray,
                child: Icon(
                  CupertinoIcons.play_circle_fill,
                  color: CupertinoColors.white,
                  size: 28,
                ),
              )
            else if (path != null)
              Image.file(
                File(path),
                fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) => const ColoredBox(
                  color: CupertinoColors.systemGrey5,
                  child: Icon(CupertinoIcons.photo),
                ),
              )
            else if (record.sourceType == AssetSourceType.photoManager)
              PhotoManagerThumbnail(assetId: record.localId)
            else
              const ColoredBox(
                color: CupertinoColors.systemGrey5,
                child: Icon(CupertinoIcons.photo),
              ),
            if (selected) const ColoredBox(color: Color(0x662E7DFF)),
            Positioned(
              top: 4,
              right: 4,
              child: Icon(
                selected
                    ? CupertinoIcons.checkmark_circle_fill
                    : CupertinoIcons.circle,
                color: selected
                    ? CupertinoColors.activeBlue
                    : CupertinoColors.white,
                size: 20,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
