import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import 'backup_targets_store.dart';
import 'folder_picker.dart';
import 'local_folder_connectivity.dart';

class AddLocalFolderScreen extends StatefulWidget {
  const AddLocalFolderScreen({
    super.key,
    required this.store,
    this.folderPicker = const NativeFolderPicker(),
    this.checkAccess = checkFolderAccess,
  });

  final BackupTargetsStore store;
  final FolderPicker folderPicker;

  /// Overridable for tests so they never touch the real security-scoped
  /// bookmark platform channel.
  final Future<LocalFolderAccessCheckResult> Function({required String path}) checkAccess;

  @override
  State<AddLocalFolderScreen> createState() => _AddLocalFolderScreenState();
}

class _AddLocalFolderScreenState extends State<AddLocalFolderScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _prefixController = TextEditingController();

  String? _pickedPath;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _nameController.dispose();
    _prefixController.dispose();
    super.dispose();
  }

  String? _required(AppLocalizations l10n, String? value) {
    return (value == null || value.trim().isEmpty) ? l10n.settingsRequiredFieldError : null;
  }

  Future<void> _pickFolder() async {
    final path = await widget.folderPicker.pickFolder();
    if (path == null) return;
    setState(() {
      _pickedPath = path;
      if (_nameController.text.trim().isEmpty) {
        _nameController.text = path.split('/').where((s) => s.isNotEmpty).lastOrNull ?? path;
      }
    });
  }

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context)!;
    if (!_formKey.currentState!.validate()) return;
    final path = _pickedPath;
    if (path == null) {
      setState(() => _error = l10n.settingsLocalFolderRequiredError);
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });

    final result = await widget.checkAccess(path: path);

    if (!mounted) return;

    if (!result.isOk) {
      setState(() {
        _saving = false;
        _error = l10n.settingsLocalFolderAccessError;
      });
      return;
    }

    await widget.store.addLocalFolder(
      displayName: _nameController.text.trim(),
      bookmarkData: result.bookmarkData!,
      prefix: _prefixController.text.trim(),
    );

    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.settingsAddLocalFolderTitle)),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              controller: _nameController,
              enabled: !_saving,
              decoration: InputDecoration(labelText: l10n.settingsLocalFolderNameLabel),
              validator: (v) => _required(l10n, v),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _prefixController,
              enabled: !_saving,
              decoration: InputDecoration(labelText: l10n.settingsPrefixLabel, hintText: 'photo-backup/'),
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: _saving ? null : _pickFolder,
              icon: const Icon(Icons.folder_open_outlined),
              label: Text(l10n.settingsLocalFolderPickButton),
            ),
            const SizedBox(height: 8),
            Text(
              _pickedPath ?? l10n.settingsLocalFolderNoneChosen,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Colors.grey),
            ),
            if (_error != null) ...[
              const SizedBox(height: 16),
              Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _saving ? null : _save,
              child: _saving
                  ? Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        const SizedBox(width: 12),
                        Text(l10n.settingsLocalFolderValidatingMessage),
                      ],
                    )
                  : Text(l10n.settingsSaveButton),
            ),
          ],
        ),
      ),
    );
  }
}
