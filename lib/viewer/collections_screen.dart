import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../settings/backup_targets_store.dart';
import '../settings/settings_screen.dart';
import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import 'backup_screen.dart';
import 'detail_screen.dart';

/// Photos app's "Collections" tab: a scrollable dashboard of sections
/// (Recently Added, Media Types, Utilities) rather than a flat list —
/// matches the real app's grouped-list ("insetGrouped") visual language.
/// No Albums/People & Pets section: those need data (albums, face
/// recognition) this app has no concept of.
class CollectionsScreen extends StatefulWidget {
  const CollectionsScreen({super.key, this.assetRecordStore, this.backupTargetsStore});

  final AssetRecordStore? assetRecordStore;
  final BackupTargetsStore? backupTargetsStore;

  @override
  State<CollectionsScreen> createState() => CollectionsScreenState();
}

class CollectionsScreenState extends State<CollectionsScreen> {
  late final AssetRecordStore _assetRecordStore = widget.assetRecordStore ?? AssetRecordStore();
  late final BackupTargetsStore _backupTargetsStore = widget.backupTargetsStore ?? BackupTargetsStore();

  List<AssetRecord> _records = const [];

  @override
  void initState() {
    super.initState();
    reload();
  }

  Future<void> reload() async {
    final all = await _assetRecordStore.listAll();
    if (!mounted) return;
    setState(() => _records = all..sort((a, b) => b.createdAt.compareTo(a.createdAt)));
  }

  bool _isVideo(AssetRecord r) => r.sourcePath != null && isVideoPath(r.sourcePath!);

  int get _photoCount => _records.where((r) => !_isVideo(r)).length;
  int get _videoCount => _records.where(_isVideo).length;
  int get _pendingCount =>
      _records.where((r) => r.stateOf(DerivativeKind.original).status != UploadStatus.uploaded).length;

  Future<void> _openBackupStatus() async {
    await Navigator.of(context).push(
      CupertinoPageRoute(builder: (_) => BackupScreen(assetRecordStore: _assetRecordStore)),
    );
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push(
      CupertinoPageRoute(builder: (_) => SettingsScreen(store: _backupTargetsStore)),
    );
    await reload();
  }

  void _openRecord(AssetRecord record) {
    Navigator.of(context).push(
      CupertinoPageRoute(
        builder: (_) => DetailScreen(
          records: _records,
          initialIndex: _records.indexOf(record),
          onDelete: (r) async {
            await _assetRecordStore.remove(r.localId);
            await reload();
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return CupertinoPageScaffold(
      child: SafeArea(
        child: CustomScrollView(
          slivers: [
            CupertinoSliverNavigationBar(largeTitle: Text(l10n.tabCollections)),
            if (_records.isNotEmpty) ...[
              SliverToBoxAdapter(child: _SectionHeader(title: l10n.collectionsRecentlyAdded)),
              SliverToBoxAdapter(
                child: _RecentlyAddedRow(records: _records.take(10).toList(), onTap: _openRecord),
              ),
              SliverToBoxAdapter(child: _SectionHeader(title: l10n.collectionsMediaTypes)),
              SliverToBoxAdapter(
                child: CupertinoListSection.insetGrouped(
                  margin: const EdgeInsets.symmetric(horizontal: 16),
                  children: [
                    _row(
                      icon: CupertinoIcons.photo,
                      color: CupertinoColors.systemGreen,
                      title: l10n.collectionsPhotosRow,
                      count: _photoCount,
                    ),
                    _row(
                      icon: CupertinoIcons.video_camera_solid,
                      color: CupertinoColors.systemPurple,
                      title: l10n.collectionsVideosRow,
                      count: _videoCount,
                    ),
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
                    icon: CupertinoIcons.cloud_upload_fill,
                    color: CupertinoColors.systemBlue,
                    title: l10n.collectionsBackupStatusRow,
                    count: _pendingCount,
                    onTap: _openBackupStatus,
                  ),
                  _row(
                    icon: CupertinoIcons.gear_alt_fill,
                    color: CupertinoColors.systemGrey,
                    title: l10n.collectionsSettingsRow,
                    onTap: _openSettings,
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

class _RecentlyAddedRow extends StatelessWidget {
  const _RecentlyAddedRow({required this.records, required this.onTap});

  final List<AssetRecord> records;
  final ValueChanged<AssetRecord> onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 140,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: records.length,
        separatorBuilder: (context, index) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final record = records[i];
          final path = record.sourcePath;
          return GestureDetector(
            onTap: () => onTap(record),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: SizedBox(
                width: 120,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (path != null && !isVideoPath(path))
                      Image.file(
                        File(path),
                        fit: BoxFit.cover,
                        errorBuilder: (context, error, stackTrace) =>
                            const ColoredBox(color: CupertinoColors.systemGrey5),
                      )
                    else
                      const ColoredBox(
                        color: CupertinoColors.darkBackgroundGray,
                        child: Icon(CupertinoIcons.play_circle_fill, color: CupertinoColors.white),
                      ),
                    Positioned(
                      left: 8,
                      bottom: 8,
                      child: Text(
                        DateFormat.MMMd().format(record.createdAt),
                        style: const TextStyle(
                          color: CupertinoColors.white,
                          fontWeight: FontWeight.w600,
                          shadows: [Shadow(blurRadius: 4, color: CupertinoColors.black)],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
