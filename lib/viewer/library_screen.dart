import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../photos/demo_assets_service.dart';
import '../photos/manual_add.dart';
import '../settings/backup_targets_store.dart';
import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import '../upload/backup_coordinator.dart';
import 'detail_screen.dart';

/// Photos-app-style grid: square tiles grouped under day headers, newest
/// first. The real camera-roll grid (T4.1, needs `photo_manager`) isn't
/// built yet — this lists manually-added/demo files, which is also the
/// entry point for the manual add flow (T2.5) and "Try with Demo Photos".
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

  List<AssetRecord> _manuallyAdded = [];
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
    setState(
      () => _manuallyAdded = all.where((r) => r.sourceType == AssetSourceType.manualFile).toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt)),
    );
  }

  List<AssetRecord> get _filtered => _query.isEmpty
      ? _manuallyAdded
      : _manuallyAdded
            .where((r) => (r.sourcePath ?? r.localId).toLowerCase().contains(_query.toLowerCase()))
            .toList();

  String _dayLabel(AppLocalizations l10n, DateTime dt) {
    final now = DateTime.now();
    final date = DateTime(dt.year, dt.month, dt.day);
    final today = DateTime(now.year, now.month, now.day);
    final diff = today.difference(date).inDays;
    if (diff == 0) return l10n.libraryToday;
    if (diff == 1) return l10n.libraryYesterday;
    return DateFormat.yMMMd().format(dt);
  }

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
    _showToast(l10n.libraryAddFilesResult(records.length, succeeded));
  }

  void _showToast(String message) {
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

  Future<void> _deleteRecord(AssetRecord record) async {
    await assetRecordStore.remove(record.localId);
    await reload();
  }

  void _openRecord(AssetRecord record) {
    final records = _filtered;
    Navigator.of(context).push(
      CupertinoPageRoute(
        builder: (_) => DetailScreen(
          records: records,
          initialIndex: records.indexOf(record),
          onDelete: _deleteRecord,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final filtered = _filtered;

    final grouped = <String, List<AssetRecord>>{};
    for (final r in filtered) {
      grouped.putIfAbsent(_dayLabel(l10n, r.createdAt), () => []).add(r);
    }

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
                child: _busy
                    ? const CupertinoActivityIndicator()
                    : const Icon(CupertinoIcons.add_circled),
              ),
            ),
            if (_manuallyAdded.isNotEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: CupertinoSearchTextField(onChanged: (v) => setState(() => _query = v)),
                ),
              ),
            if (_manuallyAdded.isEmpty)
              SliverFillRemaining(hasScrollBody: false, child: _EmptyState(busy: _busy, onAddDemo: _addDemoPhotos, onAddFiles: addFiles))
            else
              for (final entry in grouped.entries) ...[
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                    child: Text(entry.key, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 20)),
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
                      (context, i) => _Tile(
                        key: ValueKey(entry.value[i].localId),
                        record: entry.value[i],
                        onTap: () => _openRecord(entry.value[i]),
                        onDelete: () => _deleteRecord(entry.value[i]),
                      ),
                      childCount: entry.value.length,
                    ),
                  ),
                ),
              ],
          ],
        ),
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({super.key, required this.record, required this.onTap, required this.onDelete});

  final AssetRecord record;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final path = record.sourcePath;
    final video = path != null && isVideoPath(path);

    return CupertinoContextMenu(
      actions: [
        CupertinoContextMenuAction(
          isDestructiveAction: true,
          trailingIcon: CupertinoIcons.delete,
          onPressed: () {
            Navigator.of(context).pop();
            onDelete();
          },
          child: Text(l10n.libraryDeleteTooltip),
        ),
      ],
      child: GestureDetector(
        onTap: onTap,
        child: AspectRatio(
          aspectRatio: 1,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (video)
                const ColoredBox(
                  color: CupertinoColors.darkBackgroundGray,
                  child: Icon(CupertinoIcons.play_circle_fill, color: CupertinoColors.white, size: 28),
                )
              else if (path != null)
                Image.file(
                  File(path),
                  fit: BoxFit.cover,
                  errorBuilder: (context, error, stackTrace) =>
                      const ColoredBox(color: CupertinoColors.systemGrey5, child: Icon(CupertinoIcons.photo)),
                )
              else
                const ColoredBox(color: CupertinoColors.systemGrey5, child: Icon(CupertinoIcons.photo)),
              if (video) const Positioned(top: 4, right: 4, child: Icon(CupertinoIcons.video_camera_solid, size: 14, color: CupertinoColors.white)),
              Positioned(bottom: 4, right: 4, child: _StatusDot(record: record)),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.record});

  final AssetRecord record;

  @override
  Widget build(BuildContext context) {
    final status = record.stateOf(DerivativeKind.original).status;
    final (icon, color) = switch (status) {
      UploadStatus.pending => (CupertinoIcons.clock, CupertinoColors.systemGrey),
      UploadStatus.uploading => (CupertinoIcons.cloud_upload, CupertinoColors.systemBlue),
      UploadStatus.uploaded => (CupertinoIcons.checkmark_circle_fill, CupertinoColors.systemGreen),
      UploadStatus.failed => (CupertinoIcons.exclamationmark_circle_fill, CupertinoColors.systemRed),
    };
    return Icon(icon, size: 14, color: color);
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
            CupertinoButton.filled(
              onPressed: busy ? null : onAddDemo,
              child: Text(l10n.libraryAddDemoButton),
            ),
            CupertinoButton(onPressed: busy ? null : onAddFiles, child: Text(l10n.libraryAddFilesButton)),
          ],
        ),
      ),
    );
  }
}
