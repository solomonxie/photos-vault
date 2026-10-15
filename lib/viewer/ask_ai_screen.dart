import 'package:flutter/cupertino.dart';

import '../l10n/app_localizations.dart';
import '../photos/ai_ask_service.dart';
import '../settings/settings_section.dart';

/// A question typed about a person, and the answer. Text only: no photo is
/// ever sent to an AI service.
///
/// Its own page rather than a sheet: an answer is prose of unknown length, and
/// a sheet that grows to fit is a sheet that covers the thing being asked
/// about.
class AskAiScreen extends StatefulWidget {
  const AskAiScreen({
    super.key,
    required this.subject,
    this.context = '',
    this.service,
  });

  /// What is being asked about, for the title.
  final String subject;

  /// What the app knows and the vendor does not, shown before it is sent.
  /// Nobody should have to guess what left their phone.
  final String context;

  final AiAskService? service;

  @override
  State<AskAiScreen> createState() => _AskAiScreenState();
}

class _AskAiScreenState extends State<AskAiScreen> {
  late final AiAskService _service = widget.service ?? AiAskService();
  final _question = TextEditingController();
  bool _asking = false;
  String? _answer;
  String? _error;

  @override
  void dispose() {
    _question.dispose();
    super.dispose();
  }

  Future<void> _ask() async {
    final question = _question.text.trim();
    if (question.isEmpty || _asking) return;
    setState(() {
      _asking = true;
      _answer = null;
      _error = null;
    });
    try {
      final answer = await _service.ask(
        question: question,
        context: widget.context,
      );
      if (mounted) setState(() => _answer = answer);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _asking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(middle: Text(l10n.askAiTitle)),
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.only(top: 12, bottom: 32),
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                widget.subject,
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: CupertinoTextField(
                controller: _question,
                placeholder: l10n.askAiPromptPlaceholder,
                minLines: 2,
                maxLines: 5,
                padding: const EdgeInsets.all(12),
              ),
            ),
            const SizedBox(height: 14),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: CupertinoButton.filled(
                onPressed: _asking ? null : _ask,
                child: Text(
                  _asking ? l10n.askAiThinking : l10n.askAiSendButton,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(l10n.askAiSendsNote, style: settingsFooterStyle),
            ),
            if (_error case final error?) ...[
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  error,
                  style: const TextStyle(color: CupertinoColors.systemRed),
                ),
              ),
            ],
            if (_answer case final answer?) ...[
              const SizedBox(height: 20),
              SettingsSection(
                heading: l10n.askAiAnswerHeading,
                children: [
                  Padding(
                    padding: const EdgeInsets.all(14),
                    // Not `SelectableText`: that is Material, and this app is
                    // Cupertino. A read-only field selects and copies.
                    child: CupertinoTextField.borderless(
                      controller: TextEditingController(text: answer),
                      readOnly: true,
                      maxLines: null,
                      padding: EdgeInsets.zero,
                    ),
                  ),
                ],
              ),
            ],
            if (widget.context.isNotEmpty) ...[
              const SizedBox(height: 20),
              SettingsSection(
                heading: l10n.askAiContextHeading,
                children: [
                  Padding(
                    padding: const EdgeInsets.all(14),
                    child: Text(
                      widget.context,
                      style: settingsRowSubtitleStyle,
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
