import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import 'aws_settings.dart';
import 'aws_settings_store.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, this.store});

  final AwsSettingsStore? store;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final AwsSettingsStore _store = widget.store ?? AwsSettingsStore();
  final _formKey = GlobalKey<FormState>();

  final _accessKeyIdController = TextEditingController();
  final _secretAccessKeyController = TextEditingController();
  final _regionController = TextEditingController();
  final _bucketController = TextEditingController();
  final _prefixController = TextEditingController();

  S3StorageClass? _thumbnailStorageClass;
  S3StorageClass? _mediumStorageClass;
  S3StorageClass? _originalStorageClass;

  bool _loading = true;
  bool _obscureSecret = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    AwsSettings settings = const AwsSettings();
    try {
      settings = await _store.load();
    } catch (_) {
      // Secure storage unavailable/unreadable — fall back to empty settings
      // rather than leaving the screen spinning forever.
    }
    _accessKeyIdController.text = settings.accessKeyId;
    _secretAccessKeyController.text = settings.secretAccessKey;
    _regionController.text = settings.region;
    _bucketController.text = settings.bucket;
    _prefixController.text = settings.prefix;
    if (!mounted) return;
    setState(() {
      _thumbnailStorageClass = settings.thumbnailStorageClass;
      _mediumStorageClass = settings.mediumStorageClass;
      _originalStorageClass = settings.originalStorageClass;
      _loading = false;
    });
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    await _store.save(
      AwsSettings(
        accessKeyId: _accessKeyIdController.text.trim(),
        secretAccessKey: _secretAccessKeyController.text.trim(),
        region: _regionController.text.trim(),
        bucket: _bucketController.text.trim(),
        prefix: _prefixController.text.trim(),
        thumbnailStorageClass: _thumbnailStorageClass,
        mediumStorageClass: _mediumStorageClass,
        originalStorageClass: _originalStorageClass,
      ),
    );
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(AppLocalizations.of(context)!.settingsSavedMessage)));
  }

  @override
  void dispose() {
    _accessKeyIdController.dispose();
    _secretAccessKeyController.dispose();
    _regionController.dispose();
    _bucketController.dispose();
    _prefixController.dispose();
    super.dispose();
  }

  String? _required(AppLocalizations l10n, String? value) {
    return (value == null || value.trim().isEmpty) ? l10n.settingsRequiredFieldError : null;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.tabSettings)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Form(
              key: _formKey,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Text(l10n.settingsSectionTitle, style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _accessKeyIdController,
                    decoration: InputDecoration(labelText: l10n.settingsAccessKeyIdLabel),
                    validator: (v) => _required(l10n, v),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _secretAccessKeyController,
                    obscureText: _obscureSecret,
                    decoration: InputDecoration(
                      labelText: l10n.settingsSecretAccessKeyLabel,
                      suffixIcon: IconButton(
                        icon: Icon(_obscureSecret ? Icons.visibility_off : Icons.visibility),
                        onPressed: () => setState(() => _obscureSecret = !_obscureSecret),
                      ),
                    ),
                    validator: (v) => _required(l10n, v),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _regionController,
                    decoration: InputDecoration(labelText: l10n.settingsRegionLabel, hintText: 'us-east-1'),
                    validator: (v) => _required(l10n, v),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _bucketController,
                    decoration: InputDecoration(labelText: l10n.settingsBucketLabel),
                    validator: (v) => _required(l10n, v),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _prefixController,
                    decoration: InputDecoration(labelText: l10n.settingsPrefixLabel, hintText: 'photo-backup/'),
                  ),
                  const SizedBox(height: 24),
                  Text(l10n.settingsStorageClassSectionTitle, style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text(
                    l10n.settingsStorageClassSectionNote,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.grey),
                  ),
                  const SizedBox(height: 12),
                  _StorageClassPicker(
                    label: l10n.settingsThumbnailStorageClassLabel,
                    bucketDefaultLabel: l10n.settingsBucketDefaultOption,
                    value: _thumbnailStorageClass,
                    onChanged: (v) => setState(() => _thumbnailStorageClass = v),
                  ),
                  const SizedBox(height: 12),
                  _StorageClassPicker(
                    label: l10n.settingsMediumStorageClassLabel,
                    bucketDefaultLabel: l10n.settingsBucketDefaultOption,
                    value: _mediumStorageClass,
                    onChanged: (v) => setState(() => _mediumStorageClass = v),
                  ),
                  const SizedBox(height: 12),
                  _StorageClassPicker(
                    label: l10n.settingsOriginalStorageClassLabel,
                    bucketDefaultLabel: l10n.settingsBucketDefaultOption,
                    value: _originalStorageClass,
                    onChanged: (v) => setState(() => _originalStorageClass = v),
                  ),
                  const SizedBox(height: 24),
                  FilledButton(onPressed: _save, child: Text(l10n.settingsSaveButton)),
                ],
              ),
            ),
    );
  }
}

class _StorageClassPicker extends StatelessWidget {
  const _StorageClassPicker({
    required this.label,
    required this.bucketDefaultLabel,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final String bucketDefaultLabel;
  final S3StorageClass? value;
  final ValueChanged<S3StorageClass?> onChanged;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<S3StorageClass?>(
      initialValue: value,
      decoration: InputDecoration(labelText: label),
      items: [
        DropdownMenuItem(value: null, child: Text(bucketDefaultLabel)),
        for (final storageClass in S3StorageClass.values)
          DropdownMenuItem(value: storageClass, child: Text(storageClass.awsValue)),
      ],
      onChanged: onChanged,
    );
  }
}
