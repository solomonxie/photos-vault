import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';

import '../l10n/app_localizations.dart';
import '../l10n/failure_text.dart';
import '../photos/face_file.dart';
import '../photos/face_import.dart';
import '../settings/settings_section.dart';

/// A `faces.json` in: what it would name, shown before anything is
/// written, then one tap to apply. See `docs/design/face-recognition`.
class FaceImportScreen extends StatefulWidget {
  const FaceImportScreen({super.key, required this.import, this.pickFile});

  final FaceImport import;

  /// Overridable so a test never opens the system file browser.
  final Future<({String name, List<int> bytes})?> Function()? pickFile;

  @override
  State<FaceImportScreen> createState() => _FaceImportScreenState();
}

class _FaceImportScreenState extends State<FaceImportScreen> {
  static const _shownConflicts = 100;

  bool _busy = false;
  String? _error;
  String? _done;
  String _fileName = '';
  FaceImportPlan? _plan;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _pick();
    });
  }

  Future<void> _pick() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _done = null;
      _plan = null;
    });
    try {
      final picked = await (widget.pickFile ?? _pickWithSystemBrowser)();
      if (picked == null) return;
      final plan = await widget.import.plan(await readFaceFile(picked.bytes));
      if (!mounted) return;
      setState(() {
        _fileName = picked.name;
        _plan = plan;
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

  Future<void> _apply() async {
    final plan = _plan;
    if (_busy || plan == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final l10n = AppLocalizations.of(context)!;
    try {
      final result = await widget.import.commit(plan);
      if (!mounted) return;
      setState(() {
        _done = [
          if (result.faces > 0 || result.grouped == 0)
            l10n.faceImportDone(result.faces, result.people),
          if (result.grouped > 0) l10n.faceImportGroupedDone(result.grouped),
        ].join(' ');
        _plan = null;
      });
    } catch (error) {
      if (mounted) setState(() => _error = failureText(l10n, error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static Future<({String name, List<int> bytes})?>
  _pickWithSystemBrowser() async {
    final picked = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['json'],
    );
    final file = picked.firstOrNull;
    if (file == null) return null;
    return (name: file.name, bytes: await file.readAsBytes());
  }

  String _conflictText(AppLocalizations l10n, FaceImportConflict c) =>
      c.sharedBy > 1
      ? l10n.faceImportSharedName(c.sharedBy, c.fileName)
      : l10n.faceImportNamedHere(c.fileName, c.appName ?? '?');

  Widget _line(String text, {Color? color}) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
    child: Text(
      text,
      style: color == null
          ? settingsRowSubtitleStyle
          : TextStyle(color: color, fontSize: 13),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final plan = _plan;
    return CupertinoPageScaffold(
      backgroundColor: settingsPageBackground,
      navigationBar: CupertinoNavigationBar(
        middle: Text(l10n.faceImportTitle),
        backgroundColor: settingsPageBackground,
      ),
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.only(top: 12, bottom: 32),
          children: [
            SettingsSection(
              heading: l10n.faceImportTitle,
              hint: l10n.faceImportHint,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: CupertinoButton(
                    color: settingsControlFill,
                    onPressed: _busy ? null : _pick,
                    child: Text(l10n.faceImportPickAnother),
                  ),
                ),
              ],
            ),
            if (_busy && plan == null) ...[
              const SizedBox(height: 16),
              _line(l10n.faceImportReading),
            ],
            if (_done case final done?) ...[
              const SizedBox(height: 16),
              _line(done),
            ],
            if (_error case final error?) ...[
              const SizedBox(height: 16),
              _line(error, color: settingsError),
            ],
            if (plan != null) ...[
              const SizedBox(height: 20),
              SettingsSection(
                heading: _fileName,
                children: [
                  _line(l10n.faceImportFaces(plan.links.length)),
                  if (plan.newPeople.isNotEmpty)
                    _line(
                      '${l10n.faceImportNewPeople(plan.newPeople.length)}: '
                      '${plan.newPeople.join(', ')}',
                    ),
                  if (plan.grouped.isNotEmpty)
                    _line(
                      l10n.faceImportGrouped(
                        plan.grouped.length,
                        plan.groups.length,
                      ),
                    ),
                  if (plan.namedNotGrouped > 0)
                    _line(l10n.faceImportNamedNotGrouped(plan.namedNotGrouped)),
                  if (plan.unchanged > 0)
                    _line(l10n.faceImportUnchanged(plan.unchanged)),
                  if (plan.skippedPhotos > 0)
                    _line(l10n.faceImportSkipped(plan.skippedPhotos)),
                  if (plan.unreadable > 0)
                    _line(l10n.faceImportUnreadable(plan.unreadable)),
                  if (plan.links.isEmpty && plan.grouped.isEmpty)
                    _line(
                      l10n.faceImportNothing,
                      color: CupertinoColors.systemOrange,
                    ),
                ],
              ),
              if (plan.conflicts.isNotEmpty) ...[
                const SizedBox(height: 20),
                SettingsSection(
                  heading: l10n.faceImportConflicts(plan.conflicts.length),
                  primary: false,
                  children: [
                    for (final c in plan.conflicts.take(_shownConflicts))
                      CupertinoListTile(
                        backgroundColor: settingsPageBackground,
                        title: Text(_conflictText(l10n, c)),
                        subtitle: Text(c.photo),
                      ),
                    if (plan.conflicts.length > _shownConflicts)
                      _line(
                        l10n.faceImportMore(
                          plan.conflicts.length - _shownConflicts,
                        ),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: CupertinoButton.filled(
                  key: const ValueKey('faceImportApply'),
                  onPressed:
                      (plan.links.isEmpty && plan.grouped.isEmpty) || _busy
                      ? null
                      : _apply,
                  child: Text(
                    plan.grouped.isEmpty
                        ? l10n.faceImportApply(plan.links.length)
                        : l10n.faceImportApplyAll,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
