import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import 'backup_targets_store.dart';
import 's3_connectivity.dart';
import 's3_region_detection.dart';

/// Default key prefix for a freshly added S3 target: the app's own folder,
/// so the user never has to think one up. Editable before saving.
const defaultS3Prefix = 'back-your-own-photos/';

class AddS3BackupScreen extends StatefulWidget {
  const AddS3BackupScreen({
    super.key,
    required this.store,
    this.checkAccess = checkBucketAccess,
    this.detectRegion = detectBucketRegion,
  });

  final BackupTargetsStore store;

  /// Overridable for tests so they never make a real network call.
  final Future<S3AccessCheckResult> Function({
    required String accessKeyId,
    required String secretAccessKey,
    required String region,
    required String bucket,
  })
  checkAccess;

  /// Overridable for tests so they never make a real network call. Region
  /// is auto-detected from the bucket name — the user never types it.
  final Future<S3RegionDetectionResult> Function(String bucket) detectRegion;

  @override
  State<AddS3BackupScreen> createState() => _AddS3BackupScreenState();
}

class _AddS3BackupScreenState extends State<AddS3BackupScreen> {
  final _formKey = GlobalKey<FormState>();

  final _accessKeyIdController = TextEditingController();
  final _secretAccessKeyController = TextEditingController();
  final _bucketController = TextEditingController();
  final _prefixController = TextEditingController(text: defaultS3Prefix);

  bool _obscureSecret = true;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _accessKeyIdController.dispose();
    _secretAccessKeyController.dispose();
    _bucketController.dispose();
    _prefixController.dispose();
    super.dispose();
  }

  String? _required(AppLocalizations l10n, String? value) {
    return (value == null || value.trim().isEmpty) ? l10n.settingsRequiredFieldError : null;
  }

  String _messageFor(AppLocalizations l10n, S3AccessCheckOutcome outcome) {
    switch (outcome) {
      case S3AccessCheckOutcome.forbidden:
        return l10n.settingsAccessCheckForbidden;
      case S3AccessCheckOutcome.notFound:
        return l10n.settingsAccessCheckNotFound;
      case S3AccessCheckOutcome.networkError:
        return l10n.settingsAccessCheckNetworkError;
      case S3AccessCheckOutcome.ok:
        return '';
    }
  }

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context)!;
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _saving = true;
      _error = null;
    });

    final accessKeyId = _accessKeyIdController.text.trim();
    final secretAccessKey = _secretAccessKeyController.text.trim();
    final bucket = _bucketController.text.trim();
    final prefix = _prefixController.text.trim();

    final regionResult = await widget.detectRegion(bucket);
    if (!mounted) return;
    if (!regionResult.isOk) {
      setState(() {
        _saving = false;
        _error = regionResult.outcome == S3RegionDetectionOutcome.notFound
            ? l10n.settingsAccessCheckNotFound
            : l10n.settingsRegionDetectionError;
      });
      return;
    }
    final region = regionResult.region!;

    final result = await widget.checkAccess(
      accessKeyId: accessKeyId,
      secretAccessKey: secretAccessKey,
      region: region,
      bucket: bucket,
    );

    if (!mounted) return;

    if (!result.isOk) {
      setState(() {
        _saving = false;
        _error = _messageFor(l10n, result.outcome);
      });
      return;
    }

    await widget.store.addS3(
      accessKeyId: accessKeyId,
      secretAccessKey: secretAccessKey,
      region: region,
      bucket: bucket,
      prefix: prefix,
    );

    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.settingsAddButton)),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              controller: _accessKeyIdController,
              enabled: !_saving,
              decoration: InputDecoration(labelText: l10n.settingsAccessKeyIdLabel),
              validator: (v) => _required(l10n, v),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _secretAccessKeyController,
              enabled: !_saving,
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
              controller: _bucketController,
              enabled: !_saving,
              decoration: InputDecoration(labelText: l10n.settingsBucketLabel),
              validator: (v) => _required(l10n, v),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _prefixController,
              enabled: !_saving,
              decoration: InputDecoration(labelText: l10n.settingsPrefixLabel, hintText: 'photo-backup/'),
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
                        Text(l10n.settingsValidatingMessage),
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
