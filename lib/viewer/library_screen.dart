import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';

import '../l10n/app_localizations.dart';
import '../photos/ai_analysis_store.dart';
import '../photos/demo_assets_service.dart';
import '../photos/demo_seed_store.dart';
import '../photos/manual_add.dart';
import '../photos/person_store.dart';
import '../photos/photo_library_service.dart';
import '../settings/ai_settings_screen.dart';
import '../settings/backup_targets_store.dart';
import '../settings/settings_screen.dart';
import '../storage/album.dart';
import '../storage/album_store.dart';
import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import '../storage/private_album_store.dart';
import '../upload/backup_coordinator.dart';
import 'album_screen.dart';
import 'asset_grid.dart';
import 'backup_screen.dart';
import 'coming_soon_screen.dart';
import 'delete_confirmation.dart';
import 'detail_screen.dart';
import 'favorites_screen.dart';
import 'media_type_screen.dart';
import 'people_screen.dart';
import 'private_album_gate.dart';
import 'recently_deleted_screen.dart';
import 'smart_collection_screen.dart';

/// The whole app, one page — matches real Photos: no separate "Library" vs
/// "Collections" tabs, just a day-grouped grid up top and Media
/// Types/Utilities sections below (Favorites/Hidden/Recently Deleted are
/// real; Backup Status/S3 Settings are this app's own, kept at the bottom).
/// Lists manually-added/demo files, not a real camera-roll grid (T4.1 still
/// needs `photo_manager`, T2.1).
class LibraryScreen extends StatefulWidget {
  const LibraryScreen({
    super.key,
    this.assetRecordStore,
    this.backupTargetsStore,
    this.albumStore,
    this.manualAddService,
    this.demoAssetsService,
    this.demoSeedStore,
    this.backupCoordinator,
    this.aiAnalysisStore,
    this.photoLibraryService,
    this.privateAlbumStore,
    this.personStore,
  });

  final AssetRecordStore? assetRecordStore;
  final BackupTargetsStore? backupTargetsStore;
  final AlbumStore? albumStore;

  /// Overridable for tests so Private Albums/People never open the real
  /// `sqflite` factory.
  final PrivateAlbumStore? privateAlbumStore;
  final PersonStore? personStore;

  /// Overridable for tests so the People/Events smart collections never open
  /// the real (platform-backed) `sqflite` factory.
  final AiAnalysisStore? aiAnalysisStore;

  /// Overridable for tests so they never touch the real `photo_manager`
  /// platform channel.
  final PhotoLibraryService? photoLibraryService;

  /// Overridable for tests so they never open the real file picker.
  final ManualAddService? manualAddService;

  /// Overridable for tests so they never touch the real asset bundle / disk.
  final DemoAssetsService? demoAssetsService;

  /// Overridable for tests so they never touch real secure storage.
  final DemoSeedStore? demoSeedStore;

  /// Overridable for tests so they never construct a real `S3Uploader`
  /// (which touches the `background_downloader` platform channel).
  final BackupCoordinator? backupCoordinator;

  @override
  State<LibraryScreen> createState() => LibraryScreenState();
}

class LibraryScreenState extends State<LibraryScreen> {
  late final AssetRecordStore assetRecordStore = widget.assetRecordStore ?? AssetRecordStore();
  late final BackupTargetsStore _backupTargetsStore = widget.backupTargetsStore ?? BackupTargetsStore();
  late final AlbumStore _albumStore = widget.albumStore ?? AlbumStore();
  late final ManualAddService _manualAddService =
      widget.manualAddService ?? ManualAddService(store: assetRecordStore);
  late final PrivateAlbumStore _privateAlbumStore = widget.privateAlbumStore ?? PrivateAlbumStore();
  late final PersonStore _personStore = widget.personStore ?? PersonStore();
  late final DemoAssetsService _demoAssetsService =
      widget.demoAssetsService ??
      DemoAssetsService(
        manualAddService: _manualAddService,
        albumStore: _albumStore,
        privateAlbumStore: _privateAlbumStore,
        personStore: _personStore,
      );
  late final DemoSeedStore _demoSeedStore = widget.demoSeedStore ?? DemoSeedStore();
  late final BackupCoordinator _coordinator =
      widget.backupCoordinator ?? BackupCoordinator(targetsStore: _backupTargetsStore, recordStore: assetRecordStore);
  late final AiAnalysisStore _aiAnalysisStore = widget.aiAnalysisStore ?? AiAnalysisStore();
  late final PhotoLibraryService _photoLibraryService =
      widget.photoLibraryService ?? PhotoLibraryService(store: assetRecordStore);

  List<AssetRecord> _all = const [];
  List<Album> _albums = const [];
  Map<String, List<AssetRecord>> _albumAssets = const {};
  String _query = '';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  /// A fresh install seeds the bundled demo photos automatically — no
  /// "Try with Demo Photos" tap required — but only once ever: after that,
  /// deleting them stays deleted until the user explicitly resets via
  /// Utilities' "Reset Demo Data". Also backs them up right away (silently,
  /// no result dialog) to any already-configured S3 target, same as a
  /// manual add — otherwise they'd sit as "pending" forever despite the
  /// files already existing in a bucket configured before this launch.
  Future<void> _init() async {
    try {
      if (!await _demoSeedStore.hasSeeded()) {
        final added = await _demoAssetsService.addAll();
        await _demoSeedStore.markSeeded();
        await _backUpRecords(added);
      }
    } catch (_) {
      // Secure storage unavailable/unreadable — skip auto-seeding rather
      // than risk doing it on every launch; "Reset Demo Data" in Utilities
      // still works.
    }
    await reload();
    // Fire-and-forget: a full camera-roll scan (and any iCloud downloads it
    // triggers for backup) can be slow, and must never block showing the
    // manual/demo assets already on hand. Re-`reload()`s itself once done.
    unawaited(_syncPhotoLibrary());
  }

  /// Pulls in the real camera roll (T2.1) — permission prompt on first run,
  /// silent on every launch after. Backs up anything newly seen the same
  /// way a manual add is, so granting access alone starts a backup.
  Future<void> _syncPhotoLibrary() async {
    try {
      final access = await _photoLibraryService.requestAccess();
      if (access == PhotoLibraryAccess.denied) return;
      final added = await _photoLibraryService.syncAll();
      if (added.isEmpty) return;
      await _backUpRecords(added);
      await reload();
    } catch (_) {
      // No `photo_manager` platform channel (tests, unsupported platform)
      // or the permission flow failed — leave the camera roll unsynced
      // rather than crash; manual add/demo photos still work.
    }
  }

  Future<void> reload() async {
    final all = await assetRecordStore.listAll();
    final albums = await _albumStore.listAll();
    final albumAssets = <String, List<AssetRecord>>{};
    for (final album in albums) {
      final memberIds = (await _albumStore.localIdsIn(album.id)).toSet();
      albumAssets[album.id] = all.where((r) => !r.isDeleted && !r.isHidden && memberIds.contains(r.localId)).toList();
    }
    if (!mounted) return;
    setState(() {
      _all = all;
      _albums = albums;
      _albumAssets = albumAssets;
    });
  }

  List<AssetRecord> get _active =>
      _all.where((r) => !r.isDeleted && !r.isHidden).toList()..sort((a, b) => b.createdAt.compareTo(a.createdAt));

  List<AssetRecord> get _filtered => _query.isEmpty
      ? _active
      : _active.where((r) => (r.sourcePath ?? r.localId).toLowerCase().contains(_query.toLowerCase())).toList();

  int get _photoCount => _active.where((r) => !r.isVideo).length;
  int get _videoCount => _active.where((r) => r.isVideo).length;
  int get _favoriteCount => _all.where((r) => r.isFavorite && !r.isDeleted).length;
  int get _hiddenCount => _all.where((r) => r.isHidden && !r.isDeleted).length;
  int get _deletedCount => _all.where((r) => r.isDeleted).length;
  int get _pendingCount =>
      _active.where((r) => r.stateOf(DerivativeKind.original).status != UploadStatus.uploaded).length;

  Future<int> _backUpRecords(List<AssetRecord> records) async {
    var succeeded = 0;
    for (final record in records) {
      try {
        final path = await _filePathFor(record);
        if (path == null) continue;
        final count = await _coordinator.backUpDerivative(record: record, kind: DerivativeKind.original, filePath: path);
        if (count > 0) succeeded++;
      } catch (_) {
        // One asset's file couldn't be resolved (e.g. an iCloud fetch
        // failed, or it was removed from the library mid-sync) — skip just
        // that one rather than aborting the rest of the batch.
      }
    }
    return succeeded;
  }

  /// [AssetRecord.sourcePath] direct for `manualFile`; for `photoManager`
  /// it's resolved on demand via `photo_manager` — may trigger an iCloud
  /// download on iOS, so can be slow the first time.
  Future<String?> _filePathFor(AssetRecord record) async {
    final path = record.sourcePath;
    if (path != null) return path;
    if (record.sourceType != AssetSourceType.photoManager) return null;
    final file = await _photoLibraryService.fileFor(record);
    return file?.path;
  }

  Future<void> _backUpAndReport(List<AssetRecord> records) async {
    final succeeded = await _backUpRecords(records);
    await reload();
    if (!mounted) return;
    final l10n = AppLocalizations.of(context)!;
    _showResult(l10n.libraryAddFilesResult(records.length, succeeded));
  }

  void _showResult(String message) {
    showCupertinoDialog<void>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        content: Text(message),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(AppLocalizations.of(context)!.actionCancel),
          ),
        ],
      ),
    );
  }

  Future<void> _runBusy(Future<List<AssetRecord>> Function() pick) async {
    setState(() => _busy = true);
    try {
      final records = await pick();
      await _backUpAndReport(records);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> addFiles() => _runBusy(_manualAddService.pickAndEnqueue);

  /// Also doubles as Utilities' "Reset Demo Data": re-adds any bundled demo
  /// photos/videos missing from the Library (e.g. deleted there) and backs
  /// them up — a no-op add for ones already present, keyed by content hash.
  Future<void> _addDemoPhotos() => _runBusy(_demoAssetsService.addAll);

  Future<void> _toggleFavorite(AssetRecord record) async {
    await assetRecordStore.setFavorite(record.localId, !record.isFavorite);
    await reload();
  }

  Future<void> _hide(AssetRecord record) async {
    await hideIntoPrivateAlbum(
      context,
      assetRecordStore: assetRecordStore,
      privateAlbumStore: _privateAlbumStore,
      record: record,
    );
    await reload();
  }

  Future<bool> _softDelete(AssetRecord record) async {
    if (!await confirmSoftDelete(context)) return false;
    await assetRecordStore.softDelete(record.localId);
    await reload();
    return true;
  }

  List<TileAction> _actionsFor(AppLocalizations l10n, AssetRecord record) => [
    TileAction(
      icon: record.isFavorite ? CupertinoIcons.heart_slash : CupertinoIcons.heart,
      label: record.isFavorite ? l10n.libraryUnfavorite : l10n.libraryFavorite,
      onPressed: () => _toggleFavorite(record),
    ),
    TileAction(icon: CupertinoIcons.eye_slash, label: l10n.libraryHide, onPressed: () => _hide(record)),
    TileAction(
      icon: CupertinoIcons.delete,
      label: l10n.libraryDeleteTooltip,
      isDestructive: true,
      onPressed: () => _softDelete(record),
    ),
  ];

  void _openRecord(AssetRecord record) {
    final records = _filtered;
    Navigator.of(context).push(
      CupertinoPageRoute(
        builder: (_) => DetailScreen(
          records: records,
          initialIndex: records.indexOf(record),
          onDelete: _softDelete,
          onToggleFavorite: _toggleFavorite,
        ),
      ),
    );
  }

  Future<void> _push(Widget screen) async {
    await Navigator.of(context).push(CupertinoPageRoute(builder: (_) => screen));
    await reload();
  }

  Future<void> _openPrivateAlbums() async {
    await openPrivateAlbums(context, assetRecordStore: assetRecordStore, privateAlbumStore: _privateAlbumStore);
    await reload();
  }

  void _openAlbum(Album album) => _push(
    AlbumScreen(
      album: album,
      assetRecordStore: assetRecordStore,
      albumStore: _albumStore,
      privateAlbumStore: _privateAlbumStore,
    ),
  );

  Future<void> _confirmDeleteAlbum(Album album) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showCupertinoDialog<bool>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: Text(l10n.albumDeleteConfirmTitle),
        content: Text(l10n.albumDeleteConfirmBody),
        actions: [
          CupertinoDialogAction(onPressed: () => Navigator.of(context).pop(false), child: Text(l10n.actionCancel)),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.albumDeleteAction),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _albumStore.remove(album.id);
    await reload();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final filtered = _filtered;

    return CupertinoPageScaffold(
      child: SafeArea(
        bottom: false,
        child: CustomScrollView(
          slivers: [
            CupertinoSliverNavigationBar(largeTitle: Text(l10n.tabLibrary)),
            if (_all.isNotEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: CupertinoSearchTextField(onChanged: (v) => setState(() => _query = v)),
                ),
              ),
            if (_all.isEmpty)
              SliverToBoxAdapter(
                child: _EmptyState(busy: _busy, onAddDemo: _addDemoPhotos, onAddFiles: addFiles),
              )
            else ...[
              ...assetGridSlivers(
                context: context,
                records: filtered,
                onTap: _openRecord,
                actionsFor: (r) => _actionsFor(l10n, r),
              ),
              SliverToBoxAdapter(child: _SectionHeader(title: l10n.collectionsCollections)),
              if (_albums.isNotEmpty) ...[
                SliverToBoxAdapter(child: _SubsectionHeader(title: l10n.collectionsAlbums)),
                SliverToBoxAdapter(
                  child: SizedBox(
                    height: 190,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: _albums.length,
                      separatorBuilder: (context, i) => const SizedBox(width: 12),
                      itemBuilder: (context, i) => SizedBox(
                        width: 140,
                        child: _AlbumCard(
                          album: _albums[i],
                          records: _albumAssets[_albums[i].id] ?? const [],
                          onTap: () => _openAlbum(_albums[i]),
                          onDelete: () => _confirmDeleteAlbum(_albums[i]),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
              SliverToBoxAdapter(child: _SubsectionHeader(title: l10n.collectionsPeopleRow)),
              SliverToBoxAdapter(
                child: _PlaceholderCollectionRow(
                  icon: CupertinoIcons.person_2_fill,
                  color: CupertinoColors.systemYellow,
                  label: l10n.collectionsPeopleCardLabel,
                  onTap: () => _push(
                    PeopleScreen(
                      personStore: _personStore,
                      assetRecordStore: assetRecordStore,
                      aiAnalysisStore: _aiAnalysisStore,
                    ),
                  ),
                ),
              ),
              SliverToBoxAdapter(child: _SubsectionHeader(title: l10n.collectionsPlacesRow)),
              SliverToBoxAdapter(
                child: _PlaceholderCollectionRow(
                  icon: CupertinoIcons.map_pin_ellipse,
                  color: CupertinoColors.systemTeal,
                  onTap: () => _push(
                    ComingSoonScreen(
                      title: l10n.collectionsPlacesRow,
                      body: l10n.collectionsPlacesComingSoonBody,
                      icon: CupertinoIcons.map_pin_ellipse,
                    ),
                  ),
                ),
              ),
              SliverToBoxAdapter(child: _SubsectionHeader(title: l10n.collectionsEventsRow)),
              SliverToBoxAdapter(
                child: _PlaceholderCollectionRow(
                  icon: CupertinoIcons.calendar,
                  color: CupertinoColors.systemOrange,
                  label: l10n.smartCollectionsCardLabel,
                  onTap: () => _push(
                    SmartCollectionScreen(
                      kind: SmartCollectionKind.events,
                      assetRecordStore: assetRecordStore,
                      aiAnalysisStore: _aiAnalysisStore,
                    ),
                  ),
                ),
              ),
              SliverToBoxAdapter(child: _SectionHeader(title: l10n.collectionsMediaTypes)),
              SliverToBoxAdapter(
                child: CupertinoListSection.insetGrouped(
                  margin: const EdgeInsets.symmetric(horizontal: 16),
                  // Un-overridden, this defaults to systemGroupedBackground
                  // (pure black in dark mode) — a harsher black than the
                  // page's own charcoal, visible as a seam around the card.
                  backgroundColor: const Color(0xFF1C1C1E),
                  decoration: const BoxDecoration(
                    color: Color(0xFF2C2C2E),
                    borderRadius: BorderRadius.all(Radius.circular(10)),
                  ),
                  children: [
                    _row(
                      icon: CupertinoIcons.photo,
                      color: CupertinoColors.systemGreen,
                      title: l10n.collectionsPhotosRow,
                      count: _photoCount,
                      onTap: () => _push(
                        MediaTypeScreen(
                          assetRecordStore: assetRecordStore,
                          isVideo: false,
                          title: l10n.collectionsPhotosRow,
                          privateAlbumStore: _privateAlbumStore,
                        ),
                      ),
                    ),
                    _row(
                      icon: CupertinoIcons.video_camera_solid,
                      color: CupertinoColors.systemPurple,
                      title: l10n.collectionsVideosRow,
                      count: _videoCount,
                      onTap: () => _push(
                        MediaTypeScreen(
                          assetRecordStore: assetRecordStore,
                          isVideo: true,
                          title: l10n.collectionsVideosRow,
                          privateAlbumStore: _privateAlbumStore,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            SliverToBoxAdapter(child: _SectionHeader(title: l10n.collectionsUtilities)),
            SliverToBoxAdapter(
              child: CupertinoListSection.insetGrouped(
                margin: const EdgeInsets.symmetric(horizontal: 16),
                backgroundColor: const Color(0xFF1C1C1E),
                decoration: const BoxDecoration(
                  color: Color(0xFF2C2C2E),
                  borderRadius: BorderRadius.all(Radius.circular(10)),
                ),
                children: [
                  _row(
                    icon: CupertinoIcons.square_arrow_up,
                    color: CupertinoColors.systemIndigo,
                    title: l10n.collectionsImportPhotosRow,
                    onTap: _busy ? null : addFiles,
                  ),
                  _row(
                    icon: CupertinoIcons.heart_fill,
                    color: CupertinoColors.systemRed,
                    title: l10n.collectionsFavoritesRow,
                    count: _favoriteCount,
                    onTap: () => _push(FavoritesScreen(assetRecordStore: assetRecordStore)),
                  ),
                  _row(
                    icon: CupertinoIcons.eye_slash_fill,
                    color: CupertinoColors.systemGrey,
                    title: l10n.collectionsHiddenRow,
                    count: _hiddenCount,
                    onTap: _openPrivateAlbums,
                  ),
                  _row(
                    icon: CupertinoIcons.trash_fill,
                    color: CupertinoColors.systemRed,
                    title: l10n.collectionsRecentlyDeletedRow,
                    count: _deletedCount,
                    onTap: () => _push(RecentlyDeletedScreen(assetRecordStore: assetRecordStore)),
                  ),
                  _row(
                    icon: CupertinoIcons.cloud_upload_fill,
                    color: CupertinoColors.systemBlue,
                    title: l10n.collectionsBackupStatusRow,
                    count: _pendingCount,
                    onTap: () => _push(BackupScreen(assetRecordStore: assetRecordStore)),
                  ),
                  _row(
                    icon: CupertinoIcons.gear_alt_fill,
                    color: CupertinoColors.systemGrey2,
                    title: l10n.collectionsSettingsRow,
                    onTap: () => _push(SettingsScreen(store: _backupTargetsStore)),
                  ),
                  _row(
                    icon: CupertinoIcons.sparkles,
                    color: CupertinoColors.systemIndigo,
                    title: l10n.collectionsAiSettingsRow,
                    onTap: () => _push(const AiSettingsScreen()),
                  ),
                  _row(
                    icon: CupertinoIcons.arrow_2_circlepath,
                    color: CupertinoColors.systemGreen,
                    title: l10n.settingsResetDemoButton,
                    onTap: _busy ? null : _addDemoPhotos,
                  ),
                ],
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 24)),
          ],
        ),
      ),
    );
  }

  CupertinoListTile _row({
    required IconData icon,
    required Color color,
    required String title,
    int? count,
    VoidCallback? onTap,
  }) {
    return CupertinoListTile(
      leading: Container(
        width: 29,
        height: 29,
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(7)),
        child: Icon(icon, color: CupertinoColors.white, size: 17),
      ),
      title: Text(title),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (count != null) Text('$count', style: const TextStyle(color: CupertinoColors.systemGrey)),
          const SizedBox(width: 4),
          const Icon(CupertinoIcons.chevron_forward, size: 18, color: CupertinoColors.systemGrey2),
        ],
      ),
      onTap: onTap,
    );
  }
}

class _AlbumCard extends StatelessWidget {
  const _AlbumCard({required this.album, required this.records, required this.onTap, required this.onDelete});

  final Album album;
  final List<AssetRecord> records;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  void _showActions(BuildContext context, AppLocalizations l10n) {
    showCupertinoModalPopup<void>(
      context: context,
      builder: (context) => CupertinoActionSheet(
        title: Text(album.name),
        actions: [
          CupertinoActionSheetAction(
            isDestructiveAction: true,
            onPressed: () {
              Navigator.of(context).pop();
              onDelete();
            },
            child: Text(l10n.albumDeleteAction),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.actionCancel),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cover = records.isEmpty ? null : records.first.sourcePath;
    final coverIsVideo = records.isNotEmpty && records.first.isVideo;

    return GestureDetector(
      onTap: onTap,
      onLongPress: () => _showActions(context, l10n),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: coverIsVideo
                  ? const ColoredBox(
                      color: CupertinoColors.darkBackgroundGray,
                      child: Icon(CupertinoIcons.play_circle_fill, color: CupertinoColors.white, size: 28),
                    )
                  : cover != null
                  ? Image.file(
                      File(cover),
                      fit: BoxFit.cover,
                      width: double.infinity,
                      errorBuilder: (context, error, stackTrace) =>
                          const ColoredBox(color: CupertinoColors.systemGrey5, child: Icon(CupertinoIcons.photo)),
                    )
                  : const ColoredBox(
                      color: CupertinoColors.systemGrey5,
                      child: Icon(CupertinoIcons.photo_on_rectangle),
                    ),
            ),
          ),
          const SizedBox(height: 6),
          Text(album.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          Text('${records.length}', style: const TextStyle(color: CupertinoColors.systemGrey, fontSize: 13)),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 32, 16, 8),
      child: Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 22)),
    );
  }
}

class _SubsectionHeader extends StatelessWidget {
  const _SubsectionHeader({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 17)),
    );
  }
}

/// A single-line, horizontally-scrolling row of album-card-shaped
/// placeholders — People/Places/Events have no real data to group by yet
/// (see IMPLEMENTATION_PLAN.md T4.4), but still look like a populated
/// Collections subsection rather than a bare row. Every card opens the same
/// "coming soon" screen.
class _PlaceholderCollectionRow extends StatelessWidget {
  const _PlaceholderCollectionRow({required this.icon, required this.color, required this.onTap, this.label});

  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  /// Card caption — defaults to "Coming Soon"; People/Events pass their own
  /// since they open a real (opt-in AI analysis) screen, not a stub.
  final String? label;

  static const _cardCount = 4;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return SizedBox(
      height: 150,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: _cardCount,
        separatorBuilder: (context, i) => const SizedBox(width: 12),
        itemBuilder: (context, i) => GestureDetector(
          onTap: onTap,
          child: SizedBox(
            width: 110,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    // Flat neutral card, same as an album with no cover yet
                    // — a translucent tint over a dark page reads as a muddy
                    // smear rather than a clean pastel. `systemGrey5` must be
                    // resolved explicitly: as a bare Color (not routed
                    // through a Cupertino-aware widget) it otherwise paints
                    // its light-mode value even in dark mode.
                    child: ColoredBox(
                      color: CupertinoDynamicColor.resolve(CupertinoColors.systemGrey5, context),
                      child: Icon(icon, color: color, size: 32),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  label ?? l10n.collectionsComingSoonTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: CupertinoColors.systemGrey, fontSize: 13),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.busy, required this.onAddDemo, required this.onAddFiles});

  final bool busy;
  final VoidCallback onAddDemo;
  final VoidCallback onAddFiles;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(CupertinoIcons.photo_on_rectangle, size: 56, color: CupertinoColors.systemGrey),
            const SizedBox(height: 12),
            Text(l10n.libraryEmptyTitle, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(
              l10n.libraryEmptyNote,
              textAlign: TextAlign.center,
              style: const TextStyle(color: CupertinoColors.systemGrey),
            ),
            const SizedBox(height: 20),
            CupertinoButton.filled(onPressed: busy ? null : onAddDemo, child: Text(l10n.libraryAddDemoButton)),
            CupertinoButton(onPressed: busy ? null : onAddFiles, child: Text(l10n.libraryAddFilesButton)),
          ],
        ),
      ),
    );
  }
}
