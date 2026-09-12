import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import 'add_s3_backup_screen.dart';
import 'backup_targets_store.dart';
import 's3_backup_target.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, this.store});

  final BackupTargetsStore? store;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final BackupTargetsStore _store = widget.store ?? BackupTargetsStore();

  List<S3BackupTarget>? _targets;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    List<S3BackupTarget> targets = const [];
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
    final added = await Navigator.of(
      context,
    ).push<bool>(MaterialPageRoute(builder: (_) => AddS3BackupScreen(store: _store)));
    if (added == true) {
      await _reload();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(AppLocalizations.of(context)!.settingsAddedMessage)));
    }
  }

  Future<void> _confirmDelete(S3BackupTarget target) async {
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
                  leading: const Icon(Icons.cloud_outlined),
                  title: Text(target.bucket),
                  subtitle: Text(target.prefix.isEmpty ? target.region : '${target.region} · ${target.prefix}'),
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
