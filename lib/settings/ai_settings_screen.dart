import 'package:flutter/cupertino.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/app_localizations.dart';
import '../photos/ai_vendor.dart';
import 'ai_settings_store.dart';
import 'settings_section.dart';

/// Standalone "AI Settings" utility screen — the keys that power
/// People/Events smart-collection recognition (T4.4, see
/// `lib/viewer/smart_collection_screen.dart`), kept separate from S3 backup
/// settings since it configures a different, optional feature. Any mix of
/// vendors can be added; [AiSettingsStore.runWithKeys] tries them in turn
/// (sequential or round-robin) so one dead/rate-limited key doesn't stop
/// analysis outright.
///
/// Same flat, dark section layout as Private Cloud: the key list is the
/// subject, the fallback strategy is the one control on its heading, and
/// adding a key is a half sheet rather than a form permanently parked
/// under the list.
class AiSettingsScreen extends StatefulWidget {
  const AiSettingsScreen({super.key, this.aiSettingsStore});

  final AiSettingsStore? aiSettingsStore;

  @override
  State<AiSettingsScreen> createState() => _AiSettingsScreenState();
}

class _AiSettingsScreenState extends State<AiSettingsScreen> {
  late final AiSettingsStore _store =
      widget.aiSettingsStore ?? AiSettingsStore();

  List<AiKeyMeta> _keys = const [];
  AiKeyStrategy _strategy = AiKeyStrategy.sequential;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final keys = await _store.listKeys();
    final strategy = await _store.getStrategy();
    if (!mounted) return;
    setState(() {
      _keys = keys;
      _strategy = strategy;
    });
  }

  Future<void> _addKey() async {
    final added = await showAddAiKeySheet(context);
    if (added == null) return;
    await _store.addKey(added.vendor, added.secret);
    await _load();
  }

  Future<void> _removeKey(AiKeyMeta key) async {
    await _store.removeKey(key.id);
    await _load();
  }

  Future<void> _moveKey(AiKeyMeta key, int direction) async {
    await _store.moveKey(key.id, direction);
    await _load();
  }

  Future<void> _toggleStrategy() async {
    final next = _strategy == AiKeyStrategy.sequential
        ? AiKeyStrategy.roundRobin
        : AiKeyStrategy.sequential;
    setState(() => _strategy = next);
    await _store.setStrategy(next);
  }

  /// Confirmed, because a key that's gone has to be fetched from the
  /// vendor's console again — the secret isn't recoverable from here.
  Future<void> _confirmRemove(AiKeyMeta key) async {
    final l10n = AppLocalizations.of(context)!;
    await showCupertinoModalPopup<void>(
      context: context,
      builder: (sheetContext) => CupertinoActionSheet(
        title: Text(aiVendorName(key.vendor)),
        actions: [
          CupertinoActionSheetAction(
            isDestructiveAction: true,
            onPressed: () {
              Navigator.of(sheetContext).pop();
              _removeKey(key);
            },
            child: Text(l10n.settingsAiClearButton),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(sheetContext).pop(),
          child: Text(l10n.actionCancel),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return CupertinoPageScaffold(
      backgroundColor: settingsPageBackground,
      navigationBar: CupertinoNavigationBar(
        backgroundColor: settingsPageBackground,
        middle: Text(l10n.collectionsAiSettingsRow),
      ),
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.only(top: 16, bottom: 32),
          children: [
            SettingsSection(
              heading: l10n.settingsAiKeysHeading,
              hint: l10n.settingsAiKeysHint,
              action: SettingsAccentButton(
                label: _strategy == AiKeyStrategy.sequential
                    ? l10n.settingsAiKeyStrategySequential
                    : l10n.settingsAiKeyStrategyRoundRobin,
                showChevron: true,
                // The order only decides anything once there's a second key
                // to fall back to.
                onPressed: _keys.length < 2 ? null : _toggleStrategy,
              ),
              children: [
                for (var i = 0; i < _keys.length; i++) ...[
                  if (i > 0)
                    const SettingsHairline(indent: settingsPagePadding),
                  SettingsRow(
                    title: aiVendorName(_keys[i].vendor),
                    subtitle: l10n.settingsAiKeyRequestCount(
                      _keys[i].requestCount,
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _RowIconButton(
                          icon: CupertinoIcons.arrow_up,
                          onPressed: i == 0
                              ? null
                              : () => _moveKey(_keys[i], -1),
                        ),
                        _RowIconButton(
                          icon: CupertinoIcons.arrow_down,
                          onPressed: i == _keys.length - 1
                              ? null
                              : () => _moveKey(_keys[i], 1),
                        ),
                        _RowIconButton(
                          icon: CupertinoIcons.ellipsis,
                          onPressed: () => _confirmRemove(_keys[i]),
                        ),
                      ],
                    ),
                  ),
                ],
                if (_keys.isNotEmpty)
                  const SettingsHairline(indent: settingsPagePadding),
                _AddKeyRow(label: l10n.settingsAddAiKeyLink, onTap: _addKey),
              ],
            ),
            const SettingsSectionDivider(),
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: settingsPagePadding,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(l10n.settingsAiTodoNote, style: settingsHintStyle),
                  const SizedBox(height: 12),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(
                        CupertinoIcons.exclamationmark_triangle_fill,
                        size: 14,
                        color: CupertinoColors.systemOrange,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          l10n.settingsAiUsageWarning,
                          style: settingsHintStyle.copyWith(
                            color: CupertinoColors.systemOrange,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The centred accent link that closes the key list, rather than a filled
/// button under it — adding a key is one more row's worth of weight.
class _AddKeyRow extends StatelessWidget {
  const _AddKeyRow({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(CupertinoIcons.add, size: 16, color: settingsAccent),
          const SizedBox(width: 6),
          Text(
            label,
            style: const TextStyle(fontSize: 15, color: settingsAccent),
          ),
        ],
      ),
    ),
  );
}

class _RowIconButton extends StatelessWidget {
  const _RowIconButton({required this.icon, required this.onPressed});

  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => CupertinoButton(
    padding: const EdgeInsets.symmetric(horizontal: 6),
    minimumSize: Size.zero,
    onPressed: onPressed,
    child: Icon(
      icon,
      size: 18,
      color: onPressed == null ? settingsTertiary : settingsAccent,
    ),
  );
}

/// What [showAddAiKeySheet] hands back.
class AddedAiKey {
  const AddedAiKey(this.vendor, this.secret);

  final AiVendor vendor;
  final String secret;
}

/// Two fields don't need a page: vendor, key, and a link to that vendor's
/// own console for anyone who doesn't have one yet.
Future<AddedAiKey?> showAddAiKeySheet(BuildContext context) =>
    showCupertinoModalPopup<AddedAiKey>(
      context: context,
      builder: (_) => const _AddAiKeySheet(),
    );

class _AddAiKeySheet extends StatefulWidget {
  const _AddAiKeySheet();

  @override
  State<_AddAiKeySheet> createState() => _AddAiKeySheetState();
}

class _AddAiKeySheetState extends State<_AddAiKeySheet> {
  final _secretController = TextEditingController();
  AiVendor _vendor = AiVendor.openai;

  @override
  void initState() {
    super.initState();
    _secretController.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _secretController.dispose();
    super.dispose();
  }

  AiVendorMeta get _meta => aiVendors.firstWhere((v) => v.vendor == _vendor);

  Future<void> _pickVendor() async {
    await showCupertinoModalPopup<void>(
      context: context,
      builder: (sheetContext) => CupertinoActionSheet(
        actions: [
          for (final meta in aiVendors)
            CupertinoActionSheetAction(
              onPressed: () {
                Navigator.of(sheetContext).pop();
                setState(() => _vendor = meta.vendor);
              },
              child: Text(meta.name),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(sheetContext).pop(),
          child: Text(AppLocalizations.of(context)!.actionCancel),
        ),
      ),
    );
  }

  void _save() {
    final secret = _secretController.text.trim();
    if (secret.isEmpty) return;
    Navigator.of(context).pop(AddedAiKey(_vendor, secret));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final media = MediaQuery.of(context);
    final ready = _secretController.text.trim().isNotEmpty;

    return Padding(
      padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
      child: Container(
        decoration: const BoxDecoration(
          color: settingsPageBackground,
          borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 10, 8, 6),
                child: Row(
                  children: [
                    CupertinoButton(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: Size.zero,
                      onPressed: () => Navigator.of(context).pop(),
                      child: Text(
                        l10n.actionCancel,
                        style: const TextStyle(
                          fontSize: 15,
                          color: settingsAccent,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        l10n.settingsAddAiKeyLink,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                          color: CupertinoColors.white,
                        ),
                      ),
                    ),
                    CupertinoButton(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: Size.zero,
                      onPressed: ready ? _save : null,
                      child: Text(
                        l10n.settingsSaveButton,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: ready ? settingsAccent : settingsTertiary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SettingsHairline(),
              SettingsRow(
                title: l10n.settingsAiVendorLabel,
                onTap: _pickVendor,
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_meta.name, style: settingsRowDetailStyle),
                    const SizedBox(width: 4),
                    const Icon(
                      CupertinoIcons.chevron_down,
                      size: 12,
                      color: settingsSecondary,
                    ),
                  ],
                ),
              ),
              const SettingsHairline(indent: settingsPagePadding),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  settingsPagePadding,
                  12,
                  settingsPagePadding,
                  6,
                ),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    l10n.settingsAiApiKeyLabel,
                    style: settingsRowTitleStyle,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  settingsPagePadding,
                  0,
                  settingsPagePadding,
                  8,
                ),
                child: CupertinoTextField(
                  controller: _secretController,
                  autofocus: true,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  smartDashesType: SmartDashesType.disabled,
                  smartQuotesType: SmartQuotesType.disabled,
                  placeholder: _meta.keyHint,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 12,
                  ),
                  style: const TextStyle(color: CupertinoColors.white),
                  decoration: BoxDecoration(
                    color: const Color(0xFF2C2C2E),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  onSubmitted: (_) => _save(),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  settingsPagePadding,
                  0,
                  settingsPagePadding,
                  16,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        l10n.settingsAiNoKeyYet(_meta.name),
                        style: settingsHintStyle,
                      ),
                    ),
                    SettingsAccentButton(
                      label: l10n.settingsAiGetKeyLink,
                      onPressed: () => launchUrl(
                        Uri.parse(_meta.docsUrl),
                        mode: LaunchMode.externalApplication,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
