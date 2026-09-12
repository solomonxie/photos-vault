import 'package:flutter/cupertino.dart';

import '../l10n/app_localizations.dart';
import '../photos/demo_assets_service.dart';
import '../photos/manual_add.dart';
import '../settings/backup_targets_store.dart';
import '../settings/settings_screen.dart';
import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import '../upload/backup_coordinator.dart';
import 'asset_grid.dart';
import 'backup_screen.dart';
import 'detail_screen.dart';
import 'favorites_screen.dart';
import 'hidden_screen.dart';
import 'recently_deleted_screen.dart';

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
    this.manualAddService,
    this.demoAssetsService,
    this.backupCoordinator,
  });

  final AssetRecordStore? assetRecordStore;
  final BackupTargetsStore? backupTargetsStore;

  /// Overridable for tests so they never open the real file picker.
  final ManualAddService? manualAddService;

  /// Overridable for tests so they never touch the real asset bundle / disk.
  final DemoAssetsService? demoAssetsService;

  /// Overridable for tests so they never construct a real `S3Uploader`
  /// (which touches the `background_downloader` platform channel).
  final BackupCoordinator? backupCoordinator;

  @override
  State<LibraryScreen> createState() => LibraryScreenState();
}

class LibraryScreenState extends State<LibraryScreen> {
  late final AssetRecordStore assetRecordStore = widget.assetRecordStore ?? AssetRecordStore();
  late final BackupTargetsStore _backupTargetsStore = widget.backupTargetsStore ?? BackupTargetsStore();
  late final ManualAddService _manualAddService =
      widget.manualAddService ?? ManualAddService(store: assetRecordStore);
  late final DemoAssetsService _demoAssetsService =
      widget.demoAssetsService ?? DemoAssetsService(manualAddService: _manualAddService);
  late final BackupCoordinator _coordinator =
      widget.backupCoordinator ?? BackupCoordinator(targetsStore: _backupTargetsStore, recordStore: assetRecordStore);

  List<AssetRecord> _all = const [];
  String _query = '';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    reload();
  }

  Future<void> reload() async {
    final all = await assetRecordStore.listAll();
    if (!mounted) return;
    setState(() => _all = all.where((r) => r.sourceType == AssetSourceType.manualFile).toList());
  }

  List<AssetRecord> get _active =>
      _all.where((r) => !r.isDeleted && !r.isHidden).toList()..sort((a, b) => b.createdAt.compareTo(a.createdAt));

  List<AssetRecord> get _filtered => _query.isEmpty
      ? _active
      : _active.where((r) => (r.sourcePath ?? r.localId).toLowerCase().contains(_query.toLowerCase())).toList();

  bool _isVideo(AssetRecord r) => r.sourcePath != null && isVideoPath(r.sourcePath!);

  int get _photoCount => _active.where((r) => !_isVideo(r)).length;
  int get _videoCount => _active.where(_isVideo).length;
  int get _favoriteCount => _all.where((r) => r.isFavorite && !r.isDeleted).length;
  int get _hiddenCount => _all.where((r) => r.isHidden && !r.isDeleted).length;
  int get _deletedCount => _all.where((r) => r.isDeleted).length;
  int get _pendingCount =>
      _active.where((r) => r.stateOf(DerivativeKind.original).status != UploadStatus.uploaded).length;

  Future<void> _backUpAndReport(List<AssetRecord> records) async {
    var succeeded = 0;
    for (final record in records) {
      final path = record.sourcePath;
      if (path == null) continue;
      final count = await _coordinator.backUpDerivative(record: record, kind: DerivativeKind.original, filePath: path);
      if (count > 0) succeeded++;
    }
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

  Future<void> _addDemoPhotos() => _runBusy(_demoAssetsService.addAll);

  Future<void> _toggleFavorite(AssetRecord record) async {
    await assetRecordStore.setFavorite(record.localId, !record.isFavorite);
    await reload();
  }

  Future<void> _hide(AssetRecord record) async {
    await assetRecordStore.setHidden(record.localId, true);
    await reload();
  }

  Future<void> _softDelete(AssetRecord record) async {
    await assetRecordStore.softDelete(record.localId);
    await reload();
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

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final filtered = _filtered;

    return CupertinoPageScaffold(
      child: SafeArea(
        bottom: false,
        child: CustomScrollView(
          slivers: [
            CupertinoSliverNavigationBar(
              largeTitle: Text(l10n.tabLibrary),
              trailing: CupertinoButton(
                padding: EdgeInsets.zero,
                onPressed: _busy ? null : addFiles,
                child: _busy ? const CupertinoActivityIndicator() : const Icon(CupertinoIcons.add_circled),
              ),
            ),
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
              SliverToBoxAdapter(child: _SectionHeader(title: l10n.collectionsMediaTypes)),
              SliverToBoxAdapter(
                child: CupertinoListSection.insetGrouped(
                  margin: const EdgeInsets.symmetric(horizontal: 16),
                  children: [
                    _row(icon: CupertinoIcons.photo, color: CupertinoColors.systemGreen, title: l10n.collectionsPhotosRow, count: _photoCount),
                    _row(icon: CupertinoIcons.video_camera_solid, color: CupertinoColors.systemPurple, title: l10n.collectionsVideosRow, count: _videoCount),
                  ],
                ),
              ),
            ],
            SliverToBoxAdapter(child: _SectionHeader(title: l10n.collectionsUtilities)),
            SliverToBoxAdapter(
              child: CupertinoListSection.insetGrouped(
                margin: const EdgeInsets.symmetric(horizontal: 16),
                children: [
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
                    onTap: () => _push(HiddenScreen(assetRecordStore: assetRecordStore)),
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

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
      child: Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 22)),
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
