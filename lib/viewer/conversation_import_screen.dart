import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../l10n/failure_text.dart';
import '../photos/conversation_file.dart';
import '../photos/conversation_store.dart';
import '../photos/person.dart';
import '../photos/person_store.dart';
import '../settings/settings_section.dart';
import 'import_name_choice.dart';

/// Chat history onto people already here. Never adds a person: a name
/// that matches nobody waits, unticked, until it's pointed at someone.
class ConversationImportScreen extends StatefulWidget {
  const ConversationImportScreen({
    super.key,
    required this.personStore,
    this.conversationStore,
    this.pickFiles,
    this.readFiles,
    this.pickOnOpen = false,
  });

  final PersonStore personStore;
  final ConversationStore? conversationStore;

  /// Overridable so a test never opens the system file browser.
  final Future<List<String>> Function()? pickFiles;

  /// Overridable so a test needn't leave the fake clock for an isolate.
  final Future<ConversationExport> Function(List<String> paths)? readFiles;

  /// Pick at once: how Developer Options opens it.
  final bool pickOnOpen;

  @override
  State<ConversationImportScreen> createState() =>
      _ConversationImportScreenState();
}

class _ConversationImportScreenState extends State<ConversationImportScreen> {
  late final ConversationStore _store =
      widget.conversationStore ?? ConversationStore();

  bool _reading = false;
  (int, int)? _progress;
  String? _error;
  String? _done;
  int _skippedLines = 0;

  List<ConversationPerson> _found = const [];
  List<Person> _people = const [];
  Map<int, List<Person>> _candidates = {};
  final Map<int, String> _names = {};

  /// Who each row goes to: always someone already in People.
  final Map<int, String> _targets = {};

  /// Attached to their one same-name person by default, not by a tap.
  final Set<int> _defaulted = {};
  final Set<int> _accepted = {};

  /// Rows that become a new person, under the name they show, on import.
  final Set<int> _newPeople = {};

  bool get _busy => _reading || _progress != null;

  String _nameOf(int i) => _names[i] ?? _found[i].name;

  bool _sameName(int i, Person p) =>
      p.name.trim().toLowerCase() == _nameOf(i).trim().toLowerCase();

  bool _taken(int i) => (_candidates[i] ?? const []).isNotEmpty;

  bool _waiting(int i) =>
      _taken(i) && !_targets.containsKey(i) && !_newPeople.contains(i);

  int get _needChoice => _accepted.where(_waiting).length;

  List<int> get _ready => [
    for (final i in _accepted)
      if (_targets.containsKey(i) || _newPeople.contains(i)) i,
  ];

  /// The closest candidate, until tapped to choose another.
  void _defaultAttach(int i) {
    final closest = (_candidates[i] ?? const <Person>[]).firstOrNull;
    if (closest == null) return;
    _targets[i] = closest.id;
    _defaulted.add(i);
  }

  @override
  void initState() {
    super.initState();
    if (widget.pickOnOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _pick();
      });
    }
  }

  Future<void> _pick() async {
    if (_busy) return;
    setState(() {
      _error = null;
      _done = null;
    });
    try {
      final paths = await (widget.pickFiles ?? _pickWithSystemBrowser)();
      if (paths.isEmpty || !mounted) return;
      setState(() => _reading = true);
      final export = await (widget.readFiles ?? readConversationFiles)(paths);
      final people = await widget.personStore.listAll();
      if (!mounted) return;
      // Rows needing a choice first; the rest by how much was said, so
      // the chats that matter most come first, known or not.
      int rank(ConversationPerson row) {
        final c = importCandidates(row.name, people);
        if (c.isEmpty) return 1;
        final same = c.where(
          (p) => p.name.trim().toLowerCase() == row.name.trim().toLowerCase(),
        );
        return same.length == 1 ? 1 : 0;
      }

      final ranks = {for (final row in export.people) row: rank(row)};
      final rows = [...export.people]
        ..sort(
          (a, b) => ranks[a] != ranks[b]
              ? ranks[a]!.compareTo(ranks[b]!)
              : b.messages.length.compareTo(a.messages.length),
        );
      setState(() {
        _people = people;
        _found = rows;
        _skippedLines = export.skipped;
        _candidates = {
          for (final (i, row) in rows.indexed)
            i: importCandidates(row.name, people),
        };
        _names.clear();
        _targets.clear();
        _defaulted.clear();
        _accepted.clear();
        for (var i = 0; i < rows.length; i++) {
          _defaultAttach(i);
          if (_taken(i)) _accepted.add(i);
        }
        if (rows.isEmpty) {
          _error = AppLocalizations.of(context)!.conversationsNothing;
        }
      });
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = failureText(AppLocalizations.of(context)!, error),
        );
      }
    } finally {
      if (mounted) setState(() => _reading = false);
    }
  }

  /// Someone already here, a new person under this name, or another name
  /// — found in People or typed for a new person.
  Future<void> _resolve(int i) async {
    final choice = await chooseImportName(
      context,
      name: _nameOf(i),
      candidates: _candidates[i] ?? const [],
      everyone: _people,
    );
    if (choice == null || !mounted) return;
    setState(() {
      _defaulted.remove(i);
      switch (choice) {
        case ImportRename(:final name):
          _names[i] = name;
          _targets.remove(i);
          _newPeople.remove(i);
          _candidates[i] = importCandidates(name, _people);
          _defaultAttach(i);
          // A name nobody has, typed on purpose: they're new.
          if (!_taken(i)) _newPeople.add(i);
        case ImportMerge(:final personId):
          _targets[i] = personId;
          _newPeople.remove(i);
        case ImportAsNew():
          _targets.remove(i);
          _newPeople.add(i);
      }
      _accepted.add(i);
    });
    if (_waiting(i)) await _resolve(i);
  }

  Future<void> _apply() async {
    if (_busy) return;
    final rows = _ready..sort();
    final total = rows.fold(0, (n, i) => n + _found[i].messages.length);
    setState(() {
      _error = null;
      _progress = (0, total);
    });
    final l10n = AppLocalizations.of(context)!;
    try {
      var written = 0;
      var added = 0;
      // One new person per name, however many rows carry it.
      final made = <String, String>{};
      for (final i in rows) {
        if (_targets.containsKey(i)) continue;
        final name = _nameOf(i).trim();
        _targets[i] = made[name.toLowerCase()] ??=
            (await widget.personStore.create(name: name)).id;
      }
      for (final i in rows) {
        final base = written;
        added += await _store.insert(
          _targets[i]!,
          _found[i].messages,
          onProgress: (n) {
            if (mounted) setState(() => _progress = (base + n, total));
          },
        );
        written += _found[i].messages.length;
      }
      await applyConversationSpans(widget.personStore, store: _store);
      final people = {for (final i in rows) _targets[i]!}.length;
      if (!mounted) return;
      setState(() {
        _done = l10n.conversationsDone(added, people, total - added);
        _found = const [];
        _accepted.clear();
      });
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = failureText(AppLocalizations.of(context)!, error),
        );
      }
    } finally {
      if (mounted) setState(() => _progress = null);
    }
  }

  static Future<List<String>> _pickWithSystemBrowser() async {
    final picked = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['jsonl', 'zip'],
    );
    return [for (final f in picked) ?f.path];
  }

  String? _matchLabel(AppLocalizations l10n, int i) {
    final candidates = _candidates[i] ?? const [];
    if (_defaulted.contains(i)) {
      final into = candidates.first;
      final others = candidates.length - 1;
      if (others == 0 && _sameName(i, into)) {
        return l10n.conversationsAttachingDefault;
      }
      return others == 0
          ? l10n.conversationsAttachingClosest(into.name)
          : l10n.conversationsAttachingClosestOf(into.name, others);
    }
    if (_newPeople.contains(i)) return l10n.conversationsNewPerson(_nameOf(i));
    if (_targets[i] case final id?) {
      final into = _people.where((p) => p.id == id).firstOrNull;
      return l10n.conversationsAttachTo(into?.name ?? _nameOf(i));
    }
    if (candidates.isEmpty) return l10n.conversationsNotInPeople;
    final same = candidates.where((p) => _sameName(i, p)).length;
    if (same > 1) return l10n.importSharedName(same);
    return l10n.profileCsvSimilarChoose(
      candidates.map((p) => p.name).join(', '),
    );
  }

  String _range(ConversationPerson row) {
    final format = DateFormat.yMMMd();
    final first = format.format(row.first!);
    final last = format.format(row.last!);
    return first == last ? first : '$first – $last';
  }

  Widget _row(AppLocalizations l10n, int i) {
    final row = _found[i];
    final targeted = _targets.containsKey(i);
    final nobody = !_taken(i) && !targeted && !_newPeople.contains(i);
    final orange = _waiting(i) || _defaulted.contains(i);
    return GestureDetector(
      key: ValueKey('conversation-row-$i'),
      behavior: HitTestBehavior.opaque,
      onTap: _busy ? null : () => _resolve(i),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _nameOf(i),
                    style: nobody
                        ? settingsRowTitleStyle.copyWith(
                            color: settingsTertiary,
                          )
                        : settingsRowTitleStyle,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    l10n.conversationsRowStats(
                      row.messages.length,
                      _range(row),
                    ),
                    style: settingsFooterStyle,
                  ),
                  if (_matchLabel(l10n, i) case final label?)
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: 13,
                        color: nobody
                            ? settingsTertiary
                            : orange
                            ? CupertinoColors.systemOrange
                            : settingsAccent,
                      ),
                    ),
                ],
              ),
            ),
            CupertinoButton(
              key: ValueKey('conversation-preview-$i'),
              padding: const EdgeInsets.symmetric(horizontal: 6),
              minimumSize: const Size(36, 36),
              onPressed: () => Navigator.of(context).push(
                CupertinoPageRoute<void>(
                  builder: (_) => _PreviewScreen(row: row),
                ),
              ),
              child: const Icon(CupertinoIcons.chat_bubble_2, size: 22),
            ),
            CupertinoSwitch(
              value: _accepted.contains(i) && !nobody,
              onChanged: nobody || _busy
                  ? null
                  : (on) => setState(
                      () => on ? _accepted.add(i) : _accepted.remove(i),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final progress = _progress;
    final selectable = [
      for (var i = 0; i < _found.length; i++)
        if (_taken(i) || _targets.containsKey(i)) i,
    ];
    final allOn = selectable.every(_accepted.contains);
    final ready = _ready.length;
    final needChoice = _needChoice;
    return PopScope(
      canPop: progress == null,
      child: CupertinoPageScaffold(
        backgroundColor: settingsPageBackground,
        navigationBar: CupertinoNavigationBar(
          middle: Text(l10n.conversationsImportTitle),
          backgroundColor: settingsPageBackground,
        ),
        child: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.only(top: 12, bottom: 32),
                  children: [
                    SettingsSection(
                      heading: l10n.conversationsImportTitle,
                      hint: l10n.conversationsImportHint,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                          child: CupertinoButton(
                            key: const ValueKey('conversationsChooseFiles'),
                            color: settingsControlFill,
                            onPressed: _busy ? null : _pick,
                            child: Text(l10n.conversationsChooseFiles),
                          ),
                        ),
                      ],
                    ),
                    if (_reading) ...[
                      const SizedBox(height: 20),
                      const CupertinoActivityIndicator(),
                      const SizedBox(height: 8),
                      Center(
                        child: Text(
                          l10n.conversationsReading,
                          style: settingsHintStyle,
                        ),
                      ),
                    ],
                    if (_done case final done?) ...[
                      const SizedBox(height: 16),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Text(
                          done,
                          key: const ValueKey('conversationsDone'),
                          style: settingsRowSubtitleStyle,
                        ),
                      ),
                    ],
                    if (_error case final error?) ...[
                      const SizedBox(height: 16),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Text(
                          error,
                          style: const TextStyle(color: settingsError),
                        ),
                      ),
                    ],
                    if (_found.isNotEmpty) ...[
                      const SizedBox(height: 20),
                      SettingsSection(
                        heading: l10n.conversationsReviewHeading(_found.length),
                        hint: _skippedLines > 0
                            ? l10n.conversationsSkippedLines(_skippedLines)
                            : null,
                        action: selectable.isEmpty
                            ? null
                            : CupertinoButton(
                                padding: EdgeInsets.zero,
                                onPressed: _busy
                                    ? null
                                    : () => setState(
                                        () => allOn
                                            ? _accepted.clear()
                                            : _accepted.addAll(selectable),
                                      ),
                                child: Text(
                                  allOn
                                      ? l10n.profileCsvSelectNone
                                      : l10n.profileCsvSelectAll,
                                  style: const TextStyle(
                                    fontSize: 13,
                                    color: settingsAccent,
                                  ),
                                ),
                              ),
                        children: [
                          for (var i = 0; i < _found.length; i++) _row(l10n, i),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              // Pinned: with hundreds of names the button would be a long
              // scroll away.
              if (_found.isNotEmpty)
                Container(
                  padding: const EdgeInsets.only(top: 10, bottom: 8),
                  decoration: const BoxDecoration(
                    color: settingsPageBackground,
                    border: Border(top: BorderSide(color: Color(0xFF38383A))),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (needChoice > 0)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
                          child: Text(
                            l10n.importNeedsChoice(needChoice),
                            key: const ValueKey('importNeedsChoice'),
                            style: const TextStyle(
                              fontSize: 13,
                              color: CupertinoColors.systemOrange,
                            ),
                          ),
                        ),
                      if (progress != null)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                          child: Row(
                            children: [
                              const CupertinoActivityIndicator(),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  l10n.conversationsImporting(
                                    progress.$1,
                                    progress.$2,
                                  ),
                                  style: settingsHintStyle,
                                ),
                              ),
                            ],
                          ),
                        ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: CupertinoButton.filled(
                          key: const ValueKey('conversationsApply'),
                          onPressed: ready == 0 || _busy || needChoice > 0
                              ? null
                              : _apply,
                          child: Text(l10n.conversationsApply(ready)),
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

/// One name's messages before anything is imported: what was said, the
/// chats it came from and every name they went by — enough to tell who
/// it is, and whether they're worth keeping.
class _PreviewScreen extends StatefulWidget {
  const _PreviewScreen({required this.row});

  final ConversationPerson row;

  @override
  State<_PreviewScreen> createState() => _PreviewScreenState();
}

class _PreviewScreenState extends State<_PreviewScreen> {
  late final List<ConversationMessage> _all = [...widget.row.messages]
    ..sort((a, b) => b.at.compareTo(a.at));
  late final List<String> _names = () {
    final c = <String, int>{};
    for (final m in _all) {
      if (!m.fromMe && m.sender.isNotEmpty) {
        c[m.sender] = (c[m.sender] ?? 0) + 1;
      }
    }
    return (c.entries.toList()..sort((a, b) => b.value - a.value))
        .map((e) => e.key)
        .take(12)
        .toList();
  }();
  late final List<String> _chats = {for (final m in _all) m.chat}.toList();
  List<ConversationMessage> _shown = const [];
  String _query = '';

  @override
  void initState() {
    super.initState();
    _shown = _all;
  }

  void _search(String q) => setState(() {
    _query = q.trim().toLowerCase();
    _shown = _query.isEmpty
        ? _all
        : [
            for (final m in _all)
              if (m.text.toLowerCase().contains(_query)) m,
          ];
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final width = MediaQuery.sizeOf(context).width * 0.75;
    return CupertinoPageScaffold(
      backgroundColor: settingsPageBackground,
      navigationBar: CupertinoNavigationBar(
        backgroundColor: settingsPageBackground,
        middle: Text(widget.row.name),
      ),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Text(
                [
                  l10n.conversationsPreviewNames(_names.join(', ')),
                  l10n.conversationsPreviewChats(_chats.join(', ')),
                ].join('\n'),
                style: settingsFooterStyle,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: CupertinoSearchTextField(
                autocorrect: false,
                onChanged: _search,
              ),
            ),
            Expanded(
              child: ListView.builder(
                reverse: true,
                itemCount: _shown.length,
                itemBuilder: (context, i) {
                  final m = _shown[i];
                  final mine = m.fromMe;
                  return Align(
                    alignment: mine
                        ? Alignment.centerRight
                        : Alignment.centerLeft,
                    child: Container(
                      constraints: BoxConstraints(maxWidth: width),
                      margin: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 2,
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: mine
                            ? CupertinoTheme.of(context).primaryColor
                            : const Color(0xFF3A3A3C),
                        borderRadius: const BorderRadius.all(
                          Radius.circular(16),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (!mine)
                            Text(
                              m.sender,
                              style: const TextStyle(
                                fontSize: 11,
                                color: Color(0xB3FFFFFF),
                              ),
                            ),
                          Text(
                            m.text.isEmpty ? '[${m.kind}]' : m.text,
                            style: const TextStyle(
                              fontSize: 15,
                              color: CupertinoColors.white,
                            ),
                          ),
                          Text(
                            DateFormat.yMMMd().add_jm().format(m.at),
                            style: const TextStyle(
                              fontSize: 10,
                              color: Color(0xB3FFFFFF),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
