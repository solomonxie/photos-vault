import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import 'add_local_folder_screen.dart';
import 'add_s3_backup_screen.dart';
import 'backup_target.dart';
import 'backup_targets_store.dart';
import 'folder_picker.dart';
import 'local_folder_connectivity.dart';
import 'security_scoped_bookmark.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    this.store,
    this.folderPicker = const NativeFolderPicker(),
    this.bookmarkResolver = const PlatformSecurityScopedBookmarkResolver(),
  });

  final BackupTargetsStore? store;
  final FolderPicker folderPicker;

  /// Overridable for tests so re-pick recovery never touches the real
  /// platform channel.
  final SecurityScopedBookmarkResolver bookmarkResolver;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final BackupTargetsStore _store = widget.store ?? BackupTargetsStore();

  List<BackupTarget>? _targets;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    List<BackupTarget> targets = const [];
    try {
      targets = await _store.loadAll();
    } catch (_) {
      // Secure storage unavailable/unreadable — show an empty list rather
      // than spinning forever.
    }
    if (!mounted) return;
    setState(() => _targets = targets);
  }

  Future<void> _addBackup() async {
    final l10n = AppLocalizations.of(context)!;
    final choice = await showModalBottomSheet<_AddChoice>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.cloud_outlined),
              title: Text(l10n.settingsAddS3Option),
              onTap: () => Navigator.of(context).pop(_AddChoice.s3),
            ),
            ListTile(
              leading: const Icon(Icons.folder_outlined),
              title: Text(l10n.settingsAddLocalFolderOption),
              onTap: () => Navigator.of(context).pop(_AddChoice.localFolder),
            ),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;

    final added = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => switch (choice) {
          _AddChoice.s3 => AddS3BackupScreen(store: _store),
          _AddChoice.localFolder => AddLocalFolderScreen(store: _store, folderPicker: widget.folderPicker),
        },
      ),
    );
    if (added == true) {
      await _reload();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(AppLocalizations.of(context)!.settingsAddedMessage)));
    }
  }

  /// T1.8: tapping a local-folder target does a quick resolve so a stale
  /// bookmark (folder moved/renamed/deleted, or access revoked) surfaces a
  /// re-pick prompt instead of failing silently at the next backup.
  Future<void> _checkLocalFolder(LocalFolderBackupTarget target) async {
    final resolvedPath = await widget.bookmarkResolver.resolveAndStartAccess(target.bookmarkData);
    if (resolvedPath != null) {
      await widget.bookmarkResolver.stopAccess(resolvedPath);
      return;
    }
    if (!mounted) return;
    await _promptRepick(target);
  }

  Future<void> _promptRepick(LocalFolderBackupTarget target) async {
    final l10n = AppLocalizations.of(context)!;
    final shouldRepick = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.settingsLocalFolderStaleTitle),
        content: Text(l10n.settingsLocalFolderStaleBody),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(l10n.actionCancel)),
          TextButton(onPressed: () => Navigator.of(context).pop(true), child: Text(l10n.settingsLocalFolderRepickButton)),
        ],
      ),
    );
    if (shouldRepick != true || !mounted) return;

    final path = await widget.folderPicker.pickFolder();
    if (path == null || !mounted) return;

    final result = await checkFolderAccess(path: path, resolver: widget.bookmarkResolver);
    if (!result.isOk) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(AppLocalizations.of(context)!.settingsLocalFolderAccessError)));
      return;
    }

    await _store.updateLocalFolderBookmark(target.id, result.bookmarkData!);
    await _reload();
  }

  Future<void> _confirmDelete(BackupTarget target) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.settingsDeleteConfirmTitle),
        content: Text(l10n.settingsDeleteConfirmBody),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(l10n.actionCancel)),
          TextButton(onPressed: () => Navigator.of(context).pop(true), child: Text(l10n.actionDelete)),
        ],
      ),
    );
    if (confirmed == true) {
      await _store.remove(target.id);
      await _reload();
    }
  }

  IconData _iconFor(BackupTarget target) => switch (target) {
    S3BackupTarget() => Icons.cloud_outlined,
    LocalFolderBackupTarget() => Icons.folder_outlined,
  };

  String _titleFor(BackupTarget target) => switch (target) {
    S3BackupTarget(:final bucket) => bucket,
    LocalFolderBackupTarget(:final displayName) => displayName,
  };

  String _subtitleFor(BackupTarget target) => switch (target) {
    S3BackupTarget(:final region, :final prefix) => prefix.isEmpty ? region : '$region · $prefix',
    LocalFolderBackupTarget(:final prefix) => prefix,
  };

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final targets = _targets;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.tabSettings),
        actions: [IconButton(icon: const Icon(Icons.add), onPressed: _addBackup, tooltip: l10n.settingsAddButton)],
      ),
      body: targets == null
          ? const Center(child: CircularProgressIndicator())
          : targets.isEmpty
          ? _EmptyState(onAdd: _addBackup)
          : ListView.builder(
              itemCount: targets.length,
              itemBuilder: (context, index) {
                final target = targets[index];
                return ListTile(
                  leading: Icon(_iconFor(target)),
                  title: Text(_titleFor(target)),
                  subtitle: Text(_subtitleFor(target)),
                  onTap: switch (target) {
                    LocalFolderBackupTarget() => () => _checkLocalFolder(target),
                    S3BackupTarget() => null,
                  },
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => _confirmDelete(target),
                  ),
                );
              },
            ),
    );
  }
}

enum _AddChoice { s3, localFolder }

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onAdd});

  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_outlined, size: 48, color: Colors.grey),
            const SizedBox(height: 12),
            Text(l10n.settingsEmptyTitle, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(
              l10n.settingsEmptyNote,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Colors.grey),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onAdd,
              icon: const Icon(Icons.add),
              label: Text(l10n.settingsAddButton),
            ),
          ],
        ),
      ),
    );
  }
}
