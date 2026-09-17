import 'dart:io';

import 'package:flutter/cupertino.dart';

import '../photos/library_metadata.dart';
import '../l10n/app_localizations.dart';
import '../photos/library_custody.dart';
import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import 'asset_grid.dart';
import 'asset_grid_view.dart';
import 'asset_picker_screen.dart';
import 'delete_confirmation.dart';
import 'detail_screen.dart';
import 'private_album_gate.dart';
import 'zoom_page_route.dart';

/// Contents of a private "album" — every [AssetRecord] currently tagged
/// with [passcodeHash]. There's no separate album entity to load: this
/// *is* the query. Reached via Utilities' "Hidden" row through
/// `private_album_gate.dart`. Header shows item count + total size; the
/// "..." menu offers adding from the full library and clearing the group
/// (every member's `passcodeHash` back to `null` — nothing is destroyed).
/// See DESIGN.md.
class PrivateAlbumScreen extends StatefulWidget {
  const PrivateAlbumScreen({
    super.key,
    required this.passcodeHash,
    required this.assetRecordStore,
    this.custody,
  });

  final String passcodeHash;
  final AssetRecordStore assetRecordStore;

  /// Overridable for tests so they never touch the real photo library.
  final LibraryCustody? custody;

  @override
  State<PrivateAlbumScreen> createState() => _PrivateAlbumScreenState();
}

class _PrivateAlbumScreenState extends State<PrivateAlbumScreen> {
  late final LibraryCustody _custody =
      widget.custody ?? LibraryCustody(store: widget.assetRecordStore);
  List<AssetRecord> _records = const [];
  int _totalBytes = 0;
  bool _selecting = false;
  Set<String> _selectedIds = {};

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final all = await widget.assetRecordStore.forPasscodeHash(
      widget.passcodeHash,
    );
    if (!mounted) return;
    final records = all.where((r) => !r.isDeleted).toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    setState(() {
      _records = records;
      // Best-effort: only sums files already resolvable on disk
      // (`manualFile` records, or `photoManager` ones already downloaded) —
      // doesn't trigger an iCloud fetch just to render a header stat.
      _totalBytes = records.fold(0, (sum, r) {
        final path = r.sourcePath;
        if (path == null) return sum;
        final file = File(path);
        return sum + (file.existsSync() ? file.lengthSync() : 0);
      });
    });
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  Future<void> _removeFromAlbum(AssetRecord record) =>
      _removeManyFromAlbum([record.localId]);

  /// Clears `passcodeHash` (back to the main library) for every id — shared
  /// by the single-tile "Remove from Private Album" action and
  /// multi-select's "Move to Library".
  ///
  /// "Back to the library" means the OS photo library too: hiding took the
  /// photo out of Photos, so taking it out of hiding puts it back. A photo
  /// the library refuses is still un-hidden here — it just stays this
  /// app's alone, which is the state it was already in.
  Future<void> _removeManyFromAlbum(Iterable<String> localIds) async {
    var failed = 0;
    for (final id in localIds) {
      final record = await widget.assetRecordStore.getByLocalId(id);
      await widget.assetRecordStore.setPasscodeHash(id, null);
      if (record == null) continue;
      if (await _custody.putBack(record) == CustodyResult.failed) failed++;
    }
    if (failed > 0 && mounted) {
      final l10n = AppLocalizations.of(context)!;
      await _showNote(l10n.privateAlbumReturnFailed(failed));
    }
    await _reload();
  }

  Future<void> _showNote(String message) => showCupertinoDialog<void>(
    context: context,
    builder: (context) => CupertinoAlertDialog(
      content: Text(message),
      actions: [
        CupertinoDialogAction(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(AppLocalizations.of(context)!.actionOk),
        ),
      ],
    ),
  );

  void _enterSelectMode() => setState(() => _selecting = true);

  void _exitSelectMode() => setState(() {
    _selecting = false;
    _selectedIds = {};
  });

  void _toggleSelected(AssetRecord record) => setState(() {
    if (!_selectedIds.remove(record.localId)) _selectedIds.add(record.localId);
  });

  Future<void> _moveSelectedToLibrary() async {
    if (_selectedIds.isEmpty) return;
    await _removeManyFromAlbum(_selectedIds);
    _exitSelectMode();
  }

  Future<bool> _delete(AssetRecord record) async {
    if (!await confirmSoftDelete(context)) return false;
    await widget.assetRecordStore.softDelete(record.localId);
    await _reload();
    return true;
  }

  Future<void> _addFromLibrary() async {
    final l10n = AppLocalizations.of(context)!;
    final picked = await Navigator.of(context).push<List<AssetRecord>>(
      CupertinoPageRoute(
        builder: (_) => AssetPickerScreen(
          title: l10n.privateAlbumPickerMoveTitle,
          assetRecordStore: widget.assetRecordStore,
          excludeIds: _records.map((r) => r.localId).toSet(),
        ),
      ),
    );
    if (picked == null || picked.isEmpty || !mounted) return;
    // The same hide the grid's own action performs — including taking the
    // photos out of Photos. Adding from in here used to only set the hash,
    // so the photos vanished from this app and stayed in the camera roll.
    // The album is already open, so its passcode isn't asked for again.
    await hideIntoPrivateAlbum(
      context,
      assetRecordStore: widget.assetRecordStore,
      records: picked,
      passcodeHash: widget.passcodeHash,
      custody: _custody,
    );
    await _reload();
  }

  Future<void> _confirmDeleteAlbum() async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showCupertinoDialog<bool>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: Text(l10n.privateAlbumDeleteConfirmTitle),
        content: Text(l10n.privateAlbumDeleteConfirmBody),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.actionCancel),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.actionDelete),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    // Through the same path a single "Move to Library" takes, so every
    // photo goes back to Photos rather than only losing its passcode.
    await _removeManyFromAlbum(_records.map((r) => r.localId).toList());
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _toggleFavorite(AssetRecord record) async {
    await setFavoriteEverywhere(
      widget.assetRecordStore,
      record,
      !record.isFavorite,
    );
    await _reload();
  }

  void _open(AssetRecord record) {
    if (_selecting) {
      _toggleSelected(record);
      return;
    }
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
      navigationBar: CupertinoNavigationBar(
        middle: Text(l10n.privateAlbumScreenTitle),
        leading: _selecting
            ? CupertinoButton(
                padding: EdgeInsets.zero,
                onPressed: _exitSelectMode,
                child: Text(l10n.actionCancel),
              )
            : null,
        // The two things this page does, on the page, rather than behind a
        // "…" — there were only ever two of them, and a menu holding two
        // items is a tap spent on finding out what they are.
        trailing: _selecting
            ? null
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CupertinoButton(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    minimumSize: Size.zero,
                    onPressed: _addFromLibrary,
                    child: Text(
                      l10n.privateAlbumMoveFromLibrary,
                      style: const TextStyle(fontSize: 15),
                    ),
                  ),
                  if (_records.isNotEmpty) ...[
                    CupertinoButton(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      minimumSize: Size.zero,
                      onPressed: _enterSelectMode,
                      child: Text(
                        l10n.privateAlbumSelectButton,
                        style: const TextStyle(fontSize: 15),
                      ),
                    ),
                    CupertinoButton(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      minimumSize: Size.zero,
                      onPressed: _confirmDeleteAlbum,
                      child: Text(
                        l10n.privateAlbumDeleteAlbum,
                        style: const TextStyle(
                          fontSize: 15,
                          color: CupertinoColors.systemRed,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
      ),
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '${l10n.privateAlbumItemCount(_records.length)} · ${_formatSize(_totalBytes)}',
                  style: const TextStyle(color: CupertinoColors.systemGrey),
                ),
              ),
            ),
            Expanded(
              child: _records.isEmpty
                  ? Center(
                      child: Text(
                        l10n.privateAlbumEmpty,
                        style: const TextStyle(
                          color: CupertinoColors.systemGrey,
                        ),
                      ),
                    )
                  : AssetGridView(
                      records: _records,
                      onTap: _open,
                      selectedIds: _selecting ? _selectedIds : null,
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
                          icon: CupertinoIcons.eye,
                          label: l10n.privateAlbumRemove,
                          onPressed: () => _removeFromAlbum(r),
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
            if (_selecting)
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  child: CupertinoButton.filled(
                    onPressed: _selectedIds.isEmpty
                        ? null
                        : _moveSelectedToLibrary,
                    child: Text(
                      l10n.privateAlbumMoveSelectedToLibrary(
                        _selectedIds.length,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
