import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';

import '../l10n/app_localizations.dart';
import '../photos/ai_ask_service.dart';
import '../photos/document_text.dart';
import '../photos/person.dart';
import '../photos/person_detail.dart';
import '../photos/person_store.dart';
import '../photos/profile_autofill.dart';
import '../settings/settings_section.dart';
import '../vault/keys.dart';

/// What a run of the autofill is doing.
enum AutofillStage { idle, reading, asking, reviewing, done }

/// Pick a document, let the AI read it, then go through what it found one line
/// at a time.
///
/// Nothing is written until something is accepted, and nothing is accepted by
/// default. The whole point of a review step is that a vendor's reading of a CV
/// is a proposal about a real person, and some of it will be wrong in ways only
/// the reader can see.
class ProfileAutofillScreen extends StatefulWidget {
  const ProfileAutofillScreen({
    super.key,
    required this.person,
    required this.personStore,
    required this.detail,
    this.passcodeHash = openNamespace,
    this.keys,
    this.service,
    this.pickFile,
    this.reader,
  });

  final Person person;
  final PersonStore personStore;

  /// The set currently open, so accepted items land where the reader is
  /// looking rather than in the profile they cannot see.
  final PersonDetail detail;
  final String passcodeHash;
  final AlbumKeys? keys;

  final AiAskService? service;

  /// Overridable so a test never opens the system file browser. [path] is
  /// there for PDFKit, which opens a URL rather than bytes.
  final Future<({String name, List<int> bytes, String? path})?> Function()?
  pickFile;

  /// Overridable so a test never reaches the PDF platform channel.
  final DocumentReader? reader;

  @override
  State<ProfileAutofillScreen> createState() => _ProfileAutofillScreenState();
}

class _ProfileAutofillScreenState extends State<ProfileAutofillScreen> {
  late final AiAskService _service = widget.service ?? AiAskService();
  late final DocumentReader _reader = widget.reader ?? DocumentReader();
  AutofillStage _stage = AutofillStage.idle;
  String? _error;
  String _fileName = '';
  List<ProfileSuggestion> _suggestions = const [];

  /// Which ones are in. Nothing starts accepted — a list that arrives already
  /// ticked is a list nobody reads.
  final Set<int> _accepted = {};

  Future<void> _run() async {
    final l10n = AppLocalizations.of(context)!;
    setState(() {
      _stage = AutofillStage.reading;
      _error = null;
      _suggestions = const [];
      _accepted.clear();
    });
    try {
      final picked = await (widget.pickFile ?? _pickWithSystemBrowser)();
      if (picked == null) {
        if (mounted) setState(() => _stage = AutofillStage.idle);
        return;
      }
      final read = await _reader.read(
        name: picked.name,
        bytes: picked.bytes,
        path: picked.path,
      );
      final text = read.text;
      if (text == null) {
        if (mounted) {
          setState(() {
            _stage = AutofillStage.idle;
            _error = switch (read.problem) {
              DocumentProblem.scannedPdf => l10n.autofillScannedPdf,
              DocumentProblem.empty => l10n.autofillEmptyFile,
              _ => l10n.autofillUnsupportedFormat,
            };
          });
        }
        return;
      }
      if (!mounted) return;
      setState(() {
        _fileName = picked.name;
        _stage = AutofillStage.asking;
      });
      final reply = await _service.ask(question: autofillPrompt(text));
      final found = parseAutofill(reply);
      if (!mounted) return;
      setState(() {
        _suggestions = found;
        _stage = found.isEmpty ? AutofillStage.idle : AutofillStage.reviewing;
        if (found.isEmpty) _error = l10n.autofillNothingFound;
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _stage = AutofillStage.idle;
          _error = '$error';
        });
      }
    }
  }

  static Future<({String name, List<int> bytes, String? path})?>
  _pickWithSystemBrowser() async {
    final picked = await FilePicker.pickFiles(type: FileType.any);
    final file = picked.firstOrNull;
    if (file == null) return null;
    return (name: file.name, bytes: await file.readAsBytes(), path: file.path);
  }

  /// Writes the accepted ones, each through the same call the screen it
  /// belongs to would have made.
  Future<void> _apply() async {
    final store = widget.personStore;
    final hash = widget.passcodeHash;
    final keys = widget.keys;
    var detail = widget.detail;
    var changedDetail = false;

    for (final index in _accepted.toList()..sort()) {
      final suggestion = _suggestions[index];
      switch (suggestion.target) {
        case SuggestionTarget.bio:
          detail = detail.copyWith(bio: suggestion.value);
          changedDetail = true;
        case SuggestionTarget.trait:
          detail = detail.copyWith(
            traits: {...detail.traits, suggestion.label: suggestion.value},
          );
          changedDetail = true;
        case SuggestionTarget.customField:
          detail = detail.copyWith(
            customFields: [
              ...detail.customFields,
              PersonCustomField(
                label: suggestion.label,
                value: suggestion.value,
              ),
            ],
          );
          changedDetail = true;
        case SuggestionTarget.tag:
          final tag = suggestion.label.toLowerCase();
          if (!detail.impression.tags.contains(tag)) {
            detail = detail.copyWith(
              impression: detail.impression.copyWith(
                tags: [...detail.impression.tags, tag],
              ),
            );
            changedDetail = true;
          }
        case SuggestionTarget.group:
          await store.joinGroup(
            widget.person.id,
            PersonGroup(
              id: store.newId(),
              name: suggestion.label,
              // Nothing in a document says which kind of group it is, and
              // guessing "company" from a CV would be wrong for a university.
              kind: GroupKind.circle,
            ),
            passcodeHash: hash,
            keys: keys,
          );
        case SuggestionTarget.education:
        case SuggestionTarget.job:
          await store.addHistoryEntry(
            PersonHistoryEntry(
              id: store.newId(),
              personId: widget.person.id,
              category: suggestion.target == SuggestionTarget.education
                  ? HistoryCategory.education
                  : HistoryCategory.job,
              title: suggestion.label,
              notes: suggestion.value,
            ),
            passcodeHash: hash,
            keys: keys,
          );
        case SuggestionTarget.place:
          await store.addLocation(
            PersonLocation(
              id: store.newId(),
              personId: widget.person.id,
              kind: LocationKind.relocation,
              place: suggestion.label,
              since: DateTime.now(),
            ),
            passcodeHash: hash,
            keys: keys,
          );
      }
    }
    if (changedDetail) {
      await store.saveDetail(
        widget.person.id,
        detail,
        passcodeHash: hash,
        keys: keys,
      );
    }
    if (mounted) Navigator.of(context).pop(_accepted.length);
  }

  static String _targetLabel(AppLocalizations l10n, SuggestionTarget target) =>
      switch (target) {
        SuggestionTarget.bio => l10n.autofillTargetBio,
        SuggestionTarget.trait => l10n.autofillTargetTrait,
        SuggestionTarget.customField => l10n.autofillTargetCustomField,
        SuggestionTarget.group => l10n.autofillTargetGroup,
        SuggestionTarget.education => l10n.autofillTargetEducation,
        SuggestionTarget.job => l10n.autofillTargetJob,
        SuggestionTarget.place => l10n.autofillTargetPlace,
        SuggestionTarget.tag => l10n.autofillTargetTag,
      };

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final busy =
        _stage == AutofillStage.reading || _stage == AutofillStage.asking;
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(middle: Text(l10n.autofillTitle)),
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.only(top: 12, bottom: 32),
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: CupertinoButton.filled(
                onPressed: busy ? null : _run,
                child: Text(switch (_stage) {
                  AutofillStage.reading => l10n.autofillReading,
                  AutofillStage.asking => l10n.autofillAsking,
                  _ => l10n.autofillPickButton,
                }),
              ),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(l10n.autofillSendsNote, style: settingsFooterStyle),
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
            if (_suggestions.isNotEmpty) ...[
              const SizedBox(height: 20),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(_fileName, style: settingsRowSubtitleStyle),
                    ),
                    CupertinoButton(
                      padding: EdgeInsets.zero,
                      onPressed: () => setState(
                        () => _accepted.addAll(
                          List.generate(_suggestions.length, (i) => i),
                        ),
                      ),
                      child: Text(
                        l10n.autofillAcceptAll,
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                    const SizedBox(width: 8),
                    CupertinoButton(
                      padding: EdgeInsets.zero,
                      onPressed: () => setState(_accepted.clear),
                      child: Text(
                        l10n.autofillRejectAll,
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
              SettingsSection(
                heading: l10n.autofillReviewHeading,
                children: [
                  for (var i = 0; i < _suggestions.length; i++)
                    CupertinoListTile(
                      key: ValueKey('suggestion-$i'),
                      title: Text(_suggestions[i].label),
                      subtitle: Text(
                        [
                          _targetLabel(l10n, _suggestions[i].target),
                          if (_suggestions[i].summary.isNotEmpty)
                            _suggestions[i].summary,
                        ].join(' · '),
                      ),
                      trailing: CupertinoSwitch(
                        value: _accepted.contains(i),
                        onChanged: (on) => setState(
                          () => on ? _accepted.add(i) : _accepted.remove(i),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: CupertinoButton.filled(
                  onPressed: _accepted.isEmpty ? null : _apply,
                  child: Text(l10n.autofillApply(_accepted.length)),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
