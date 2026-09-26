import 'dart:typed_data';

import 'package:flutter/cupertino.dart';

import '../l10n/app_localizations.dart';
import '../photos/ai_ask_service.dart';
import '../photos/image_pipeline.dart';
import '../settings/settings_section.dart';

/// How much of a picture to send.
///
/// Tokens are charged by pixels, and a question like "what kind of building is
/// this" is answered as well by a thumbnail as by twelve megapixels. The
/// default is the small one for that reason; full size is there for the
/// questions that genuinely need it, like reading small print.
enum AskAiResolution { small, medium, full }

int? maxEdgeFor(AskAiResolution resolution) => switch (resolution) {
  AskAiResolution.small => 512,
  AskAiResolution.medium => 1024,
  AskAiResolution.full => null,
};

/// A question typed about a person or a photo, and the answer.
///
/// Its own page rather than a sheet: an answer is prose of unknown length, and
/// a sheet that grows to fit is a sheet that covers the thing being asked
/// about.
class AskAiScreen extends StatefulWidget {
  const AskAiScreen({
    super.key,
    required this.subject,
    this.context = '',
    this.imageBytes,
    this.service,
  });

  /// What is being asked about, for the title — a name, or a file name.
  final String subject;

  /// What the app knows and the vendor does not, shown before it is sent.
  /// Nobody should have to guess what left their phone.
  final String context;

  /// The photo, full size. Shrunk here according to the chosen resolution
  /// rather than by the caller, so the choice and the shrinking stay together.
  final Future<Uint8List?> Function()? imageBytes;

  final AiAskService? service;

  @override
  State<AskAiScreen> createState() => _AskAiScreenState();
}

class _AskAiScreenState extends State<AskAiScreen> {
  late final AiAskService _service = widget.service ?? AiAskService();
  final _question = TextEditingController();
  AskAiResolution _resolution = AskAiResolution.small;
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
      Uint8List? image;
      if (widget.imageBytes != null) {
        final full = await widget.imageBytes!();
        image = full == null ? null : _shrink(full);
      }
      final answer = await _service.ask(
        question: question,
        context: widget.context,
        image: image,
      );
      if (mounted) setState(() => _answer = answer);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _asking = false);
    }
  }

  /// Re-encodes to the chosen edge. A failed shrink sends the original rather
  /// than sending nothing: an expensive answer beats no answer, and the size
  /// was a saving rather than a requirement.
  Uint8List _shrink(Uint8List full) {
    final maxEdge = maxEdgeFor(_resolution);
    if (maxEdge == null) return full;
    return optimizeStill(full, maxEdge: maxEdge)?.$1 ?? full;
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
            if (widget.imageBytes != null) ...[
              const SizedBox(height: 14),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      l10n.askAiResolutionLabel,
                      style: settingsRowSubtitleStyle,
                    ),
                    const SizedBox(height: 6),
                    CupertinoSlidingSegmentedControl<AskAiResolution>(
                      groupValue: _resolution,
                      children: {
                        AskAiResolution.small: Text(
                          l10n.askAiResolutionSmall,
                          style: const TextStyle(fontSize: 12),
                        ),
                        AskAiResolution.medium: Text(
                          l10n.askAiResolutionMedium,
                          style: const TextStyle(fontSize: 12),
                        ),
                        AskAiResolution.full: Text(
                          l10n.askAiResolutionFull,
                          style: const TextStyle(fontSize: 12),
                        ),
                      },
                      onValueChanged: (value) =>
                          setState(() => _resolution = value ?? _resolution),
                    ),
                    const SizedBox(height: 6),
                    Text(l10n.askAiResolutionNote, style: settingsFooterStyle),
                  ],
                ),
              ),
            ],
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
