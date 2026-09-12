import 'package:flutter/cupertino.dart';

import '../l10n/app_localizations.dart';
import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';

/// Lightweight stand-in for T4.3's full dashboard (queued/uploading/done/
/// failed counts, storage used per tier) — real per-derivative counts from
/// `asset_record`, just not the storage-used breakdown yet.
class BackupScreen extends StatefulWidget {
  const BackupScreen({super.key, this.assetRecordStore});

  final AssetRecordStore? assetRecordStore;

  @override
  State<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends State<BackupScreen> {
  late final AssetRecordStore _store = widget.assetRecordStore ?? AssetRecordStore();

  List<AssetRecord> _records = const [];

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final all = await _store.listAll();
    if (!mounted) return;
    setState(() => _records = all);
  }

  int _countOf(UploadStatus status) =>
      _records.where((r) => r.stateOf(DerivativeKind.original).status == status).length;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(middle: Text(l10n.tabBackup)),
      child: SafeArea(
        child: _records.isEmpty
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(CupertinoIcons.cloud_upload, size: 48, color: CupertinoColors.systemGrey),
                      const SizedBox(height: 12),
                      Text(l10n.backupEmptyTitle, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 4),
                      Text(
                        l10n.backupEmptyNote,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: CupertinoColors.systemGrey),
                      ),
                    ],
                  ),
                ),
              )
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  CupertinoListSection.insetGrouped(
                    header: Text(l10n.backupStatusSectionHeader),
                    children: [
                      _statusTile(l10n.libraryStatusPending, _countOf(UploadStatus.pending), CupertinoColors.systemGrey),
                      _statusTile(l10n.libraryStatusUploading, _countOf(UploadStatus.uploading), CupertinoColors.systemBlue),
                      _statusTile(l10n.libraryStatusUploaded, _countOf(UploadStatus.uploaded), CupertinoColors.systemGreen),
                      _statusTile(l10n.libraryStatusFailed, _countOf(UploadStatus.failed), CupertinoColors.systemRed),
                    ],
                  ),
                ],
              ),
      ),
    );
  }

  CupertinoListTile _statusTile(String label, int count, Color color) {
    return CupertinoListTile(
      leading: Icon(CupertinoIcons.circle_fill, size: 12, color: color),
      title: Text(label),
      trailing: Text('$count', style: const TextStyle(color: CupertinoColors.systemGrey)),
    );
  }
}
