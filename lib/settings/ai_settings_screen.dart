import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import 'ai_settings_store.dart';

/// Standalone "AI Settings" utility screen — the OpenAI API key that powers
/// People/Events smart-collection recognition (T4.4, see
/// `lib/viewer/smart_collection_screen.dart`), kept separate from S3 backup
/// settings since it configures a different, optional feature.
class AiSettingsScreen extends StatefulWidget {
  const AiSettingsScreen({super.key, this.aiSettingsStore});

  final AiSettingsStore? aiSettingsStore;

  @override
  State<AiSettingsScreen> createState() => _AiSettingsScreenState();
}

class _AiSettingsScreenState extends State<AiSettingsScreen> {
  late final AiSettingsStore _aiSettingsStore = widget.aiSettingsStore ?? AiSettingsStore();
  final _openAiApiKeyController = TextEditingController();

  bool _savingApiKey = false;

  @override
  void initState() {
    super.initState();
    _loadApiKey();
  }

  @override
  void dispose() {
    _openAiApiKeyController.dispose();
    super.dispose();
  }

  Future<void> _loadApiKey() async {
    final key = await _aiSettingsStore.readOpenAiApiKey();
    if (!mounted || key == null) return;
    _openAiApiKeyController.text = key;
  }

  Future<void> _saveApiKey() async {
    setState(() => _savingApiKey = true);
    try {
      await _aiSettingsStore.saveOpenAiApiKey(_openAiApiKeyController.text.trim());
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(AppLocalizations.of(context)!.settingsAiSavedMessage)));
    } finally {
      if (mounted) setState(() => _savingApiKey = false);
    }
  }

  Future<void> _clearApiKey() async {
    setState(() => _savingApiKey = true);
    try {
      await _aiSettingsStore.clearOpenAiApiKey();
      _openAiApiKeyController.clear();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(AppLocalizations.of(context)!.settingsAiClearedMessage)));
    } finally {
      if (mounted) setState(() => _savingApiKey = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.collectionsAiSettingsRow)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(l10n.settingsAiTodoNote, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.grey)),
          const SizedBox(height: 12),
          TextField(
            controller: _openAiApiKeyController,
            obscureText: true,
            decoration: InputDecoration(labelText: l10n.settingsAiApiKeyLabel, border: const OutlineInputBorder()),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              FilledButton(onPressed: _savingApiKey ? null : _saveApiKey, child: Text(l10n.settingsSaveButton)),
              const SizedBox(width: 8),
              TextButton(onPressed: _savingApiKey ? null : _clearApiKey, child: Text(l10n.settingsAiClearButton)),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.warning_amber_rounded, size: 16, color: Colors.orange),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  l10n.settingsAiUsageWarning,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.orange[800]),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
