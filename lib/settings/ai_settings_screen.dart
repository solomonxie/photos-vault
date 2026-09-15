import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../photos/ai_vendor.dart';
import 'ai_settings_store.dart';

/// Standalone "AI Settings" utility screen — the keys that power
/// People/Events smart-collection recognition (T4.4, see
/// `lib/viewer/smart_collection_screen.dart`), kept separate from S3 backup
/// settings since it configures a different, optional feature. Any mix of
/// vendors can be added; [AiSettingsStore.runWithKeys] tries them in turn
/// (sequential or round-robin) so one dead/rate-limited key doesn't stop
/// analysis outright.
class AiSettingsScreen extends StatefulWidget {
  const AiSettingsScreen({super.key, this.aiSettingsStore});

  final AiSettingsStore? aiSettingsStore;

  @override
  State<AiSettingsScreen> createState() => _AiSettingsScreenState();
}

class _AiSettingsScreenState extends State<AiSettingsScreen> {
  late final AiSettingsStore _store =
      widget.aiSettingsStore ?? AiSettingsStore();
  final _newSecretController = TextEditingController();

  List<AiKeyMeta> _keys = const [];
  AiKeyStrategy _strategy = AiKeyStrategy.sequential;
  AiVendor _newVendor = AiVendor.openai;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _newSecretController.dispose();
    super.dispose();
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
    final secret = _newSecretController.text.trim();
    if (secret.isEmpty) return;
    setState(() => _busy = true);
    try {
      await _store.addKey(_newVendor, secret);
      _newSecretController.clear();
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context)!.settingsAiSavedMessage),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _removeKey(AiKeyMeta key) async {
    await _store.removeKey(key.id);
    await _load();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(AppLocalizations.of(context)!.settingsAiClearedMessage),
      ),
    );
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

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.collectionsAiSettingsRow)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            l10n.settingsAiTodoNote,
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: Colors.grey),
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                l10n.settingsAiKeysHeading,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              TextButton(
                onPressed: _toggleStrategy,
                child: Text(
                  _strategy == AiKeyStrategy.sequential
                      ? l10n.settingsAiKeyStrategySequential
                      : l10n.settingsAiKeyStrategyRoundRobin,
                ),
              ),
            ],
          ),
          Text(
            l10n.settingsAiKeysHint,
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: Colors.grey),
          ),
          const SizedBox(height: 8),
          for (var i = 0; i < _keys.length; i++)
            Card(
              margin: const EdgeInsets.only(bottom: 4),
              child: ListTile(
                title: Text(aiVendorName(_keys[i].vendor)),
                subtitle: Text(
                  l10n.settingsAiKeyRequestCount(_keys[i].requestCount),
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_upward),
                      onPressed: i == 0 ? null : () => _moveKey(_keys[i], -1),
                    ),
                    IconButton(
                      icon: const Icon(Icons.arrow_downward),
                      onPressed: i == _keys.length - 1
                          ? null
                          : () => _moveKey(_keys[i], 1),
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () => _removeKey(_keys[i]),
                    ),
                  ],
                ),
              ),
            ),
          const Divider(height: 32),
          Text(
            l10n.settingsAddAiKeyLink,
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<AiVendor>(
            initialValue: _newVendor,
            isExpanded: true,
            decoration: const InputDecoration(border: OutlineInputBorder()),
            items: [
              for (final v in aiVendors)
                DropdownMenuItem(value: v.vendor, child: Text(v.name)),
            ],
            onChanged: (v) => setState(() => _newVendor = v ?? _newVendor),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _newSecretController,
            obscureText: true,
            decoration: InputDecoration(
              labelText: l10n.settingsAiApiKeyLabel,
              hintText: aiVendors
                  .firstWhere((v) => v.vendor == _newVendor)
                  .keyHint,
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: _busy ? null : _addKey,
            child: Text(l10n.settingsSaveButton),
          ),
          const SizedBox(height: 16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(
                Icons.warning_amber_rounded,
                size: 16,
                color: Colors.orange,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  l10n.settingsAiUsageWarning,
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: Colors.orange[800]),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
