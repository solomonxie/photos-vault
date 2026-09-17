import 'package:flutter/cupertino.dart';

import '../l10n/app_localizations.dart';
import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import 'asset_grid_view.dart';

/// Multi-select grid over the active library (not deleted, not hidden) —
/// pops with the selected records, or `null` on cancel. Shared by Private
/// Albums' "Move/Copy from Library" (T6.4), People's "Add Photos" (T7.3)
/// and an album's own; each caller decides what selecting means.
///
/// Built on the same [AssetGridView] as the library itself, rather than a
/// grid of its own. It had one, and picking a photo from last year meant
/// flicking past a decade: no date scrubber down the right edge, no opening
/// at the newest photo, no tap-the-header to get back to it. A picker is
/// where somebody is *looking* for a photo, which is exactly when those
/// matter.
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
  static const _navigationBarHeight = 44.0;

  final _gridKey = GlobalKey<AssetGridViewState>();
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

  /// Same as the library's: back to the newest photo, and from there on to
  /// the very top.
  void _jumpHome() => _gridKey.currentState?.toggleAnchor();

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
      child: Stack(
        children: [
          SafeArea(
            child: _records.isEmpty
                ? Center(
                    child: Text(
                      l10n.privateAlbumPickerEmpty,
                      style: const TextStyle(color: CupertinoColors.systemGrey),
                    ),
                  )
                : AssetGridView(
                    key: _gridKey,
                    records: _records,
                    // Every tile is a checkbox here — there's no viewer to
                    // open, so a tap and a hold mean the same thing.
                    onTap: _toggle,
                    onLongPress: _toggle,
                    selectedIds: _selected,
                    actionsFor: (r) => const [],
                  ),
          ),
          // Tapping the header goes back to the newest photo, as on the
          // library page. The status-bar strip above it can't be covered —
          // iOS delivers that tap on a channel, not to the view.
          Positioned(
            top: MediaQuery.paddingOf(context).top,
            left: 0,
            right: 96,
            height: _navigationBarHeight,
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: _jumpHome,
            ),
          ),
        ],
      ),
    );
  }
}
