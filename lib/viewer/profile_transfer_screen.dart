import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../l10n/app_localizations.dart';
import '../l10n/failure_text.dart';
import '../photos/person_detail.dart';
import '../photos/person_store.dart';
import '../photos/profile_csv.dart';
import '../photos/profile_transfer.dart';
import '../settings/settings_section.dart';
import '../vault/keys.dart';
import 'person_target_sheet.dart';

/// Profiles to a spreadsheet and back — the People registry as a file you
/// own, editable in anything, and readable without this app.
///
/// Export is one tap to the share sheet. Import shows what the file holds
/// before any of it is written, because a spreadsheet row is a claim about a
/// real person and the file has been somewhere this app cannot see.
enum ProfileTransferStart { import, export }

class ProfileTransferScreen extends StatefulWidget {
  const ProfileTransferScreen({
    super.key,
    required this.personStore,
    this.passcodeHash = openNamespace,
    this.keys,
    this.pickFile,
    this.share,
    this.temporaryDirectory,
    this.start,
  });

  /// Run at once on opening: the People menu's Import or Export.
  final ProfileTransferStart? start;

  final PersonStore personStore;
  final String passcodeHash;
  final AlbumKeys? keys;

  /// Overridable so a test never opens the system file browser.
  final Future<({String name, List<int> bytes})?> Function()? pickFile;

  /// Overridable so a test never raises the share sheet.
  final Future<void> Function(File file)? share;

  final Future<Directory> Function()? temporaryDirectory;

  @override
  State<ProfileTransferScreen> createState() => _ProfileTransferScreenState();
}

class _ProfileTransferScreenState extends State<ProfileTransferScreen> {
  late final ProfileTransfer _transfer = ProfileTransfer(
    store: widget.personStore,
    passcodeHash: widget.passcodeHash,
    keys: widget.keys,
  );

  bool _busy = false;
  String? _error;
  String? _done;
  String _fileName = '';
  List<ProfileCsvRow> _found = const [];
  List<ProfileCsvNote> _notes = const [];

  /// Which rows are in. All of them: this
  /// file is the reader's own data, and pre-ticking a 200-row spreadsheet is
  /// the difference between a list to check and 200 switches to flip.
  final Set<int> _accepted = {};

  /// Who a shared name goes to, by row, as the user picked.
  PersonMatches _matches = PersonMatches(const []);
  final Map<int, PersonTarget> _targets = {};

  bool get _unresolved => _accepted.any(
    (i) => _matches.ambiguous(_found[i].name) && !_targets.containsKey(i),
  );

  Future<void> _resolve(int i) async {
    final target = await pickPersonTarget(
      context,
      name: _found[i].name,
      candidates: _matches.of(_found[i].name),
      personStore: widget.personStore,
    );
    if (target != null && mounted) setState(() => _targets[i] = target);
  }

  @override
  void initState() {
    super.initState();
    if (widget.start case final start?) {
      // After the first frame: both read the l10n off the context.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        start == ProfileTransferStart.import ? _pick() : _export();
      });
    }
  }

  Future<void> _export() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _done = null;
    });
    final l10n = AppLocalizations.of(context)!;
    try {
      final rows = await _transfer.read();
      if (rows.isEmpty) {
        setState(() => _error = l10n.profileCsvNobodyToExport);
        return;
      }
      final dir = await (widget.temporaryDirectory ?? getTemporaryDirectory)();
      final file = File(p.join(dir.path, 'profiles.csv'));
      await file.writeAsString(writeProfileCsv(rows));
      await (widget.share ?? _shareWithSystemSheet)(file);
      if (mounted) setState(() => _done = l10n.profileCsvExported(rows.length));
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = failureText(AppLocalizations.of(context)!, error),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pick() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _done = null;
      _found = const [];
      _notes = const [];
      _accepted.clear();
    });
    final l10n = AppLocalizations.of(context)!;
    try {
      final picked = await (widget.pickFile ?? _pickWithSystemBrowser)();
      if (picked == null) return;
      final file = readProfileCsv(_decode(picked.bytes));
      final matches = PersonMatches(await widget.personStore.listAll());
      if (!mounted) return;
      setState(() {
        _matches = matches;
        _targets.clear();
        _fileName = picked.name;
        _found = file.rows;
        _notes = file.notes;
        _accepted.addAll(List.generate(file.rows.length, (i) => i));
        if (file.rows.isEmpty && file.notes.isEmpty) {
          _error = l10n.profileCsvNoRows;
        }
      });
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = failureText(AppLocalizations.of(context)!, error),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// UTF-8 where it can be, and bytes-as-characters where it cannot — a file
  /// out of a spreadsheet in a Latin-1 locale should still import its names
  /// rather than fail whole.
  static String _decode(List<int> bytes) {
    try {
      return utf8.decode(bytes);
    } on FormatException {
      return latin1.decode(bytes, allowInvalid: true);
    }
  }

  Future<void> _apply() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final l10n = AppLocalizations.of(context)!;
    try {
      final rows = _accepted.toList()..sort();
      final result = await _transfer.write(
        [for (final index in rows) _found[index]],
        targets: [for (final index in rows) _targets[index]],
      );
      if (!mounted) return;
      setState(() {
        _done = l10n.profileCsvImported(result.created, result.updated);
        _found = const [];
        _notes = const [];
        _accepted.clear();
      });
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = failureText(AppLocalizations.of(context)!, error),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static Future<({String name, List<int> bytes})?>
  _pickWithSystemBrowser() async {
    final picked = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['csv'],
    );
    final file = picked.firstOrNull;
    if (file == null) return null;
    return (name: file.name, bytes: await file.readAsBytes());
  }

  static Future<void> _shareWithSystemSheet(File file) =>
      SharePlus.instance.share(ShareParams(files: [XFile(file.path)]));

  String _noteText(AppLocalizations l10n, ProfileCsvNote note) =>
      switch (note.problem) {
        ProfileCsvProblem.noHeader => l10n.profileCsvNoHeader,
        ProfileCsvProblem.noNameColumn => l10n.profileCsvNoNameColumn,
        ProfileCsvProblem.missingName => l10n.profileCsvMissingName(note.line),
      };

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return CupertinoPageScaffold(
      backgroundColor: settingsPageBackground,
      navigationBar: CupertinoNavigationBar(
        middle: Text(l10n.profileCsvTitle),
        backgroundColor: settingsPageBackground,
      ),
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.only(top: 12, bottom: 32),
          children: [
            SettingsSection(
              heading: l10n.profileCsvTitle,
              hint: l10n.profileCsvHint,
              footer: Text(l10n.profileCsvColumns, style: settingsFooterStyle),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: CupertinoButton.filled(
                    onPressed: _busy ? null : _export,
                    child: Text(l10n.profileCsvExportButton),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: CupertinoButton(
                    color: settingsControlFill,
                    onPressed: _busy ? null : _pick,
                    child: Text(l10n.profileCsvImportButton),
                  ),
                ),
              ],
            ),
            if (_done case final done?) ...[
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(done, style: settingsRowSubtitleStyle),
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
            if (_notes.isNotEmpty) ...[
              const SizedBox(height: 16),
              for (final note in _notes)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 2, 16, 0),
                  child: Text(
                    _noteText(l10n, note),
                    style: const TextStyle(color: settingsError, fontSize: 12),
                  ),
                ),
            ],
            if (_found.isNotEmpty) ...[
              const SizedBox(height: 20),
              SettingsSection(
                heading: l10n.profileCsvReviewHeading(_found.length),
                hint: _fileName,
                action: CupertinoButton(
                  padding: EdgeInsets.zero,
                  onPressed: () => setState(() {
                    if (_accepted.length == _found.length) {
                      _accepted.clear();
                    } else {
                      _accepted.addAll(List.generate(_found.length, (i) => i));
                    }
                  }),
                  child: Text(
                    _accepted.length == _found.length
                        ? l10n.profileCsvSelectNone
                        : l10n.profileCsvSelectAll,
                    style: const TextStyle(fontSize: 13, color: settingsAccent),
                  ),
                ),
                children: [
                  for (var i = 0; i < _found.length; i++)
                    CupertinoListTile(
                      key: ValueKey('profile-row-$i'),
                      backgroundColor: settingsPageBackground,
                      title: Text(_found[i].name),
                      subtitle: _matches.ambiguous(_found[i].name)
                          ? Text(
                              personTargetLabel(
                                l10n,
                                _targets[i],
                                _matches.of(_found[i].name),
                              ),
                              style: TextStyle(
                                color: _targets[i] == null
                                    ? CupertinoColors.systemOrange
                                    : settingsAccent,
                              ),
                            )
                          : Text(l10n.profileCsvRowItems(_found[i].itemCount)),
                      onTap: _matches.ambiguous(_found[i].name)
                          ? () => _resolve(i)
                          : null,
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
                  onPressed: _accepted.isEmpty || _busy || _unresolved
                      ? null
                      : _apply,
                  child: Text(l10n.profileCsvApply(_accepted.length)),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
