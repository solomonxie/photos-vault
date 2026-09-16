import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/app_localizations.dart';
import 'backup_storage_type.dart';
import 'backup_targets_store.dart';
import 's3_connectivity.dart';
import 's3_credentials_text.dart';
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
  late final S3TargetDraftsStore _draftsStore =
      widget.draftsStore ?? S3TargetDraftsStore();

  final _formKey = GlobalKey<FormState>();

  final _accessKeyIdController = TextEditingController();
  final _secretAccessKeyController = TextEditingController();
  final _bucketController = TextEditingController();
  final _prefixController = TextEditingController(text: defaultS3Prefix);
  final _pasteController = TextEditingController();

  /// While true the four fields are swapped out for the paste box — a mode
  /// of the same group, not a second input sitting above them.
  bool _pasteMode = false;

  /// Length of the paste box's text as of the last change, to tell a real
  /// paste (one multi-character insert) from someone typing a block out.
  int _pasteLength = 0;

  bool _obscureSecret = true;
  bool _saving = false;
  String? _error;
  List<S3TargetDraft> _drafts = const [];

  @override
  void initState() {
    super.initState();
    _reloadDrafts();
    // Live length check: AWS access key IDs are always 20 characters, secret
    // keys always 40 — a paste that picked up an extra/missing/invisible
    // character (common cause of a SignatureDoesNotMatch) shows up
    // immediately, before Save even runs a network call.
    _accessKeyIdController.addListener(_onCredentialFieldChanged);
    _secretAccessKeyController.addListener(_onCredentialFieldChanged);
  }

  void _onCredentialFieldChanged() => setState(() {});

  @override
  void dispose() {
    _accessKeyIdController.removeListener(_onCredentialFieldChanged);
    _secretAccessKeyController.removeListener(_onCredentialFieldChanged);
    _accessKeyIdController.dispose();
    _secretAccessKeyController.dispose();
    _bucketController.dispose();
    _prefixController.dispose();
    _pasteController.dispose();
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

  /// Swaps the fields for the paste box and back. The buffer is cleared on
  /// the way in *and* out — a pasted secret shouldn't sit on screen, or in
  /// state, once it has landed in the fields.
  void _togglePasteMode() {
    setState(() {
      _pasteMode = !_pasteMode;
      _pasteController.clear();
      _pasteLength = 0;
    });
  }

  /// Parses on every change rather than behind an "Apply" button — and on a
  /// real paste snaps straight back to the fields, because seeing the four
  /// of them filled is the confirmation. Typing a block out by hand keeps
  /// the box open, or it would close on the second line.
  void _onPastedTextChanged(String text) {
    final inserted = text.length - _pasteLength;
    _pasteLength = text.length;
    final parsed = S3CredentialsText.parse(text);
    setState(() {
      if (parsed.accessKeyId != null) {
        _accessKeyIdController.text = parsed.accessKeyId!;
      }
      if (parsed.secretAccessKey != null) {
        _secretAccessKeyController.text = parsed.secretAccessKey!;
      }
      if (parsed.bucket != null) _bucketController.text = parsed.bucket!;
      // An absent prefix leaves the default in place rather than blanking it.
      if (parsed.prefix != null) _prefixController.text = parsed.prefix!;

      if (inserted > 1 && !parsed.isEmpty) {
        _pasteMode = false;
        _pasteController.clear();
        _pasteLength = 0;
      }
    });
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty) return;
    _pasteController.text = text;
    _onPastedTextChanged(text);
  }

  Widget _groupHeader(AppLocalizations l10n) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Row(
      children: [
        Text(
          l10n.settingsPasteGroupTitle,
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(width: 6),
        InkWell(
          onTap: _saving ? null : _togglePasteMode,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
            child: Text(
              _pasteMode
                  ? l10n.settingsPasteToggleBack
                  : l10n.settingsPasteToggle,
              style: Theme.of(context).textTheme.titleSmall
                  ?.copyWith(color: Theme.of(context).colorScheme.primary),
            ),
          ),
        ),
      ],
    ),
  );

  Widget _pasteBox(AppLocalizations l10n) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      TextField(
        controller: _pasteController,
        enabled: !_saving,
        autofocus: true,
        autocorrect: false,
        enableSuggestions: false,
        smartDashesType: SmartDashesType.disabled,
        smartQuotesType: SmartQuotesType.disabled,
        minLines: 4,
        maxLines: 8,
        style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
        decoration: InputDecoration(
          hintText: l10n.settingsPasteBlockHint,
          hintMaxLines: 4,
          border: const OutlineInputBorder(),
          suffixIcon: IconButton(
            icon: const Icon(Icons.content_paste),
            tooltip: l10n.settingsPasteFromClipboard,
            onPressed: _saving ? null : _pasteFromClipboard,
          ),
        ),
        onChanged: _onPastedTextChanged,
      ),
      Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Text(
          l10n.settingsPasteNote,
          style: Theme.of(context).textTheme.bodySmall
              ?.copyWith(color: Colors.grey),
        ),
      ),
    ],
  );

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
    return (value == null || value.trim().isEmpty)
        ? l10n.settingsRequiredFieldError
        : null;
  }

  /// Non-blocking: static IAM keys are always exactly these lengths, but
  /// this only ever warns — never stops Save — since other credential
  /// shapes (e.g. temporary STS keys) do exist.
  String? _lengthHint(AppLocalizations l10n, String text, int expectedLength) {
    final trimmed = text.trim();
    if (trimmed.isEmpty || trimmed.length == expectedLength) return null;
    return l10n.settingsLengthHint(trimmed.length, expectedLength);
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
    if (accessKeyId.isNotEmpty ||
        secretAccessKey.isNotEmpty ||
        bucket.isNotEmpty) {
      try {
        await _draftsStore.save(
          accessKeyId: accessKeyId,
          secretAccessKey: secretAccessKey,
          bucket: bucket,
          prefix: prefix,
        );
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
            DropdownButtonFormField<BackupStorageType>(
              initialValue: BackupStorageType.s3,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: l10n.settingsStorageTypeLabel,
                border: const OutlineInputBorder(),
              ),
              items: [
                for (final t in backupStorageTypes)
                  DropdownMenuItem(
                    value: t.type,
                    enabled: t.available,
                    child: Text(
                      t.available
                          ? t.name
                          : l10n.settingsStorageTypeComingSoon(t.name),
                      style: t.available
                          ? null
                          : TextStyle(color: Theme.of(context).disabledColor),
                    ),
                  ),
              ],
              // Every other type is disabled in the list above — this never
              // actually fires, but the form needs a valid onChanged to
              // render as an editable field rather than a plain label.
              onChanged: (_) {},
            ),
            const SizedBox(height: 16),
            _groupHeader(l10n),
            if (_pasteMode)
              _pasteBox(l10n)
            else ...[
              TextFormField(
                controller: _accessKeyIdController,
                enabled: !_saving,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: l10n.settingsAccessKeyIdLabel,
                  helperText: _lengthHint(
                    l10n,
                    _accessKeyIdController.text,
                    20,
                  ),
                  helperMaxLines: 2,
                ),
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
                  helperText: _lengthHint(
                    l10n,
                    _secretAccessKeyController.text,
                    40,
                  ),
                  helperMaxLines: 2,
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscureSecret ? Icons.visibility_off : Icons.visibility,
                    ),
                    onPressed: () =>
                        setState(() => _obscureSecret = !_obscureSecret),
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
                decoration: InputDecoration(
                  labelText: l10n.settingsBucketLabel,
                ),
                validator: (v) => _required(l10n, v),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _prefixController,
                enabled: !_saving,
                decoration: InputDecoration(
                  labelText: l10n.settingsPrefixLabel,
                  hintText: 'photo-backup/',
                ),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 16),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
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
              Text(
                l10n.settingsDraftsTitle,
                style: Theme.of(context).textTheme.titleSmall,
              ),
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
                              Text(
                                draft.bucket.isEmpty
                                    ? l10n.settingsDraftUntitled
                                    : draft.bucket,
                              ),
                              if (draft.accessKeyId.isNotEmpty)
                                Text(
                                  _maskedAccessKeyId(draft.accessKeyId),
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(color: Colors.grey),
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
