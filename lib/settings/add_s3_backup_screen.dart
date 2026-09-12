import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import 'backup_targets_store.dart';
import 's3_connectivity.dart';
import 's3_region_detection.dart';
import 's3_target_draft.dart';
import 's3_target_drafts_store.dart';

/// Default key prefix for a freshly added S3 target: the app's own folder,
/// so the user never has to think one up. Editable before saving.
const defaultS3Prefix = 'bring-your-own-photos/';

class AddS3BackupScreen extends StatefulWidget {
  const AddS3BackupScreen({
    super.key,
    required this.store,
    this.checkAccess = checkBucketAccess,
    this.detectRegion = detectBucketRegion,
    this.draftsStore,
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

  final S3TargetDraftsStore? draftsStore;

  @override
  State<AddS3BackupScreen> createState() => _AddS3BackupScreenState();
}

class _AddS3BackupScreenState extends State<AddS3BackupScreen> {
  late final S3TargetDraftsStore _draftsStore = widget.draftsStore ?? S3TargetDraftsStore();

  final _formKey = GlobalKey<FormState>();

  final _accessKeyIdController = TextEditingController();
  final _secretAccessKeyController = TextEditingController();
  final _bucketController = TextEditingController();
  final _prefixController = TextEditingController(text: defaultS3Prefix);

  bool _obscureSecret = true;
  bool _saving = false;
  String? _error;
  List<S3TargetDraft> _drafts = const [];

  @override
  void initState() {
    super.initState();
    _reloadDrafts();
  }

  @override
  void dispose() {
    _accessKeyIdController.dispose();
    _secretAccessKeyController.dispose();
    _bucketController.dispose();
    _prefixController.dispose();
    super.dispose();
  }

  Future<void> _reloadDrafts() async {
    List<S3TargetDraft> drafts = const [];
    try {
      drafts = await _draftsStore.loadAll();
    } catch (_) {
      // Secure storage unavailable/unreadable — show no drafts rather than
      // crashing the screen over what's just a convenience feature.
    }
    if (!mounted) return;
    setState(() => _drafts = drafts);
  }

  void _fillFromDraft(S3TargetDraft draft) {
    _accessKeyIdController.text = draft.accessKeyId;
    _secretAccessKeyController.text = draft.secretAccessKey;
    _bucketController.text = draft.bucket;
    _prefixController.text = draft.prefix;
  }

  Future<void> _deleteDraft(S3TargetDraft draft) async {
    await _draftsStore.remove(draft.id);
    await _reloadDrafts();
  }

  String _maskedAccessKeyId(String accessKeyId) {
    if (accessKeyId.length <= 8) return accessKeyId;
    return '${accessKeyId.substring(0, 4)}…${accessKeyId.substring(accessKeyId.length - 4)}';
  }

  String? _required(AppLocalizations l10n, String? value) {
    return (value == null || value.trim().isEmpty) ? l10n.settingsRequiredFieldError : null;
  }

  String _messageFor(AppLocalizations l10n, S3AccessCheckResult result) {
    final base = switch (result.outcome) {
      S3AccessCheckOutcome.forbidden => l10n.settingsAccessCheckForbidden,
      S3AccessCheckOutcome.notFound => l10n.settingsAccessCheckNotFound,
      S3AccessCheckOutcome.networkError => l10n.settingsAccessCheckNetworkError,
      S3AccessCheckOutcome.ok => '',
    };
    // Surface AWS's own error code (InvalidAccessKeyId, SignatureDoesNotMatch,
    // AccessDenied, ...) — each points at a different field to fix.
    final detail = result.detail;
    return detail == null ? base : '$base ($detail)';
  }

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context)!;

    final accessKeyId = _accessKeyIdController.text.trim();
    final secretAccessKey = _secretAccessKeyController.text.trim();
    final bucket = _bucketController.text.trim();
    final prefix = _prefixController.text.trim();

    // Save a draft of this attempt before validating — so even a failed or
    // abandoned save doesn't mean retyping everything next time. Best-effort:
    // a secure-storage hiccup here shouldn't block the actual save attempt.
    if (accessKeyId.isNotEmpty || secretAccessKey.isNotEmpty || bucket.isNotEmpty) {
      try {
        await _draftsStore.save(accessKeyId: accessKeyId, secretAccessKey: secretAccessKey, bucket: bucket, prefix: prefix);
      } catch (_) {
        // Ignored — see above.
      }
      await _reloadDrafts();
    }

    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _saving = true;
      _error = null;
    });

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
        _error = _messageFor(l10n, result);
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
    await _draftsStore.removeMatching(accessKeyId: accessKeyId, bucket: bucket);

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
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(labelText: l10n.settingsAccessKeyIdLabel),
              validator: (v) => _required(l10n, v),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _secretAccessKeyController,
              enabled: !_saving,
              obscureText: _obscureSecret,
              autocorrect: false,
              enableSuggestions: false,
              smartDashesType: SmartDashesType.disabled,
              smartQuotesType: SmartQuotesType.disabled,
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
              autocorrect: false,
              enableSuggestions: false,
              smartDashesType: SmartDashesType.disabled,
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
            if (_drafts.isNotEmpty) ...[
              const SizedBox(height: 32),
              const Divider(),
              const SizedBox(height: 8),
              Text(l10n.settingsDraftsTitle, style: Theme.of(context).textTheme.titleSmall),
              for (final draft in _drafts)
                InkWell(
                  onTap: _saving ? null : () => _fillFromDraft(draft),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(draft.bucket.isEmpty ? l10n.settingsDraftUntitled : draft.bucket),
                              if (draft.accessKeyId.isNotEmpty)
                                Text(
                                  _maskedAccessKeyId(draft.accessKeyId),
                                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.grey),
                                ),
                            ],
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close, size: 18),
                          color: Colors.grey,
                          tooltip: l10n.settingsDraftDeleteTooltip,
                          onPressed: _saving ? null : () => _deleteDraft(draft),
                        ),
                      ],
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
