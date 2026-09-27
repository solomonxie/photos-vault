import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../l10n/app_localizations.dart';
import '../photos/person_detail.dart';
import '../photos/person_store.dart';
import '../photos/profile_csv.dart';
import '../photos/profile_transfer.dart';
import '../settings/settings_section.dart';
import '../vault/keys.dart';

/// Profiles to a spreadsheet and back — the People registry as a file you
/// own, editable in anything, and readable without this app.
///
/// Export is one tap to the share sheet. Import shows what the file holds
/// before any of it is written, because a spreadsheet row is a claim about a
/// real person and the file has been somewhere this app cannot see.
class ProfileTransferScreen extends StatefulWidget {
  const ProfileTransferScreen({
    super.key,
    required this.personStore,
    this.passcodeHash = openNamespace,
    this.keys,
    this.pickFile,
    this.share,
    this.temporaryDirectory,
  });

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

  /// Which rows are in. All of them, unlike the AI autofill's review: this
  /// file is the reader's own data, and pre-ticking a 200-row spreadsheet is
  /// the difference between a list to check and 200 switches to flip.
  final Set<int> _accepted = {};

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
      if (mounted) setState(() => _error = '$error');
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
      if (!mounted) return;
      setState(() {
        _fileName = picked.name;
        _found = file.rows;
        _notes = file.notes;
        _accepted.addAll(List.generate(file.rows.length, (i) => i));
        if (file.rows.isEmpty && file.notes.isEmpty) {
          _error = l10n.profileCsvNoRows;
        }
      });
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
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
      final result = await _transfer.write([
        for (final index in _accepted.toList()..sort()) _found[index],
      ]);
      if (!mounted) return;
      setState(() {
        _done = l10n.profileCsvImported(result.created, result.updated);
        _found = const [];
        _notes = const [];
        _accepted.clear();
      });
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static Future<({String name, List<int> bytes})?>
  _pickWithSystemBrowser() async {
    final picked = await FilePicker.pickFiles(type: FileType.any);
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
                      subtitle: Text(
                        l10n.profileCsvRowItems(_found[i].itemCount),
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
                  onPressed: _accepted.isEmpty || _busy ? null : _apply,
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
