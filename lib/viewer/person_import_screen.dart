import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';

import '../l10n/app_localizations.dart';
import '../l10n/failure_text.dart';
import '../photos/person.dart';
import '../photos/person_owner.dart';
import '../photos/person_store.dart';
import '../settings/settings_section.dart';
import '../storage/asset_record_store.dart';
import 'person_picker_sheet.dart';

/// A file that read fine but holds nothing to import; [message] is shown.
class NothingToImport implements Exception {
  const NothingToImport(this.message);
  final String message;

  @override
  String toString() => message;
}

/// A file read for [PersonImportScreen]: its summary rows, and what doing
/// the import onto one person means.
class PersonImportPlan {
  const PersonImportPlan({required this.rows, required this.run});

  /// (label, value), shown before anything is written.
  final List<(String, String)> rows;

  /// Writes it onto [personId]; reports progress 0..1 and returns what it
  /// did, in a sentence.
  final Future<String> Function(
    String personId,
    void Function(double progress) onProgress,
  )
  run;
}

/// Pick a file, see what is in it, point it at one person, import.
/// Defaults to whose phone this is.
class PersonImportScreen extends StatefulWidget {
  const PersonImportScreen({
    super.key,
    required this.title,
    required this.hint,
    required this.extensions,
    required this.read,
    required this.personStore,
    this.assetRecordStore,
    this.pickOnOpen = false,
    this.pickFile,
  });

  final String title;
  final String hint;
  final List<String> extensions;
  final Future<PersonImportPlan> Function(String path) read;
  final PersonStore personStore;

  /// For whose phone this is; null leaves the person to pick.
  final AssetRecordStore? assetRecordStore;
  final bool pickOnOpen;

  /// Overridable so a test never opens the system file browser.
  final Future<String?> Function()? pickFile;

  @override
  State<PersonImportScreen> createState() => _PersonImportScreenState();
}

class _PersonImportScreenState extends State<PersonImportScreen> {
  PersonImportPlan? _plan;
  Person? _target;
  String? _ownerId;
  List<Person> _people = const [];
  bool _reading = false;
  double? _progress;
  String? _error;
  String? _done;

  bool get _busy => _reading || _progress != null;

  @override
  void initState() {
    super.initState();
    _loadPeople();
    if (widget.pickOnOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _pick();
      });
    }
  }

  Future<void> _loadPeople() async {
    final people = await widget.personStore.listAll();
    final store = widget.assetRecordStore;
    final owner = store == null ? null : await PersonOwner(store).id();
    if (!mounted) return;
    setState(() {
      _people = people;
      _ownerId = owner;
      _target ??= people.where((p) => p.id == owner).firstOrNull;
    });
  }

  Future<String?> _pickWithSystemBrowser() async {
    final picked = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: widget.extensions,
    );
    return picked.firstOrNull?.path;
  }

  Future<void> _pick() async {
    if (_busy) return;
    setState(() {
      _error = null;
      _done = null;
    });
    try {
      final path = await (widget.pickFile ?? _pickWithSystemBrowser)();
      if (path == null || !mounted) return;
      setState(() => _reading = true);
      final plan = await widget.read(path);
      if (mounted) setState(() => _plan = plan);
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

  Future<void> _choosePerson() async {
    final l10n = AppLocalizations.of(context)!;
    final picked = await showPersonPickerSheet(
      context: context,
      candidates: _people,
      personStore: widget.personStore,
      title: l10n.personImportWhose,
      ownerId: _ownerId,
    );
    if (picked == null || !mounted) return;
    setState(() => _target = picked);
    if (!_people.any((p) => p.id == picked.id)) await _loadPeople();
  }

  Future<void> _run() async {
    final plan = _plan;
    final target = _target;
    if (plan == null || target == null || _busy) return;
    setState(() {
      _progress = 0;
      _error = null;
    });
    try {
      final done = await plan.run(target.id, (v) {
        if (mounted) setState(() => _progress = v);
      });
      if (mounted) {
        setState(() {
          _done = done;
          _plan = null;
        });
      }
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

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final plan = _plan;
    final progress = _progress;
    return PopScope(
      canPop: progress == null,
      child: CupertinoPageScaffold(
        backgroundColor: settingsPageBackground,
        navigationBar: CupertinoNavigationBar(
          middle: Text(widget.title),
          backgroundColor: settingsPageBackground,
        ),
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.only(top: 12, bottom: 32),
            children: [
              SettingsSection(
                heading: widget.title,
                hint: widget.hint,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: CupertinoButton(
                      key: const ValueKey('personImportChoose'),
                      color: settingsControlFill,
                      onPressed: _busy ? null : _pick,
                      child: Text(l10n.devChooseFile),
                    ),
                  ),
                ],
              ),
              if (_reading) ...[
                const SizedBox(height: 20),
                const CupertinoActivityIndicator(),
              ],
              if (_error case final error?) ...[
                const SizedBox(height: 12),
                SettingsErrorLine(message: error),
              ],
              if (_done case final done?) ...[
                const SizedBox(height: 16),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    done,
                    key: const ValueKey('personImportDone'),
                    style: settingsRowSubtitleStyle,
                  ),
                ),
              ],
              if (plan != null) ...[
                const SizedBox(height: 24),
                SettingsGroup(
                  children: [
                    for (final (label, value) in plan.rows)
                      SettingsGroupRow(title: label, value: value),
                  ],
                ),
                const SizedBox(height: 24),
                SettingsGroup(
                  children: [
                    SettingsGroupRow(
                      key: const ValueKey('personImportTarget'),
                      title: l10n.personImportWhose,
                      value: _target == null
                          ? l10n.personImportChoosePerson
                          : _target!.id == _ownerId
                          ? '${l10n.ownerPickerMe} · ${_target!.name}'
                          : _target!.name,
                      chevron: true,
                      onTap: _busy ? null : _choosePerson,
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: progress != null
                      ? Column(
                          children: [
                            const CupertinoActivityIndicator(),
                            const SizedBox(height: 8),
                            Text(
                              '${(progress * 100).round()}%',
                              style: settingsHintStyle,
                            ),
                          ],
                        )
                      : CupertinoButton.filled(
                          key: const ValueKey('personImportRun'),
                          onPressed: _target == null ? null : _run,
                          child: Text(l10n.personImportRun),
                        ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
