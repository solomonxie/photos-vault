import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../photos/demo_assets_service.dart';
import '../photos/manual_add.dart';
import '../settings/backup_targets_store.dart';
import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import '../upload/backup_coordinator.dart';
import '../widgets/placeholder_screen.dart';

/// The photo grid lands in T4.1; until then this tab is also the entry
/// point for the manual add flow (T2.5) — pick files from the Files app /
/// iCloud Drive and immediately back them up, useful for testing the
/// upload pipeline without a camera roll. "Try with Demo Photos" seeds a
/// few tiny bundled assets for the same reason, with zero setup.
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
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  late final AssetRecordStore _assetRecordStore = widget.assetRecordStore ?? AssetRecordStore();
  late final BackupTargetsStore _backupTargetsStore = widget.backupTargetsStore ?? BackupTargetsStore();
  late final ManualAddService _manualAddService =
      widget.manualAddService ?? ManualAddService(store: _assetRecordStore);
  late final DemoAssetsService _demoAssetsService =
      widget.demoAssetsService ?? DemoAssetsService(manualAddService: _manualAddService);
  late final BackupCoordinator _coordinator =
      widget.backupCoordinator ?? BackupCoordinator(targetsStore: _backupTargetsStore, recordStore: _assetRecordStore);

  List<AssetRecord> _manuallyAdded = [];
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final all = await _assetRecordStore.listAll();
    if (!mounted) return;
    setState(() => _manuallyAdded = all.where((r) => r.sourceType == AssetSourceType.manualFile).toList());
  }

  Future<void> _backUpAndReport(List<AssetRecord> records) async {
    var succeeded = 0;
    for (final record in records) {
      final path = record.sourcePath;
      if (path == null) continue;
      final count = await _coordinator.backUpDerivative(record: record, kind: DerivativeKind.original, filePath: path);
      if (count > 0) succeeded++;
    }
    await _reload();
    if (!mounted) return;
    final l10n = AppLocalizations.of(context)!;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(l10n.libraryAddFilesResult(records.length, succeeded))),
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

  Future<void> _addFiles() => _runBusy(_manualAddService.pickAndEnqueue);

  Future<void> _addDemoPhotos() => _runBusy(_demoAssetsService.addAll);

  Future<void> _deleteRecord(AssetRecord record) async {
    await _assetRecordStore.remove(record.localId);
    await _reload();
  }

  String _statusLabel(AppLocalizations l10n, AssetRecord record) {
    final status = record.stateOf(DerivativeKind.original).status;
    return switch (status) {
      UploadStatus.pending => l10n.libraryStatusPending,
      UploadStatus.uploading => l10n.libraryStatusUploading,
      UploadStatus.uploaded => l10n.libraryStatusUploaded,
      UploadStatus.failed => l10n.libraryStatusFailed,
    };
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.tabLibrary),
        actions: [
          IconButton(
            icon: _busy
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.add),
            tooltip: l10n.libraryAddFilesButton,
            onPressed: _busy ? null : _addFiles,
          ),
        ],
      ),
      body: _manuallyAdded.isEmpty
          ? Column(
              children: [
                Expanded(
                  child: PlaceholderScreen(
                    icon: Icons.photo_library_outlined,
                    title: l10n.libraryEmptyTitle,
                    note: l10n.libraryEmptyNote,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                  child: OutlinedButton.icon(
                    onPressed: _busy ? null : _addDemoPhotos,
                    icon: const Icon(Icons.auto_awesome_outlined),
                    label: Text(l10n.libraryAddDemoButton),
                  ),
                ),
              ],
            )
          : ListView.builder(
              itemCount: _manuallyAdded.length,
              itemBuilder: (context, index) {
                final record = _manuallyAdded[index];
                return ListTile(
                  leading: const Icon(Icons.insert_drive_file_outlined),
                  title: Text(record.sourcePath?.split('/').last ?? record.localId),
                  subtitle: Text(_statusLabel(l10n, record)),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline),
                    tooltip: l10n.libraryDeleteTooltip,
                    onPressed: () => _deleteRecord(record),
                  ),
                );
              },
            ),
    );
  }
}
