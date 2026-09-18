import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';

import '../l10n/app_localizations.dart';
import '../viewer/search_picker_sheet.dart';
import 'backup_storage_type.dart';
import 'backup_targets_store.dart';
import 's3_backup_target.dart';
import 's3_connectivity.dart';
import 's3_credentials_text.dart';
import 's3_region_detection.dart';
import 's3_target_draft.dart';
import 's3_target_drafts_store.dart';
import 'settings_section.dart';

/// Default key prefix for a freshly added target: the app's own folder, so
/// the user never has to think one up. Editable before saving.
const defaultKeyPrefix = 'photos-vault/';

/// The fields, by name — what a test types into.
const accessKeyIdFieldKey = Key('addBackupAccessKeyId');
const secretAccessKeyFieldKey = Key('addBackupSecretAccessKey');
const bucketFieldKey = Key('addBackupBucket');
const prefixFieldKey = Key('addBackupPrefix');
const regionFieldKey = Key('addBackupRegion');
const pasteFieldKey = Key('addBackupPaste');

/// Same page as Cloud Settings, one step in: a dark card-less form whose
/// fields are filled boxes under small labels, the storage type a row that
/// opens a sheet, and Save in the navigation bar rather than a button
/// parked under the drafts list.
class AddBackupScreen extends StatefulWidget {
  const AddBackupScreen({
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
    BackupStorageType provider,
  })
  checkAccess;

  /// Overridable for tests so they never make a real network call. Only
  /// S3's region can be had from the bucket name alone; COS and OSS are
  /// picked from a list instead.
  final Future<S3RegionDetectionResult> Function(String bucket) detectRegion;

  final S3TargetDraftsStore? draftsStore;

  @override
  State<AddBackupScreen> createState() => _AddBackupScreenState();
}

class _AddBackupScreenState extends State<AddBackupScreen> {
  late final S3TargetDraftsStore _draftsStore =
      widget.draftsStore ?? S3TargetDraftsStore();

  final _accessKeyIdController = TextEditingController();
  final _secretAccessKeyController = TextEditingController();
  final _bucketController = TextEditingController();
  final _prefixController = TextEditingController(text: defaultKeyPrefix);
  final _pasteController = TextEditingController();

  BackupStorageType _provider = BackupStorageType.s3;

  /// Picked from the provider's own list, or typed — both providers add
  /// regions faster than an app ships, and being unable to enter the one
  /// on the console would be worse than a typo. Empty for S3, which
  /// detects it from the bucket name instead.
  String _region = '';

  /// While true the fields are swapped out for the paste box — a mode of
  /// the same group, not a second input sitting above them.
  bool _pasteMode = false;

  /// Length of the paste box's text as of the last change, to tell a real
  /// paste (one multi-character insert) from someone typing a block out.
  int _pasteLength = 0;

  bool _obscureSecret = true;
  bool _saving = false;
  String? _error;

  /// Per-field "Required", keyed by the field's own key — shown on Save,
  /// cleared as soon as the field it points at has something in it.
  final _fieldErrors = <Key, String>{};

  List<S3TargetDraft> _drafts = const [];

  @override
  void initState() {
    super.initState();
    _reloadDrafts();
    // Live length check: AWS access key IDs are always 20 characters, secret
    // keys always 40 — a paste that picked up an extra/missing/invisible
    // character (common cause of a SignatureDoesNotMatch) shows up
    // immediately, before Save even runs a network call.
    _accessKeyIdController.addListener(_onFieldChanged);
    _secretAccessKeyController.addListener(_onFieldChanged);
    _bucketController.addListener(_onFieldChanged);
  }

  /// The three a value has to be typed into — the region is picked, so it
  /// clears its own error when one is chosen.
  Map<Key, TextEditingController> get _requiredFields => {
    accessKeyIdFieldKey: _accessKeyIdController,
    secretAccessKeyFieldKey: _secretAccessKeyController,
    bucketFieldKey: _bucketController,
  };

  void _onFieldChanged() => setState(() {
    final typed = _requiredFields;
    _fieldErrors.removeWhere(
      (key, _) => typed[key]?.text.trim().isNotEmpty ?? false,
    );
  });

  BackupStorageTypeMeta get _meta => backupStorageTypeMeta(_provider);

  @override
  void dispose() {
    _accessKeyIdController.removeListener(_onFieldChanged);
    _secretAccessKeyController.removeListener(_onFieldChanged);
    _bucketController.removeListener(_onFieldChanged);
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
  /// real paste snaps straight back to the fields, because seeing them
  /// filled is the confirmation. Typing a block out by hand keeps the box
  /// open, or it would close on the second line.
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
      // Before the region, which only means anything under its provider.
      final pastedProvider = parsed.provider;
      if (pastedProvider != null &&
          pastedProvider != _provider &&
          backupStorageTypeMeta(pastedProvider).available) {
        _provider = pastedProvider;
        _region = '';
      }
      if (parsed.region != null) _region = parsed.region!;

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

  /// The available backends, shown as themselves. The unbuilt ones are
  /// named in the field's hint instead of sitting there as dead chips —
  /// the roadmap is worth saying, not worth three tap targets that do
  /// nothing.
  static final _vendors = backupStorageTypes.where((m) => m.available).toList();

  void _selectVendor(int index) {
    final type = _vendors[index].type;
    if (type == _provider) return;
    setState(() {
      _provider = type;
      // A region id means nothing to another provider.
      _region = '';
      _fieldErrors.remove(regionFieldKey);
      _error = null;
    });
  }

  /// The provider's published regions as a searchable list that still takes
  /// a typed value — the same drop-down the rest of the app uses for a
  /// repeated free-text value.
  Future<void> _pickRegion() async {
    final l10n = AppLocalizations.of(context)!;
    final picked = await showSearchPickerSheet(
      context: context,
      title: l10n.settingsRegionLabel,
      options: _meta.regions.toSet(),
      selected: _region.isEmpty ? null : _region,
    );
    if (picked == null || !mounted) return;
    setState(() {
      _region = picked.trim().toLowerCase();
      _fieldErrors.remove(regionFieldKey);
      _error = null;
    });
  }

  void _fillFromDraft(S3TargetDraft draft) {
    setState(() {
      _accessKeyIdController.text = draft.accessKeyId;
      _secretAccessKeyController.text = draft.secretAccessKey;
      _bucketController.text = draft.bucket;
      _prefixController.text = draft.prefix;
      _provider = draft.provider;
      _region = draft.region;
      _fieldErrors.clear();
      _error = null;
    });
  }

  Future<void> _deleteDraft(S3TargetDraft draft) async {
    await _draftsStore.remove(draft.id);
    await _reloadDrafts();
  }

  /// Each console names the two halves of a credential differently, and a
  /// SecretId pasted into a box labelled "secret access key" is the mistake
  /// the labels exist to stop.
  String _accessKeyLabel(AppLocalizations l10n) => switch (_provider) {
    BackupStorageType.tencentCos => l10n.settingsSecretIdLabel,
    _ => l10n.settingsAccessKeyIdLabel,
  };

  String _secretLabel(AppLocalizations l10n) => switch (_provider) {
    BackupStorageType.tencentCos => l10n.settingsSecretKeyLabel,
    BackupStorageType.aliyunOss => l10n.settingsAccessKeySecretLabel,
    _ => l10n.settingsSecretAccessKeyLabel,
  };

  String _maskedAccessKeyId(String accessKeyId) {
    if (accessKeyId.length <= 8) return accessKeyId;
    return '${accessKeyId.substring(0, 4)}…${accessKeyId.substring(accessKeyId.length - 4)}';
  }

  /// Which provider and region the draft would restore, alongside enough of
  /// the key to tell two attempts at the same bucket apart.
  String _draftSubtitle(S3TargetDraft draft) => [
    backupStorageTypeMeta(draft.provider).shortName,
    if (draft.region.isNotEmpty) draft.region,
    if (draft.accessKeyId.isNotEmpty) _maskedAccessKeyId(draft.accessKeyId),
  ].join(' · ');

  /// Non-blocking: static IAM keys are always exactly these lengths, but
  /// this only ever warns — never stops Save — since other credential
  /// shapes (e.g. temporary STS keys) do exist. AWS only: COS and OSS keys
  /// have no one fixed length to compare against.
  String? _lengthHint(AppLocalizations l10n, String text, int expectedLength) {
    if (_provider != BackupStorageType.s3) return null;
    final trimmed = text.trim();
    if (trimmed.isEmpty || trimmed.length == expectedLength) return null;
    return l10n.settingsLengthHint(trimmed.length, expectedLength);
  }

  String _messageFor(AppLocalizations l10n, S3AccessCheckResult result) {
    final base = switch (result.outcome) {
      S3AccessCheckOutcome.forbidden => l10n.settingsAccessCheckForbidden,
      // A picked region is the other way to get a 404, and the likelier one
      // — the bucket name came off the same screen as the credentials.
      S3AccessCheckOutcome.notFound =>
        _meta.detectsRegion
            ? l10n.settingsAccessCheckNotFound
            : l10n.settingsAccessCheckNotFoundRegion,
      S3AccessCheckOutcome.networkError => l10n.settingsAccessCheckNetworkError,
      S3AccessCheckOutcome.ok => '',
    };
    // Surface the provider's own error code (InvalidAccessKeyId,
    // SignatureDoesNotMatch, AccessDenied, ...) — each points at a
    // different field to fix.
    final detail = result.detail;
    return detail == null ? base : '$base ($detail)';
  }

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context)!;

    final accessKeyId = _accessKeyIdController.text.trim();
    final secretAccessKey = _secretAccessKeyController.text.trim();
    final bucket = _bucketController.text.trim();
    final prefix = normalizeKeyPrefix(_prefixController.text);
    final pickedRegion = _region.trim().toLowerCase();
    // Show what's actually going to be saved, rather than quietly filing it
    // under something the user didn't type.
    if (_prefixController.text != prefix) _prefixController.text = prefix;

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
          region: pickedRegion,
          provider: _provider,
        );
      } catch (_) {
        // Ignored — see above.
      }
      await _reloadDrafts();
    }
    if (!mounted) return;

    final missing = <Key, String>{
      if (accessKeyId.isEmpty)
        accessKeyIdFieldKey: l10n.settingsRequiredFieldError,
      if (secretAccessKey.isEmpty)
        secretAccessKeyFieldKey: l10n.settingsRequiredFieldError,
      if (bucket.isEmpty) bucketFieldKey: l10n.settingsRequiredFieldError,
      // Its own field says it, rather than a line at the foot of the form.
      if (!_meta.detectsRegion && pickedRegion.isEmpty)
        regionFieldKey: l10n.settingsRegionRequiredError,
    };
    if (missing.isNotEmpty) {
      setState(() {
        _fieldErrors
          ..clear()
          ..addAll(missing);
      });
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
      _fieldErrors.clear();
    });

    final String region;
    if (_meta.detectsRegion) {
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
      region = regionResult.region!;
    } else {
      region = pickedRegion;
    }

    final result = await widget.checkAccess(
      accessKeyId: accessKeyId,
      secretAccessKey: secretAccessKey,
      region: region,
      bucket: bucket,
      provider: _provider,
    );

    if (!mounted) return;

    if (!result.isOk) {
      setState(() {
        _saving = false;
        _error = _messageFor(l10n, result);
      });
      return;
    }

    await widget.store.add(
      accessKeyId: accessKeyId,
      secretAccessKey: secretAccessKey,
      region: region,
      bucket: bucket,
      prefix: prefix,
      provider: _provider,
    );
    await _draftsStore.removeMatching(accessKeyId: accessKeyId, bucket: bucket);

    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  Widget _pasteBox(AppLocalizations l10n) => SettingsField(
    label: l10n.settingsPasteBlockLabel,
    fieldKey: pasteFieldKey,
    controller: _pasteController,
    enabled: !_saving,
    autofocus: true,
    monospace: true,
    minLines: 4,
    maxLines: 8,
    placeholder: l10n.settingsPasteBlockHint,
    helper: _meta.detectsRegion
        ? l10n.settingsPasteNote
        : l10n.settingsPasteNoteEndpoint,
    suffix: CupertinoButton(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      minimumSize: Size.zero,
      onPressed: _saving ? null : _pasteFromClipboard,
      child: Icon(
        CupertinoIcons.doc_on_clipboard,
        size: 18,
        semanticLabel: l10n.settingsPasteFromClipboard,
        color: settingsAccent,
      ),
    ),
    onChanged: _onPastedTextChanged,
  );

  /// Above the fields *and* the paste box: a pasted endpoint can change
  /// it, and a block that doesn't snap back would otherwise change the
  /// vendor with nothing on screen saying so.
  Widget _vendorField(AppLocalizations l10n) => SettingsChoiceField(
    label: l10n.settingsCloudVendorLabel,
    helper: l10n.settingsCloudVendorHint,
    options: [for (final meta in _vendors) meta.name],
    selected: _vendors.indexWhere((m) => m.type == _provider),
    onSelected: _saving ? null : _selectVendor,
  );

  List<Widget> _fields(AppLocalizations l10n) => [
    SettingsField(
      label: _accessKeyLabel(l10n),
      fieldKey: accessKeyIdFieldKey,
      controller: _accessKeyIdController,
      enabled: !_saving,
      helper: _lengthHint(l10n, _accessKeyIdController.text, 20),
      errorText: _fieldErrors[accessKeyIdFieldKey],
    ),
    SettingsField(
      label: _secretLabel(l10n),
      fieldKey: secretAccessKeyFieldKey,
      controller: _secretAccessKeyController,
      enabled: !_saving,
      obscure: _obscureSecret,
      helper: _lengthHint(l10n, _secretAccessKeyController.text, 40),
      errorText: _fieldErrors[secretAccessKeyFieldKey],
      suffix: CupertinoButton(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        minimumSize: Size.zero,
        onPressed: () => setState(() => _obscureSecret = !_obscureSecret),
        child: Icon(
          _obscureSecret ? CupertinoIcons.eye_slash : CupertinoIcons.eye,
          size: 18,
          color: settingsSecondary,
        ),
      ),
    ),
    SettingsField(
      label: l10n.settingsBucketLabel,
      fieldKey: bucketFieldKey,
      controller: _bucketController,
      enabled: !_saving,
      placeholder: _provider == BackupStorageType.tencentCos
          ? 'my-photos-1250000000'
          : 'my-photos',
      helper: _provider == BackupStorageType.tencentCos
          ? l10n.settingsBucketAppIdHint
          : null,
      errorText: _fieldErrors[bucketFieldKey],
    ),
    if (!_meta.detectsRegion)
      SettingsPickerField(
        fieldKey: regionFieldKey,
        label: l10n.settingsRegionLabel,
        value: _region,
        placeholder: _meta.regions.first,
        helper: l10n.settingsRegionHint,
        errorText: _fieldErrors[regionFieldKey],
        onTap: _saving ? null : _pickRegion,
      ),
    SettingsField(
      label: l10n.settingsPrefixLabel,
      fieldKey: prefixFieldKey,
      controller: _prefixController,
      enabled: !_saving,
      placeholder: 'photo-backup/',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return CupertinoPageScaffold(
      backgroundColor: settingsPageBackground,
      navigationBar: CupertinoNavigationBar(
        backgroundColor: settingsPageBackground,
        middle: Text(l10n.settingsAddButton),
        trailing: _saving
            ? const CupertinoActivityIndicator(radius: 9)
            : CupertinoButton(
                padding: EdgeInsets.zero,
                minimumSize: Size.zero,
                onPressed: _save,
                child: Text(
                  l10n.settingsSaveButton,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: settingsAccent,
                  ),
                ),
              ),
      ),
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.only(top: 16, bottom: 32),
          children: [
            SettingsSection(
              heading: l10n.settingsPasteGroupTitle,
              action: SettingsAccentButton(
                label: _pasteMode
                    ? l10n.settingsPasteToggleBack
                    : l10n.settingsPasteToggle,
                onPressed: _saving ? null : _togglePasteMode,
              ),
              children: [
                _vendorField(l10n),
                const SettingsHairline(indent: settingsPagePadding),
                const SizedBox(height: 12),
                if (_pasteMode) _pasteBox(l10n) else ..._fields(l10n),
                if (_error != null) SettingsErrorLine(message: _error!),
                if (_saving)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: settingsPagePadding,
                    ),
                    child: SettingsFooterLine(
                      text: l10n.settingsValidatingMessage,
                      busy: true,
                    ),
                  ),
              ],
            ),
            if (_drafts.isNotEmpty) ...[
              const SettingsSectionDivider(),
              SettingsSection(
                heading: l10n.settingsDraftsTitle,
                primary: false,
                children: [
                  for (var i = 0; i < _drafts.length; i++) ...[
                    if (i > 0)
                      const SettingsHairline(indent: settingsPagePadding),
                    SettingsRow(
                      title: _drafts[i].bucket.isEmpty
                          ? l10n.settingsDraftUntitled
                          : _drafts[i].bucket,
                      subtitle: _draftSubtitle(_drafts[i]),
                      onTap: _saving ? null : () => _fillFromDraft(_drafts[i]),
                      trailing: CupertinoButton(
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        minimumSize: Size.zero,
                        onPressed: _saving
                            ? null
                            : () => _deleteDraft(_drafts[i]),
                        child: Icon(
                          CupertinoIcons.xmark,
                          size: 16,
                          semanticLabel: l10n.settingsDraftDeleteTooltip,
                          color: settingsSecondary,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
