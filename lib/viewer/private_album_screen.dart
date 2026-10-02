import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:intl/intl.dart';

import '../photos/derived_asset.dart';
import '../photos/library_metadata.dart';
import '../l10n/app_localizations.dart';
import '../photos/library_custody.dart';
import '../storage/asset_record.dart';
import '../settings/backup_targets_store.dart';
import '../storage/asset_record_store.dart';
import '../vault/album_index.dart';
import '../vault/bucket.dart';
import '../vault/cache.dart';
import '../vault/gallery.dart';
import '../vault/hidden_notes.dart';
import '../vault/hidden_removal.dart';
import '../vault/hidden_restore.dart';
import '../vault/passphrase_sheet.dart';
import '../vault/private_lifecycle.dart';
import '../vault/keys.dart';
import '../vault/photo_screen.dart';
import 'asset_grid.dart';
import 'asset_grid_view.dart';
import 'asset_picker_screen.dart';
import 'detail_screen.dart';
import 'resize_photos.dart';
import 'select_sweep.dart';
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
    this.targetsStore,
  });

  final String passcodeHash;
  final AssetRecordStore assetRecordStore;

  /// Overridable for tests so they never touch the real photo library.
  final LibraryCustody? custody;

  /// Where the buckets are, for the one question hiding has to ask: with
  /// none configured this app's container becomes the only copy. Overridable
  /// so tests don't reach the keychain.
  final BackupTargetsStore? targetsStore;

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
    _loadNotes();
  }

  late final HiddenNotes? _notesStore = widget.albumKeys == null
      ? null
      : HiddenNotes(store: widget.assetRecordStore, keys: widget.albumKeys!);
  List<HiddenNote> _notes = const [];

  Future<void> _loadNotes() async {
    final notes = await _notesStore?.list() ?? const <HiddenNote>[];
    if (mounted) setState(() => _notes = notes);
  }

  /// Add with no [note]; edit or delete with one.
  Future<void> _editNote([HiddenNote? note]) async {
    final store = _notesStore;
    if (store == null) return;
    final l10n = AppLocalizations.of(context)!;
    final controller = TextEditingController(text: note?.text ?? '');
    final action = await showCupertinoModalPopup<String>(
      context: context,
      builder: (sheetContext) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
        ),
        child: Container(
          decoration: const BoxDecoration(
            color: Color(0xFF1C1C1E),
            borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
          ),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      CupertinoButton(
                        padding: EdgeInsets.zero,
                        onPressed: () => Navigator.of(sheetContext).pop(),
                        child: Text(l10n.actionCancel),
                      ),
                      Expanded(
                        child: Text(
                          note == null
                              ? l10n.hiddenNotesAdd
                              : l10n.hiddenNotesEdit,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: CupertinoColors.white,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      CupertinoButton(
                        padding: EdgeInsets.zero,
                        onPressed: () => Navigator.of(sheetContext).pop('save'),
                        child: Text(l10n.settingsSaveButton),
                      ),
                    ],
                  ),
                  CupertinoTextField(
                    key: const ValueKey('hiddenNoteField'),
                    controller: controller,
                    autofocus: true,
                    minLines: 4,
                    maxLines: 10,
                    placeholder: l10n.hiddenNotesPlaceholder,
                  ),
                  if (note != null)
                    CupertinoButton(
                      onPressed: () => Navigator.of(sheetContext).pop('delete'),
                      child: Text(
                        l10n.actionDelete,
                        style: const TextStyle(
                          color: CupertinoColors.systemRed,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    final text = controller.text.trim();
    controller.dispose();
    if (action == 'save' && text.isNotEmpty) {
      await store.save(text, existing: note);
    } else if (action == 'delete' && note != null) {
      await store.delete(note.id);
    } else {
      return;
    }
    await _loadNotes();
  }

  Widget _notesSliver(AppLocalizations l10n) {
    if (_notesStore == null) {
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }
    const grey = TextStyle(fontSize: 12, color: CupertinoColors.systemGrey);
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 28, 20, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    l10n.hiddenNotesTitle.toUpperCase(),
                    style: const TextStyle(
                      fontSize: 13,
                      letterSpacing: 0.4,
                      color: CupertinoColors.systemGrey,
                    ),
                  ),
                ),
                CupertinoButton(
                  key: const ValueKey('hiddenNoteAdd'),
                  padding: EdgeInsets.zero,
                  minimumSize: Size.zero,
                  onPressed: _editNote,
                  child: const Icon(CupertinoIcons.add_circled, size: 22),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (_notes.isEmpty)
              Text(l10n.hiddenNotesEmpty, style: grey)
            else
              for (final note in _notes)
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _editNote(note),
                  child: Container(
                    width: double.infinity,
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF2C2C2E),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          note.text,
                          maxLines: 6,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 15,
                            color: CupertinoColors.white,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          DateFormat.yMMMd().add_jm().format(note.updatedAt),
                          style: grey,
                        ),
                      ],
                    ),
                  ),
                ),
          ],
        ),
      ),
    );
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
    await _reloadHoldings();
    // Filed while there was no bucket: offered up now one may exist.
    unawaited(gallery.sendUnsent(entries));
  }

  /// Which entries are held in full here, and what that weighs. Its own
  /// pass, after the grid is already on screen: it stats a directory, and a
  /// photo grid must not wait on a filesystem walk.
  Future<void> _reloadHoldings() async {
    final gallery = _gallery;
    if (gallery == null) return;
    final held = await gallery.localKeys(_cloudEntries);
    final usage = await gallery.store.usage();
    if (!mounted) return;
    setState(() {
      _onThisPhone = held;
      _localBytes = usage.carrierBytes + usage.thumbnailBytes;
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

  /// Which of [_cloudEntries] this phone still holds in full. The rest draw
  /// from a kept thumbnail and need a download to open.
  Set<String> _onThisPhone = const {};

  /// What the carriers cost on this phone — the number that makes "send some
  /// of these back to the bucket" a decision rather than a guess.
  int _localBytes = 0;

  /// Selection over the bucket-side grid, separate from [_selecting] over the
  /// local records: the two grids hold different things and offer different
  /// verbs. One selection mode covering both would put "Move to Library"
  /// beside "Download" for photos that can only do one of them.
  bool _cloudSelecting = false;
  Set<String> _selectedCloudKeys = {};
  bool _cloudBusy = false;
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
    // Binned ones too: a hidden photo never shows in Recently Deleted, so
    // one binned by an older build is reachable only from here.
    final records = all.toList()
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
      await resetBackupAfterUnhide(
        record,
        widget.assetRecordStore,
        loadTargets: widget.targetsStore?.loadAll,
      );
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

  final _sweep = SelectSweep<String>();
  final _cloudSweep = SelectSweep<String>();

  /// Holding a photo starts selecting it; the same finger then sweeps.
  void _startSelecting(AssetRecord record) {
    setState(() {
      _selecting = true;
      _selectedIds = {..._selectedIds, record.localId};
    });
    _sweep.begin(record.localId);
  }

  void _onSweep(Offset globalPosition) {
    if (!_selecting) return;
    final record = metaDataUnder<AssetRecord>(context, globalPosition);
    if (record == null) return;
    final next = _sweep.over(record.localId, _selectedIds);
    if (next != null) setState(() => _selectedIds = next);
  }

  void _onCloudSweep(Offset globalPosition) {
    if (!_cloudSelecting) return;
    final entry = metaDataUnder<IndexEntry>(context, globalPosition);
    if (entry == null) return;
    final next = _cloudSweep.over(entry.objectKey, _selectedCloudKeys);
    if (next != null) setState(() => _selectedCloudKeys = next);
  }

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

  /// Permanent, not the library's bin: Recently Deleted opens without a
  /// passcode. See `../vault/hidden_removal.dart`.
  late final HiddenRemoval _removal = HiddenRemoval(
    store: widget.assetRecordStore,
    targetsStore: widget.targetsStore,
  );

  Future<bool> _delete(AssetRecord record) => _deleteHidden(records: [record]);

  Future<bool> _deleteHidden({
    List<AssetRecord> records = const [],
    List<IndexEntry> entries = const [],
  }) async {
    final count = records.length + entries.length;
    if (count == 0 || !await _confirmHiddenDelete(count)) return false;
    final done = await _removal.delete(
      keys: widget.albumKeys,
      records: records,
      entries: entries,
      passphrases: _passphrases,
    );
    if (!mounted) return done;
    await _reload();
    await _refreshCloud();
    if (!done && mounted) {
      await _say(AppLocalizations.of(context)!.hiddenDeleteFailed);
    }
    return done;
  }

  Future<bool> _confirmHiddenDelete(int count) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showCupertinoModalPopup<bool>(
      context: context,
      builder: (context) => CupertinoActionSheet(
        title: Text(l10n.hiddenDeleteConfirmTitle(count)),
        message: Text(l10n.hiddenDeleteConfirmBody),
        actions: [
          CupertinoActionSheetAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.actionDelete),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l10n.actionCancel),
        ),
      ),
    );
    return confirmed ?? false;
  }

  Future<void> _refreshCloud() async {
    final gallery = _gallery;
    if (gallery == null) return;
    final entries = await gallery.list();
    if (!mounted) return;
    setState(() {
      _cloudEntries = entries;
      _selectedCloudKeys = {
        for (final e in entries)
          if (_selectedCloudKeys.contains(e.objectKey)) e.objectKey,
      };
    });
    await _reloadHoldings();
  }

  Future<void> _deleteSelected() async {
    final chosen = _records
        .where((r) => _selectedIds.contains(r.localId))
        .toList();
    if (await _deleteHidden(records: chosen)) _exitSelectMode();
  }

  /// Resized copies stay in this album; a replaced original goes through
  /// [HiddenRemoval], for good — there is no Recently Deleted in here.
  Future<void> _resizeSelected() async {
    final l10n = AppLocalizations.of(context)!;
    final chosen = [
      for (final r in _records)
        if (_selectedIds.contains(r.localId) && !r.countsAsVideo) r,
    ];
    final created = await resizePhotos<AssetRecord>(
      context,
      records: chosen,
      readBytes: (r) async {
        final path = r.sourcePath;
        return path == null ? null : File(path).readAsBytes();
      },
      saveCopy: (source, bytes) => createDerivedAsset(
        source: source,
        bytes: bytes,
        extension: '.jpg',
        store: widget.assetRecordStore,
      ),
      replaceOriginals: (originals) => _removal.delete(
        keys: widget.albumKeys,
        records: originals,
        passphrases: _passphrases,
      ),
      replaceNote: l10n.resizeBodyHidden,
    );
    if (created.isEmpty || !mounted) return;
    _exitSelectMode();
    await _reload();
  }

  Future<void> _resizeSelectedCloud() async {
    final gallery = _gallery;
    if (gallery == null) return;
    final l10n = AppLocalizations.of(context)!;
    final created = await resizePhotos<IndexEntry>(
      context,
      records: [
        for (final e in _selectedCloud)
          if (!e.isVideo) e,
      ],
      readBytes: gallery.original,
      // A filed photo has no record left; the copy is a new one in this
      // album, filed the usual way.
      saveCopy: (entry, bytes) => createDerivedAsset(
        source: AssetRecord(
          localId: 'vault:${entry.objectKey}',
          contentHash: entry.objectKey,
          platform: 'ios',
          createdAt: entry.takenAt,
          updatedAt: entry.takenAt,
          passcodeHash: widget.passcodeHash,
        ),
        bytes: bytes,
        extension: '.jpg',
        store: widget.assetRecordStore,
      ),
      replaceOriginals: (originals) => _removal.delete(
        keys: widget.albumKeys,
        entries: originals,
        passphrases: _passphrases,
      ),
      replaceNote: l10n.resizeBodyHidden,
    );
    if (created.isEmpty || !mounted) return;
    _exitCloudSelect();
    await _reload();
    await _refreshCloud();
  }

  Future<void> _deleteSelectedCloud() async {
    if (await _deleteHidden(entries: _selectedCloud)) _exitCloudSelect();
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
      targetsStore: widget.targetsStore,
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

  /// The two things you can do to a selection of hidden photos: send the
  /// full copies back to the bucket, or bring them down.
  ///
  /// Both are shown whatever is selected, and each is dead when it would do
  /// nothing — a mixed selection is the normal case, and a bar whose buttons
  /// appear and vanish as tiles are tapped is harder to aim at than one whose
  /// buttons grey out.
  Widget _cloudSelectionBar(AppLocalizations l10n) {
    final chosen = _selectedCloud;
    final here = chosen.where((e) => _onThisPhone.contains(e.objectKey)).length;
    final away = chosen.length - here;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        child: Column(
          children: [
            Text(
              l10n.vaultSelectionHeld(here, away),
              style: const TextStyle(
                fontSize: 12,
                color: CupertinoColors.systemGrey,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: CupertinoButton(
                    color: const Color(0xFF2C2C2E),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    onPressed: _cloudBusy || here == 0 ? null : _freeUpSelected,
                    child: Text(
                      l10n.vaultFreeUpButton(here),
                      style: const TextStyle(fontSize: 15),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                CupertinoButton(
                  color: const Color(0xFF2C2C2E),
                  padding: const EdgeInsets.symmetric(
                    vertical: 10,
                    horizontal: 14,
                  ),
                  onPressed: _cloudBusy || chosen.isEmpty
                      ? null
                      : _resizeSelectedCloud,
                  child: const Icon(CupertinoIcons.fullscreen_exit, size: 20),
                ),
                const SizedBox(width: 8),
                CupertinoButton(
                  key: const ValueKey('vaultRecoverSelected'),
                  color: const Color(0xFF2C2C2E),
                  padding: const EdgeInsets.symmetric(
                    vertical: 10,
                    horizontal: 14,
                  ),
                  onPressed: _cloudBusy || chosen.isEmpty
                      ? null
                      : _recoverSelectedCloud,
                  child: const Icon(CupertinoIcons.arrow_uturn_left, size: 20),
                ),
                const SizedBox(width: 8),
                CupertinoButton(
                  color: const Color(0xFF2C2C2E),
                  padding: const EdgeInsets.symmetric(
                    vertical: 10,
                    horizontal: 14,
                  ),
                  onPressed: _cloudBusy || chosen.isEmpty
                      ? null
                      : _deleteSelectedCloud,
                  child: const Icon(
                    CupertinoIcons.delete,
                    size: 20,
                    color: CupertinoColors.systemRed,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: CupertinoButton.filled(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    onPressed: _cloudBusy || away == 0
                        ? null
                        : _downloadSelected,
                    child: Text(
                      l10n.vaultDownloadButton(away),
                      style: const TextStyle(fontSize: 15),
                    ),
                  ),
                ),
              ],
            ),
          ],
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
            selecting: _cloudSelecting,
            selected: _selectedCloudKeys.contains(entry.objectKey),
            onThisPhone: _onThisPhone.contains(entry.objectKey),
            onTap: _cloudSelecting
                ? () => _toggleCloud(entry)
                : () => _openCloud(entry),
            onLongPress: _cloudSelecting
                ? null
                : () => _enterCloudSelect(entry),
            onSelectDragUpdate: _onCloudSweep,
            onSelectDragEnd: _cloudSweep.end,
          );
        }, childCount: _cloudEntries.length),
      ),
    );
  }

  void _enterCloudSelect(IndexEntry entry) {
    setState(() {
      _cloudSelecting = true;
      _selectedCloudKeys = {entry.objectKey};
    });
    _cloudSweep.begin(entry.objectKey);
  }

  void _exitCloudSelect() => setState(() {
    _cloudSelecting = false;
    _selectedCloudKeys = {};
  });

  void _toggleCloud(IndexEntry entry) => setState(() {
    if (!_selectedCloudKeys.remove(entry.objectKey)) {
      _selectedCloudKeys.add(entry.objectKey);
    }
  });

  List<IndexEntry> get _selectedCloud => [
    for (final entry in _cloudEntries)
      if (_selectedCloudKeys.contains(entry.objectKey)) entry,
  ];

  /// Drops the full local copy of each selected photo and keeps its tile.
  ///
  /// Each one is checked against the bucket first (`sendBackToBucket`), and
  /// a photo the bucket cannot be shown to hold is left alone and counted —
  /// freeing space must never be how a hidden photo stops existing.
  Future<void> _freeUpSelected() async {
    final gallery = _gallery;
    if (gallery == null || _cloudBusy) return;
    final chosen = _selectedCloud;
    if (chosen.isEmpty) return;
    setState(() => _cloudBusy = true);
    var freed = 0;
    var refused = 0;
    for (final entry in chosen) {
      if (await gallery.sendBackToBucket(entry)) {
        freed++;
      } else {
        refused++;
      }
    }
    if (!mounted) return;
    setState(() => _cloudBusy = false);
    _exitCloudSelect();
    await _reloadHoldings();
    if (!mounted) return;
    final l10n = AppLocalizations.of(context)!;
    await _say(
      refused == 0
          ? l10n.vaultFreedResult(freed)
          : l10n.vaultFreedPartial(freed, refused),
    );
  }

  /// Un-hides filed photos: each goes back to Photos first, and leaves the
  /// album only once Photos has it. One that can't go back stays here.
  Future<void> _recoverSelectedCloud() async {
    final gallery = _gallery;
    final keys = widget.albumKeys;
    if (gallery == null || keys == null || _cloudBusy) return;
    final chosen = _selectedCloud;
    if (chosen.isEmpty) return;
    setState(() => _cloudBusy = true);
    final restore = HiddenRestore(
      gallery: gallery,
      saveFiles: _custody.saveFiles,
    );
    final plainIds = <String, String>{};
    for (final entry in chosen) {
      final localId = await restore.restore(entry);
      if (localId != null) plainIds[entry.objectKey] = localId;
    }
    final released = await _removal.release(
      keys: keys,
      plainIds: plainIds,
      passphrases: _passphrases,
    );
    if (!mounted) return;
    setState(() => _cloudBusy = false);
    _exitCloudSelect();
    await _refreshCloud();
    final failed = released ? chosen.length - plainIds.length : chosen.length;
    if (failed > 0 && mounted) {
      await _showNote(
        AppLocalizations.of(context)!.privateAlbumReturnFailed(failed),
      );
    }
  }

  /// Brings the selected photos back down, so they open with no network.
  Future<void> _downloadSelected() async {
    final gallery = _gallery;
    if (gallery == null || _cloudBusy) return;
    final chosen = [
      for (final entry in _selectedCloud)
        if (!_onThisPhone.contains(entry.objectKey)) entry,
    ];
    if (chosen.isEmpty) return;
    setState(() => _cloudBusy = true);
    var got = 0;
    for (final entry in chosen) {
      if (await gallery.download(entry)) got++;
    }
    if (!mounted) return;
    setState(() => _cloudBusy = false);
    _exitCloudSelect();
    await _reloadHoldings();
    if (!mounted) return;
    final l10n = AppLocalizations.of(context)!;
    await _say(
      got == chosen.length
          ? l10n.vaultDownloadedResult(got)
          : l10n.vaultDownloadedPartial(got, chosen.length - got),
    );
  }

  Future<void> _say(String message) => showCupertinoDialog<void>(
    context: context,
    builder: (dialogContext) => CupertinoAlertDialog(
      content: Text(message),
      actions: [
        CupertinoDialogAction(
          isDefaultAction: true,
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: Text(AppLocalizations.of(context)!.actionOk),
        ),
      ],
    ),
  );

  Future<void> _openCloud(IndexEntry entry) async {
    final gallery = _gallery;
    if (gallery == null) return;
    await Navigator.of(context).push(
      CupertinoPageRoute<void>(
        builder: (_) => VaultPhotoScreen(
          gallery: gallery,
          entry: entry,
          onDelete: () => _deleteHidden(entries: [entry]),
        ),
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
          leading: _selecting || _cloudSelecting
              ? CupertinoButton(
                  padding: EdgeInsets.zero,
                  onPressed: _selecting ? _exitSelectMode : _exitCloudSelect,
                  child: Text(l10n.actionCancel),
                )
              : null,
          // Everything that acts on the *album* rather than on a photo is
          // behind the one button: the backup switch, the passphrases, the
          // delete. They are settings for this album, and a row of them
          // across the top read as a toolbar of unrelated verbs — with
          // "Delete Private Album" sitting in red next to "Add", a tap away
          // from each other.
          trailing: _selecting || _cloudSelecting
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
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Both grids in one number. Counting only the local
                      // records read as an empty album the moment the
                      // carriers were filed and the rows deleted.
                      Text(
                        '${l10n.privateAlbumItemCount(_records.length + _cloudEntries.length)}'
                        ' · ${_formatSize(_totalBytes + _localBytes)}',
                        style: const TextStyle(
                          color: CupertinoColors.systemGrey,
                        ),
                      ),
                      // What is held in full here, which is the number the
                      // "free up space" decision is made against.
                      if (_onThisPhone.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            l10n.vaultLocalFooter(
                              _onThisPhone.length,
                              _formatSize(_localBytes),
                            ),
                            style: const TextStyle(
                              fontSize: 12,
                              color: CupertinoColors.systemGrey,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              Expanded(
                child: AssetGridView(
                  records: _records,
                  onTap: _open,
                  selectedIds: _selecting ? _selectedIds : null,
                  onLongPress: _startSelecting,
                  onSelectDragUpdate: _onSweep,
                  onSelectDragEnd: _sweep.end,
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
                    _notesSliver(l10n),
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
                    child: Row(
                      children: [
                        Expanded(
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
                        const SizedBox(width: 8),
                        CupertinoButton(
                          color: const Color(0xFF2C2C2E),
                          onPressed: _selectedIds.isEmpty
                              ? null
                              : _resizeSelected,
                          child: const Icon(CupertinoIcons.fullscreen_exit),
                        ),
                        const SizedBox(width: 8),
                        CupertinoButton(
                          color: const Color(0xFF2C2C2E),
                          onPressed: _selectedIds.isEmpty
                              ? null
                              : _deleteSelected,
                          child: const Icon(
                            CupertinoIcons.delete,
                            color: CupertinoColors.systemRed,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              if (_cloudSelecting) _cloudSelectionBar(l10n),
            ],
          ),
        ),
      ),
    );
  }
}
