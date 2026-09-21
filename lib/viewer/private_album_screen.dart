import 'dart:io';

import 'package:flutter/cupertino.dart';

import '../photos/library_metadata.dart';
import '../l10n/app_localizations.dart';
import '../photos/library_custody.dart';
import '../photos/asset_removal.dart';
import '../storage/asset_record.dart';
import '../settings/backup_targets_store.dart';
import '../storage/asset_record_store.dart';
import '../vault/album_index.dart';
import '../vault/bucket.dart';
import '../vault/cache.dart';
import '../vault/gallery.dart';
import '../vault/passphrase_sheet.dart';
import '../vault/private_lifecycle.dart';
import '../vault/keys.dart';
import '../vault/photo_screen.dart';
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
    this.albumKeys,
    this.vaultKeys,
  });

  final String passcodeHash;
  final AssetRecordStore assetRecordStore;

  /// Overridable for tests so they never touch the real photo library.
  final LibraryCustody? custody;

  /// This album's key, derived when the gate took the code. Absent only
  /// where nothing has been set up yet, which is also where nothing can
  /// have been uploaded.
  final AlbumKeys? albumKeys;
  final VaultKeys? vaultKeys;

  @override
  State<PrivateAlbumScreen> createState() => _PrivateAlbumScreenState();
}

class _PrivateAlbumScreenState extends State<PrivateAlbumScreen>
    with WidgetsBindingObserver, PrivateScreenLifecycle {
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
    _loadFromBucket();
    _loadTarget();
  }

  @override
  void dispose() {
    _gallery?.dispose();
    super.dispose();
  }

  /// The album as the bucket knows it. This is the whole album once the
  /// uploads have landed — a hidden photo's record is deleted the moment
  /// its carrier is confirmed, so the phone stops knowing anything about
  /// it. Local records only exist in the window between hiding and the
  /// upload.
  Future<void> _loadFromBucket() async {
    final keys = widget.albumKeys;
    if (keys == null) return;
    final gallery = VaultGallery(keys: keys);
    final entries = await gallery.list();
    if (!mounted) {
      gallery.dispose();
      return;
    }
    final known = await widget.vaultKeys?.entries() ?? const [];
    if (!mounted) {
      gallery.dispose();
      return;
    }
    setState(() {
      _gallery = gallery;
      _cloudEntries = entries;
      _passphrases = known;
    });
  }

  /// Whether there is anywhere for these photos to go. The one thing the
  /// footer still has to answer, now that backup is not a choice.
  bool _hasTarget = false;

  /// The long explanation is collapsed to its first few lines. Three
  /// bullets is enough to tell somebody whether they want the rest; ten of
  /// them unasked-for is a wall nobody reads, on the screen where the
  /// photos are.
  bool _howExpanded = false;
  static const _howCollapsedLines = 3;

  VaultGallery? _gallery;
  List<IndexEntry> _cloudEntries = const [];
  List<PassphraseEntry> _passphrases = const [];

  /// Its own load, deliberately not part of [_reload]: this reaches secure
  /// storage, and a photo grid must not wait on — or be emptied by — a
  /// question about buckets.
  Future<void> _loadTarget() async {
    try {
      final has = (await BackupTargetsStore().loadAll()).isNotEmpty;
      if (mounted) setState(() => _hasTarget = has);
    } catch (_) {
      // No secure storage (tests, a locked keychain) — the footer just
      // reads as "no bucket", which is the safer thing to say.
    }
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
    await _reload();
    return outcome.leftTheList;
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

  /// Everything that is only in the bucket. Its own grid rather than mixed
  /// into the local one: these have no record on this phone to mix with.
  Widget _cloudSliver(AppLocalizations l10n) {
    final gallery = _gallery;
    if (gallery == null || _cloudEntries.isEmpty) {
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 1),
      sliver: SliverGrid(
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 4,
          mainAxisSpacing: 2,
          crossAxisSpacing: 2,
        ),
        delegate: SliverChildBuilderDelegate((context, index) {
          final entry = _cloudEntries[index];
          return VaultTile(
            gallery: gallery,
            entry: entry,
            onTap: () => _openCloud(entry),
          );
        }, childCount: _cloudEntries.length),
      ),
    );
  }

  Future<void> _openCloud(IndexEntry entry) async {
    final gallery = _gallery;
    if (gallery == null) return;
    await Navigator.of(context).push(
      CupertinoPageRoute<void>(
        builder: (_) => VaultPhotoScreen(gallery: gallery, entry: entry),
      ),
    );
  }

  /// This album's own settings, in one place. The backup switch lives here
  /// rather than in the footer now: it is the album's setting, not a
  /// caption on the copy that explains it, and the copy below still says
  /// which way it sits.
  Future<void> _showAlbumMenu() async {
    final l10n = AppLocalizations.of(context)!;
    final keys = widget.vaultKeys;
    await showCupertinoModalPopup<void>(
      context: context,
      builder: (sheetContext) => CupertinoActionSheet(
        // Which passphrases this phone can still derive, and their hints.
        // A line of context rather than a section of the page: it is only
        // ever read when deciding whether to add another one.
        message: _passphrases.isEmpty
            ? null
            : Text(
                [
                  for (final entry in _passphrases)
                    '${entry.id == widget.albumKeys?.entry.id ? l10n.vaultPassphraseInUse : l10n.vaultPassphraseAdded}'
                        ' · '
                        '${entry.hint.isEmpty ? l10n.vaultPassphraseNoHint : l10n.vaultPassphraseHint(entry.hint)}',
                ].join('\n'),
                style: const TextStyle(fontSize: 13),
              ),
        actions: [
          if (keys != null) ...[
            CupertinoActionSheetAction(
              onPressed: () {
                Navigator.of(sheetContext).pop();
                _addPassphrase();
              },
              child: Text(l10n.vaultAddPassphraseTitle),
            ),
            CupertinoActionSheetAction(
              isDestructiveAction: true,
              onPressed: () {
                Navigator.of(sheetContext).pop();
                _forgetOnThisPhone();
              },
              child: Text(l10n.vaultForgetOnThisPhone),
            ),
          ],
          if (_records.isNotEmpty)
            CupertinoActionSheetAction(
              isDestructiveAction: true,
              onPressed: () {
                Navigator.of(sheetContext).pop();
                _confirmDeleteAlbum();
              },
              child: Text(l10n.privateAlbumDeleteAlbum),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(sheetContext).pop(),
          child: Text(l10n.actionCancel),
        ),
      ),
    );
  }

  Future<void> _addPassphrase() async {
    final keys = widget.vaultKeys;
    if (keys == null) return;
    // Candidates come from the bucket's own index: a phone restored from
    // nothing has no entries of its own, and the hint has to reach it
    // somehow.
    final known = await keys.entries();
    final fromBucket = widget.albumKeys == null
        ? const <PassphraseEntry>[]
        : (await VaultBucket().readAlbum(widget.albumKeys!)).passphrases;
    final candidates = {
      for (final e in [...known, ...fromBucket]) e.id: e,
    }.values.toList();
    if (!mounted) return;
    final added = await showAddPassphraseSheet(
      context,
      keys: keys,
      candidates: candidates,
    );
    if (added && mounted) await _loadFromBucket();
  }

  Future<void> _forgetOnThisPhone() async {
    await widget.vaultKeys?.forgetOnThisDevice();
    await VaultCache().clear();
    if (mounted) Navigator.of(context).pop();
  }

  /// Where the photos end, because that is where you are when you want
  /// another one — the same reasoning as the library's own "+" (see
  /// `docs/design/uiux/collections.md`).
  Widget _addSliver(AppLocalizations l10n) => SliverToBoxAdapter(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 0),
      child: SizedBox(
        width: double.infinity,
        child: CupertinoButton(
          color: const Color(0xFF2C2C2E),
          padding: const EdgeInsets.symmetric(vertical: 12),
          onPressed: _addFromLibrary,
          child: Text(
            l10n.privateAlbumMoveFromLibrary,
            style: const TextStyle(fontSize: 16),
          ),
        ),
      ),
    ),
  );

  /// The design's own decisions, in plain sentences. They are the kind of
  /// thing somebody wants once, before trusting this with anything.
  Widget _howItWorks(AppLocalizations l10n) {
    final bullets = l10n.privateAlbumHowBullets.split('\n');
    final shown = _howExpanded
        ? bullets
        : bullets.take(_howCollapsedLines).toList();
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.privateAlbumHowTitle,
              style: const TextStyle(
                fontSize: 13,
                letterSpacing: 0.4,
                color: CupertinoColors.systemGrey,
              ),
            ),
            const SizedBox(height: 10),
            for (final bullet in shown)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '\u2022  ',
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.45,
                        color: CupertinoColors.systemGrey,
                      ),
                    ),
                    Expanded(
                      child: Text(
                        bullet,
                        style: const TextStyle(
                          fontSize: 13,
                          height: 1.45,
                          color: CupertinoColors.systemGrey,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            CupertinoButton(
              padding: EdgeInsets.zero,
              minimumSize: Size.zero,
              onPressed: () => setState(() => _howExpanded = !_howExpanded),
              child: Text(
                _howExpanded ? l10n.actionLess : l10n.actionMore,
                style: const TextStyle(fontSize: 15),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// What happens to a hidden photo, on the screen the hidden photos are
  /// on. Nothing to choose here: hiding a photo *is* sending it to the
  /// bucket encrypted, and the only fork left is whether a bucket exists.
  Widget _backupFooter(AppLocalizations l10n) => SliverToBoxAdapter(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(20, 32, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.privateAlbumBackupTitle.toUpperCase(),
            style: const TextStyle(
              fontSize: 13,
              letterSpacing: 0.4,
              color: CupertinoColors.systemGrey,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            _hasTarget
                ? l10n.privateAlbumBackupStatusOn
                : l10n.privateAlbumBackupStatusOff,
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: CupertinoColors.white,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            _hasTarget
                ? l10n.privateAlbumBackupExplainer
                : l10n.privateAlbumBackupNoBucket,
            style: const TextStyle(
              fontSize: 13,
              height: 1.45,
              color: CupertinoColors.systemGrey,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            l10n.privateAlbumBackupRecentlyDeleted,
            style: const TextStyle(
              fontSize: 13,
              height: 1.45,
              color: CupertinoColors.systemGrey,
            ),
          ),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return withPrivacyCover(
      CupertinoPageScaffold(
        navigationBar: CupertinoNavigationBar(
          middle: Text(l10n.privateAlbumScreenTitle),
          leading: _selecting
              ? CupertinoButton(
                  padding: EdgeInsets.zero,
                  onPressed: _exitSelectMode,
                  child: Text(l10n.actionCancel),
                )
              : null,
          // Everything that acts on the *album* rather than on a photo is
          // behind the one button: the backup switch, the passphrases, the
          // delete. They are settings for this album, and a row of them
          // across the top read as a toolbar of unrelated verbs — with
          // "Delete Private Album" sitting in red next to "Add", a tap away
          // from each other.
          trailing: _selecting
              ? null
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_records.isNotEmpty)
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
                      onPressed: _showAlbumMenu,
                      child: const Icon(
                        CupertinoIcons.ellipsis_circle,
                        size: 22,
                      ),
                    ),
                  ],
                ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '${l10n.privateAlbumItemCount(_records.length)} · ${_formatSize(_totalBytes)}',
                    style: const TextStyle(color: CupertinoColors.systemGrey),
                  ),
                ),
              ),
              Expanded(
                child: AssetGridView(
                  records: _records,
                  onTap: _open,
                  selectedIds: _selecting ? _selectedIds : null,
                  // Mounted even with nothing in it, so the backup footer is
                  // there for the decision that gets made before the first
                  // photo goes in.
                  emptySliver: SliverToBoxAdapter(
                    key: const ValueKey('privateAlbumEmpty'),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 48),
                      child: Center(
                        child: Text(
                          l10n.privateAlbumEmpty,
                          style: const TextStyle(
                            color: CupertinoColors.systemGrey,
                          ),
                        ),
                      ),
                    ),
                  ),
                  trailingSlivers: [
                    _cloudSliver(l10n),
                    _addSliver(l10n),
                    _backupFooter(l10n),
                    _howItWorks(l10n),
                  ],
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
      ),
    );
  }
}
