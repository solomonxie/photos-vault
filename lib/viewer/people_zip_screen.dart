import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:path_provider/path_provider.dart';

import '../l10n/app_localizations.dart';
import '../l10n/failure_text.dart';
import '../photos/people_zip.dart';
import '../photos/person.dart';
import '../photos/person_store.dart';
import '../photos/profile_transfer.dart';
import '../settings/settings_section.dart';
import '../storage/asset_record_store.dart';
import '../vault/passcode_tags.dart';
import 'person_target_sheet.dart';
import 'private_album_gate.dart';

/// People ⋯ → Import People Zip: what the zip holds, person by person —
/// import or not, hide or not, and which photos — before anything is
/// written. See `docs/design/people-zip-import/DESIGN.md`.
class PeopleZipScreen extends StatefulWidget {
  const PeopleZipScreen({
    super.key,
    required this.personStore,
    required this.assetRecordStore,
    this.pickZip,
    this.workDir,
    this.importer,
    this.askCode,
  });

  final PersonStore personStore;
  final AssetRecordStore assetRecordStore;

  /// Overridable so a test never opens the file browser; null path is a
  /// cancel.
  final Future<String?> Function()? pickZip;
  final Future<Directory> Function()? workDir;
  final PeopleZipImporter? importer;
  final Future<String?> Function(BuildContext context)? askCode;

  @override
  State<PeopleZipScreen> createState() => _PeopleZipScreenState();
}

class _PeopleZipScreenState extends State<PeopleZipScreen> {
  PeopleZip? _zip;
  List<PeopleZipPick> _picks = const [];
  PersonMatches _matches = PersonMatches(const []);
  bool _opening = false;
  String? _error;
  (int, int)? _progress;
  PeopleZipResult? _result;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _pick());
  }

  @override
  void dispose() {
    // Mid-import the run owns the folder and discards it when done.
    if (_progress == null) unawaited(_zip?.discard());
    super.dispose();
  }

  static Future<String?> _pickWithSystemBrowser() async {
    final picked = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['zip'],
    );
    return picked.firstOrNull?.path;
  }

  Future<void> _pick() async {
    if (_opening || _progress != null) return;
    final path = await (widget.pickZip ?? _pickWithSystemBrowser)();
    if (path == null || !mounted) {
      if (_zip == null && mounted) Navigator.of(context).maybePop();
      return;
    }
    setState(() {
      _opening = true;
      _error = null;
      _result = null;
    });
    try {
      await _zip?.discard();
      final zip = await PeopleZip.open(
        path,
        await (widget.workDir ?? getTemporaryDirectory)(),
      );
      // The picker's own copy of the zip: unpacked, so no longer needed.
      if (widget.pickZip == null) {
        unawaited(FilePicker.clearTemporaryFiles().catchError((_) {}));
      }
      final matches = PersonMatches(await widget.personStore.listAll());
      if (!mounted) {
        await zip.discard();
        return;
      }
      setState(() {
        _zip = zip;
        _matches = matches;
        _picks = [for (final person in zip.people) PeopleZipPick(person)];
      });
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = failureText(AppLocalizations.of(context)!, error),
        );
      }
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  bool get _unresolved => _picks.any(
    (p) => p.include && _matches.ambiguous(p.person.name) && p.target == null,
  );

  Future<void> _resolve(PeopleZipPick pick) async {
    final target = await pickPersonTarget(
      context,
      name: pick.person.name,
      candidates: _matches.of(pick.person.name),
      personStore: widget.personStore,
    );
    if (target != null && mounted) setState(() => pick.target = target);
  }

  int get _photoCount =>
      _picks.where((p) => p.include).fold(0, (n, p) => n + p.photos.length);

  Future<void> _import() async {
    final zip = _zip;
    if (zip == null || _progress != null) return;
    String? code;
    if (_picks.any((p) => p.include && p.hide)) {
      code = await (widget.askCode ?? _askCode)(context);
      if (code == null || !mounted) return;
    }
    final importer =
        widget.importer ??
        PeopleZipImporter(
          personStore: widget.personStore,
          recordStore: widget.assetRecordStore,
          tagFor: PasscodeTags(
            records: widget.assetRecordStore,
            people: widget.personStore,
          ).tagFor,
        );
    setState(() => _progress = (0, _photoCount));
    PeopleZipResult result;
    try {
      result = await importer.run(
        _picks,
        code: code,
        onProgress: (done, total) {
          if (mounted) setState(() => _progress = (done, total));
        },
      );
    } catch (error) {
      if (mounted) {
        setState(() {
          _progress = null;
          _error = failureText(AppLocalizations.of(context)!, error);
        });
      }
      return;
    } finally {
      await zip.discard();
    }
    if (!mounted) return;
    setState(() {
      _progress = null;
      _zip = null;
      _picks = const [];
      _result = result;
    });
  }

  static Future<String?> _askCode(BuildContext context) async =>
      (await askHideCodeOnce(context, convertible: 0))?.code;

  void _preview(PeopleZipPick pick) => Navigator.of(context).push(
    CupertinoPageRoute<void>(
      builder: (_) => _PersonPhotosScreen(
        pick: pick,
        onChanged: () {
          if (mounted) setState(() {});
        },
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final included = _picks.where((p) => p.include).length;
    final progress = _progress;
    // Leaving mid-run would lose the summary; the run itself would finish.
    return PopScope(
      canPop: progress == null,
      child: CupertinoPageScaffold(
        backgroundColor: settingsPageBackground,
        navigationBar: CupertinoNavigationBar(
          backgroundColor: settingsPageBackground,
          middle: Text(l10n.peopleZipTitle),
          trailing: _picks.isEmpty || progress != null
              ? null
              : SettingsAccentButton(
                  label: included == _picks.length
                      ? l10n.selectionDeselectAll
                      : l10n.selectionSelectAll,
                  onPressed: () => setState(() {
                    final all = included != _picks.length;
                    for (final pick in _picks) {
                      pick.include = all;
                    }
                  }),
                ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              Expanded(child: _body(l10n)),
              if (_picks.isNotEmpty) _footer(l10n, included, progress),
            ],
          ),
        ),
      ),
    );
  }

  Widget _body(AppLocalizations l10n) {
    if (_opening) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CupertinoActivityIndicator(),
            const SizedBox(height: 10),
            Text(l10n.peopleZipOpening, style: settingsHintStyle),
          ],
        ),
      );
    }
    final message =
        _error ??
        switch (_result) {
          final r? => [
            l10n.peopleZipDone(r.people, r.visible, r.hidden),
            if (r.failed > 0) l10n.peopleZipFailed(r.failed),
          ].join(' '),
          null => null,
        };
    if (_picks.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (message != null)
                Text(
                  message,
                  key: const ValueKey('peopleZipMessage'),
                  textAlign: TextAlign.center,
                  style: settingsRowTitleStyle,
                ),
              const SizedBox(height: 16),
              if (_result != null) ...[
                CupertinoButton.filled(
                  key: const ValueKey('peopleZipDoneButton'),
                  onPressed: () => Navigator.of(context).maybePop(),
                  child: Text(l10n.selectionDone),
                ),
                CupertinoButton(
                  onPressed: _pick,
                  child: Text(l10n.peopleZipPickAnother),
                ),
              ] else
                CupertinoButton.filled(
                  onPressed: _pick,
                  child: Text(l10n.peopleZipPickAnother),
                ),
            ],
          ),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(
        settingsPagePadding,
        8,
        settingsPagePadding,
        16,
      ),
      itemCount: _picks.length + 1,
      separatorBuilder: (_, _) => const SizedBox(height: 6),
      itemBuilder: (context, i) => i == 0
          ? Padding(
              padding: const EdgeInsets.only(bottom: 6, left: 4),
              child: Text(l10n.peopleZipHint, style: settingsHintStyle),
            )
          : _PersonRow(
              key: ValueKey('peopleZip-${_picks[i - 1].person.name}'),
              pick: _picks[i - 1],
              candidates: _matches.of(_picks[i - 1].person.name),
              onResolve: () => _resolve(_picks[i - 1]),
              enabled: _progress == null,
              onChanged: () => setState(() {}),
              onPreview: () => _preview(_picks[i - 1]),
            ),
    );
  }

  Widget _footer(AppLocalizations l10n, int included, (int, int)? progress) =>
      Container(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
        color: settingsPageBackground,
        child: progress != null
            ? Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CupertinoActivityIndicator(),
                  const SizedBox(height: 6),
                  Text(
                    l10n.peopleZipProgress(progress.$1, progress.$2),
                    style: settingsHintStyle,
                  ),
                ],
              )
            : SizedBox(
                width: double.infinity,
                child: CupertinoButton.filled(
                  key: const ValueKey('peopleZipImport'),
                  onPressed: included == 0 || _unresolved ? null : _import,
                  child: Text(l10n.peopleZipImport(included, _photoCount)),
                ),
              ),
      );
}

class _PersonRow extends StatelessWidget {
  const _PersonRow({
    super.key,
    required this.pick,
    required this.candidates,
    required this.onResolve,
    required this.enabled,
    required this.onChanged,
    required this.onPreview,
  });

  final PeopleZipPick pick;

  /// People here with this name; two or more and [onResolve] picks.
  final List<Person> candidates;
  final VoidCallback onResolve;
  final bool enabled;
  final VoidCallback onChanged;
  final VoidCallback onPreview;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final person = pick.person;
    final decode = (44 * MediaQuery.devicePixelRatioOf(context)).round();
    final cover = pick.photos.isEmpty
        ? null
        : person.photos.firstWhere(pick.photos.contains);
    return Container(
      decoration: BoxDecoration(
        color: settingsControlFill,
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.fromLTRB(4, 6, 10, 6),
      child: Row(
        children: [
          CupertinoCheckbox(
            key: ValueKey('peopleZipInclude-${person.name}'),
            value: pick.include,
            onChanged: enabled
                ? (v) {
                    pick.include = v ?? false;
                    onChanged();
                  }
                : null,
          ),
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: person.photos.isEmpty ? null : onPreview,
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(22),
                    child: SizedBox.square(
                      dimension: 44,
                      child: cover == null
                          ? const ColoredBox(
                              color: CupertinoColors.systemGrey4,
                              child: Icon(CupertinoIcons.person_fill),
                            )
                          : Image.file(
                              File(cover),
                              fit: BoxFit.cover,
                              cacheWidth: decode,
                            ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          person.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: settingsRowTitleStyle,
                        ),
                        Text(
                          [
                            l10n.peopleZipPhotos(
                              pick.photos.length,
                              person.photos.length,
                            ),
                            if (candidates.length < 2)
                              candidates.isEmpty
                                  ? l10n.peopleZipNew
                                  : l10n.peopleZipExisting,
                          ].join(' · '),
                          style: settingsHintStyle,
                        ),
                        if (candidates.length > 1)
                          CupertinoButton(
                            key: ValueKey('peopleZipResolve-${person.name}'),
                            padding: EdgeInsets.zero,
                            minimumSize: const Size(0, 28),
                            alignment: Alignment.centerLeft,
                            onPressed: enabled ? onResolve : null,
                            child: Text(
                              personTargetLabel(l10n, pick.target, candidates),
                              style: TextStyle(
                                fontSize: 13,
                                color: pick.target == null
                                    ? CupertinoColors.systemOrange
                                    : settingsAccent,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          CupertinoButton(
            key: ValueKey('peopleZipHide-${person.name}'),
            padding: const EdgeInsets.symmetric(horizontal: 8),
            minimumSize: const Size(44, 44),
            onPressed: enabled && pick.include && person.photos.isNotEmpty
                ? () {
                    pick.hide = !pick.hide;
                    onChanged();
                  }
                : null,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  pick.hide
                      ? CupertinoIcons.eye_slash_fill
                      : CupertinoIcons.eye,
                  size: 20,
                  color: pick.hide ? CupertinoColors.systemOrange : null,
                ),
                Text(
                  pick.hide ? l10n.peopleZipHidden : l10n.libraryHide,
                  style: TextStyle(
                    fontSize: 11,
                    color: pick.hide ? CupertinoColors.systemOrange : null,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One person's photos from the zip; tap to leave one out.
class _PersonPhotosScreen extends StatefulWidget {
  const _PersonPhotosScreen({required this.pick, required this.onChanged});

  final PeopleZipPick pick;
  final VoidCallback onChanged;

  @override
  State<_PersonPhotosScreen> createState() => _PersonPhotosScreenState();
}

class _PersonPhotosScreenState extends State<_PersonPhotosScreen> {
  void _toggle(String path) {
    final photos = widget.pick.photos;
    setState(
      () => photos.contains(path) ? photos.remove(path) : photos.add(path),
    );
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final pick = widget.pick;
    final all = pick.photos.length == pick.person.photos.length;
    final decode = (130 * MediaQuery.devicePixelRatioOf(context)).round();
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(
          '${pick.person.name} · '
          '${pick.photos.length}/${pick.person.photos.length}',
        ),
        trailing: SettingsAccentButton(
          label: all ? l10n.selectionDeselectAll : l10n.selectionSelectAll,
          onPressed: () {
            setState(() {
              pick.photos.clear();
              if (!all) pick.photos.addAll(pick.person.photos);
            });
            widget.onChanged();
          },
        ),
      ),
      child: SafeArea(
        child: GridView.builder(
          padding: const EdgeInsets.all(2),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            mainAxisSpacing: 2,
            crossAxisSpacing: 2,
          ),
          itemCount: pick.person.photos.length,
          itemBuilder: (context, i) {
            final path = pick.person.photos[i];
            final on = pick.photos.contains(path);
            return GestureDetector(
              key: ValueKey('peopleZipPhoto-$i'),
              onTap: () => _toggle(path),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Opacity(
                    opacity: on ? 1 : 0.35,
                    child: Image.file(
                      File(path),
                      fit: BoxFit.cover,
                      cacheWidth: decode,
                      errorBuilder: (_, _, _) =>
                          const ColoredBox(color: CupertinoColors.systemGrey5),
                    ),
                  ),
                  Positioned(
                    right: 6,
                    bottom: 6,
                    child: Icon(
                      on
                          ? CupertinoIcons.checkmark_circle_fill
                          : CupertinoIcons.circle,
                      size: 22,
                      color: on
                          ? CupertinoColors.activeBlue
                          : CupertinoColors.white,
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
