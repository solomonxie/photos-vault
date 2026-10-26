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
import 'import_name_choice.dart';
import 'private_album_gate.dart';

/// Developer Options → Import People Zip, in two steps: which profiles to add or
/// update, then which photos to load for people already in People — hide
/// or not, and which photos. See `docs/design/people-zip-import/DESIGN.md`.
class PeopleZipScreen extends StatefulWidget {
  const PeopleZipScreen({
    super.key,
    required this.personStore,
    required this.assetRecordStore,
    this.pickZip,
    this.pickZips,
    this.workDir,
    this.importer,
    this.askCode,
  });

  final PersonStore personStore;
  final AssetRecordStore assetRecordStore;

  /// Overridable so a test never opens the file browser; null path is a
  /// cancel.
  final Future<String?> Function()? pickZip;

  /// Several at once, worked through one after another.
  final Future<List<String>?> Function()? pickZips;
  final Future<Directory> Function()? workDir;
  final PeopleZipImporter? importer;
  final Future<String?> Function(BuildContext context)? askCode;

  @override
  State<PeopleZipScreen> createState() => _PeopleZipScreenState();
}

class _PeopleZipScreenState extends State<PeopleZipScreen> {
  PeopleZip? _zip;
  List<PeopleZipPick> _picks = const [];
  List<Person> _people = const [];

  /// Who each row might be, for its name as it stands.
  final Map<PeopleZipPick, List<Person>> _candidates = {};

  List<Person> _candidatesOf(PeopleZipPick pick) =>
      _candidates[pick] ??= importCandidates(pick.displayName, _people);

  /// Rows merged into their one same-name person by default, not by a
  /// tap: orange until the user says otherwise.
  final Set<PeopleZipPick> _defaulted = {};

  Person? _onlySame(PeopleZipPick pick) {
    final same = [
      for (final p in _candidatesOf(pick))
        if (_sameName(pick, p)) p,
    ];
    return same.length == 1 ? same.single : null;
  }

  void _defaultMerge(PeopleZipPick pick) {
    final only = _onlySame(pick);
    if (only == null) return;
    pick.target ??= PersonTarget(only.id);
    _defaulted.add(pick);
  }

  bool _sameName(PeopleZipPick pick, Person p) =>
      p.name.trim().toLowerCase() == pick.displayName.trim().toLowerCase();
  bool _opening = false;
  final bool _writing = false;
  String? _error;
  (int, int)? _progress;
  ProfileImportResult? _profiles;
  PeopleZipResult? _result;
  bool _finished = false;

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

  late final PeopleZipImporter _importer =
      widget.importer ??
      PeopleZipImporter(
        personStore: widget.personStore,
        recordStore: widget.assetRecordStore,
        tagFor: PasscodeTags(
          records: widget.assetRecordStore,
          people: widget.personStore,
        ).tagFor,
      );

  static Future<List<String>?> _pickWithSystemBrowser() async {
    final picked = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['zip'],
    );
    return [for (final f in picked) ?f.path];
  }

  /// Zips still to open after this one, when several were picked: one is
  /// unpacked at a time, so the phone never holds them all unpacked.
  List<String> _queue = const [];
  int _zipNumber = 1;
  int _zipCount = 1;

  /// What every zip so far added, shown once the last is done.
  ProfileImportResult _profilesSoFar = const ProfileImportResult();
  PeopleZipResult _photosSoFar = const PeopleZipResult();
  bool _anyPhotos = false;

  Future<List<String>> _choose() async {
    if (widget.pickZips case final pick?) return await pick() ?? const [];
    if (widget.pickZip case final pick?) {
      final path = await pick();
      return path == null ? const [] : [path];
    }
    return await _pickWithSystemBrowser() ?? const [];
  }

  Future<void> _pick() async {
    if (_opening || _progress != null) return;
    final paths = await _choose();
    if (paths.isEmpty || !mounted) {
      if (_zip == null && mounted) Navigator.of(context).maybePop();
      return;
    }
    _queue = paths.sublist(1);
    _zipNumber = 1;
    _zipCount = paths.length;
    _profilesSoFar = const ProfileImportResult();
    _photosSoFar = const PeopleZipResult();
    _anyPhotos = false;
    await _open(paths.first);
  }

  Future<void> _open(String path) async {
    setState(() {
      _opening = true;
      _error = null;
      _result = null;
      _profiles = null;
      _finished = false;
    });
    try {
      await _zip?.discard();
      final zip = await PeopleZip.open(
        path,
        await (widget.workDir ?? getTemporaryDirectory)(),
      );
      // The picker's own copies, once the last is unpacked: clearing after
      // the first deleted the zips still queued behind it.
      if (widget.pickZip == null && widget.pickZips == null && _queue.isEmpty) {
        unawaited(FilePicker.clearTemporaryFiles().catchError((_) {}));
      }
      final people = await widget.personStore.listAll();
      if (!mounted) {
        await zip.discard();
        return;
      }
      setState(() {
        _zip = zip;
        _people = people;
        _candidates.clear();
        _defaulted.clear();
        _picks = [for (final person in zip.people) PeopleZipPick(person)];
      });
      for (final pick in _picks) {
        _defaultMerge(pick);
      }
      if (_rows.isEmpty) await _finish();
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

  /// The rows on screen: profiles first, then whoever has photos. Rows
  /// still waiting for a choice go first, where they can be seen.
  List<PeopleZipPick> get _rows {
    final rows = [
      for (final pick in _picks)
        if (pick.person.profile != null || pick.person.photos.isNotEmpty) pick,
    ];
    return [...rows.where(_waiting), ...rows.where((p) => !_waiting(p))];
  }

  bool _waiting(PeopleZipPick p) =>
      p.include && _candidatesOf(p).isNotEmpty && p.target == null;

  /// A name here (or like one) waits for merge, new, or another name.
  bool get _unresolved => _rows.any(_waiting);

  int get _waitingCount => _rows.where(_waiting).length;

  Future<void> _resolve(PeopleZipPick pick) async {
    final choice = await chooseImportName(
      context,
      name: pick.displayName,
      candidates: _candidatesOf(pick),
      everyone: _people,
    );
    if (choice == null || !mounted) return;
    setState(() {
      _defaulted.remove(pick);
      switch (choice) {
        case ImportRename(:final name):
          pick.name = name;
          pick.target = null;
          _candidates.remove(pick);
          _defaultMerge(pick);
        case ImportMerge(:final personId):
          pick.target = PersonTarget(personId);
        case ImportAsNew():
          pick.target = const PersonTarget.newPerson();
      }
    });
    if (choice is ImportRename && _waiting(pick)) await _resolve(pick);
  }

  int get _photoCount =>
      _rows.where((p) => p.include).fold(0, (n, p) => n + p.photos.length);

  Future<void> _loadPhotos() async {
    final zip = _zip;
    if (zip == null || _progress != null) return;
    String? code;
    if (_rows.any((p) => p.include && p.hide)) {
      code = await (widget.askCode ?? _askCode)(context);
      if (code == null || !mounted) return;
    }
    setState(() => _progress = (0, _photoCount));
    PeopleZipResult result;
    try {
      _profiles = await _importer.writeProfiles(_rows);
      result = await _importer.run(
        _rows,
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
    }
    if (!mounted) return;
    setState(() {
      _progress = null;
      _result = result;
    });
    await _finish();
  }

  Future<void> _finish() async {
    await _zip?.discard();
    if (_profiles case final p?) {
      _profilesSoFar = ProfileImportResult(
        created: _profilesSoFar.created + p.created,
        updated: _profilesSoFar.updated + p.updated,
      );
    }
    if (_result case final r?) {
      _anyPhotos = true;
      _photosSoFar = PeopleZipResult(
        people: _photosSoFar.people + r.people,
        visible: _photosSoFar.visible + r.visible,
        hidden: _photosSoFar.hidden + r.hidden,
        failed: _photosSoFar.failed + r.failed,
      );
    }
    _profiles = null;
    _result = null;
    if (!mounted) return;
    setState(() {
      _zip = null;
      _picks = const [];
      _finished = _queue.isEmpty;
    });
    if (_queue.isNotEmpty) {
      final next = _queue.first;
      _queue = _queue.sublist(1);
      _zipNumber++;
      await _open(next);
    }
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
    final rows = _rows;
    final selectable = rows;
    final included = rows.where((p) => p.include).length;
    final progress = _progress;
    final busy = progress != null || _writing;
    // Leaving mid-run would lose the summary; the run itself would finish.
    return PopScope(
      canPop: !busy,
      child: CupertinoPageScaffold(
        backgroundColor: settingsPageBackground,
        navigationBar: CupertinoNavigationBar(
          backgroundColor: settingsPageBackground,
          middle: Text(
            _picks.isEmpty ? l10n.peopleZipTitle : l10n.peopleZipStepPeople,
          ),
          trailing: selectable.isEmpty || busy
              ? null
              : SettingsAccentButton(
                  label: included == selectable.length
                      ? l10n.selectionDeselectAll
                      : l10n.selectionSelectAll,
                  onPressed: () => setState(() {
                    final all = included != selectable.length;
                    for (final pick in selectable) {
                      pick.include = all;
                    }
                  }),
                ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              Expanded(child: _body(l10n, rows)),
              if (_picks.isNotEmpty) _footer(l10n, included, progress),
            ],
          ),
        ),
      ),
    );
  }

  Widget _body(AppLocalizations l10n, List<PeopleZipPick> rows) {
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
    if (_picks.isEmpty) {
      final message = [
        ?_error,
        if (_finished) ...[
          if (_zipCount > 1) l10n.peopleZipAllDone(_zipCount),
          if (_profilesSoFar case final p when p.total > 0)
            l10n.profileCsvImported(p.created, p.updated),
          _anyPhotos
              ? l10n.peopleZipDone(
                  _photosSoFar.people,
                  _photosSoFar.visible,
                  _photosSoFar.hidden,
                )
              : l10n.peopleZipNoPhotos,
          if (_photosSoFar.failed > 0)
            l10n.peopleZipFailed(_photosSoFar.failed),
        ],
      ].join('\n');
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (message.isNotEmpty)
                Text(
                  message,
                  key: const ValueKey('peopleZipMessage'),
                  textAlign: TextAlign.center,
                  style: settingsRowTitleStyle,
                ),
              const SizedBox(height: 16),
              if (_finished) ...[
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
      itemCount: rows.length + 1,
      separatorBuilder: (_, _) => const SizedBox(height: 6),
      itemBuilder: (context, i) {
        if (i == 0) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 6, left: 4),
            child: Text(
              [
                ?_error,
                if (_zipCount > 1) l10n.peopleZipOf(_zipNumber, _zipCount),
                l10n.peopleZipOnePageHint,
              ].join('\n'),
              style: settingsHintStyle,
            ),
          );
        }
        final pick = rows[i - 1];
        return _PersonRow(
          key: ValueKey('peopleZip-${pick.person.name}'),
          pick: pick,
          photos: true,
          canLoad: true,
          candidates: _candidatesOf(pick),
          defaulted: _defaulted.contains(pick),
          onResolve: () => _resolve(pick),
          enabled: _progress == null && !_writing,
          onChanged: () => setState(() {}),
          onPreview: () => _preview(pick),
        );
      },
    );
  }

  Widget _footer(AppLocalizations l10n, int included, (int, int)? progress) {
    final Widget child;
    if (progress != null || _writing) {
      child = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CupertinoActivityIndicator(),
          if (progress != null) ...[
            const SizedBox(height: 6),
            Text(
              l10n.peopleZipProgress(progress.$1, progress.$2),
              style: settingsHintStyle,
            ),
          ],
        ],
      );
    } else {
      child = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_unresolved)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                l10n.importNeedsChoice(_waitingCount),
                key: const ValueKey('importNeedsChoice'),
                style: const TextStyle(
                  fontSize: 13,
                  color: CupertinoColors.systemOrange,
                ),
              ),
            ),
          SizedBox(
            width: double.infinity,
            child: CupertinoButton.filled(
              key: const ValueKey('peopleZipImport'),
              onPressed: included == 0 || _unresolved ? null : _loadPhotos,
              child: Text(l10n.peopleZipImport(included, _photoCount)),
            ),
          ),
        ],
      );
    }
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
      color: settingsPageBackground,
      child: child,
    );
  }
}

class _PersonRow extends StatelessWidget {
  const _PersonRow({
    super.key,
    required this.pick,
    required this.photos,
    required this.canLoad,
    required this.candidates,
    required this.defaulted,
    required this.onResolve,
    required this.enabled,
    required this.onChanged,
    required this.onPreview,
  });

  final PeopleZipPick pick;

  /// The photos step: counts, preview and Hide; otherwise the profile step.
  final bool photos;

  /// In People already, so photos can go to them.
  final bool canLoad;

  /// People here with this name; two or more and [onResolve] picks.
  final List<Person> candidates;

  /// Merging into the one same-name person by default, not by a tap.
  final bool defaulted;
  final VoidCallback onResolve;
  final bool enabled;
  final VoidCallback onChanged;
  final VoidCallback onPreview;

  /// What was chosen for this row, or what it still asks.
  String _choiceLabel(AppLocalizations l10n, bool resolved) {
    if (defaulted) return l10n.importMergingDefault;
    final id = pick.target?.personId;
    if (id != null) {
      final into = candidates.where((p) => p.id == id).firstOrNull;
      return l10n.profileCsvMergeInto(into?.name ?? pick.displayName);
    }
    if (resolved) return l10n.profileCsvWillCreate;
    if (candidates.isEmpty) {
      return pick.name == null
          ? l10n.importRename
          : l10n.importRenamed(pick.displayName);
    }
    final same = candidates.any(
      (p) =>
          p.name.trim().toLowerCase() == pick.displayName.trim().toLowerCase(),
    );
    if (!same) {
      return l10n.profileCsvSimilarChoose(
        candidates.map((p) => p.name).join(', '),
      );
    }
    return candidates.length > 1
        ? l10n.importSharedName(candidates.length)
        : l10n.profileCsvChoose;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final person = pick.person;
    final active = enabled && (!photos || canLoad);
    final decode = (44 * MediaQuery.devicePixelRatioOf(context)).round();
    final cover = pick.photos.isEmpty
        ? person.photos.firstOrNull
        : person.photos.firstWhere(pick.photos.contains);
    final resolved = pick.target != null;
    final subtitle = photos
        ? [
            l10n.peopleZipPhotos(pick.photos.length, person.photos.length),
            if (!canLoad) l10n.peopleZipNotInPeople,
          ].join(' · ')
        : candidates.isEmpty
        ? l10n.peopleZipNew
        : null;
    return Opacity(
      opacity: photos && !canLoad ? 0.5 : 1,
      child: Container(
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
              onChanged: active
                  ? (v) {
                      pick.include = v ?? false;
                      onChanged();
                    }
                  : null,
            ),
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: photos && canLoad ? onPreview : null,
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
                            pick.displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: settingsRowTitleStyle,
                          ),
                          if (subtitle != null)
                            Text(subtitle, style: settingsHintStyle),
                          CupertinoButton(
                            key: ValueKey('peopleZipResolve-${person.name}'),
                            padding: EdgeInsets.zero,
                            minimumSize: const Size(0, 28),
                            alignment: Alignment.centerLeft,
                            onPressed:
                                active || (photos && candidates.isNotEmpty)
                                ? onResolve
                                : null,
                            child: Text(
                              _choiceLabel(l10n, resolved),
                              style: TextStyle(
                                fontSize: 13,
                                color:
                                    !defaulted &&
                                        (resolved || candidates.isEmpty)
                                    ? settingsAccent
                                    : CupertinoColors.systemOrange,
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
            if (photos)
              CupertinoButton(
                key: ValueKey('peopleZipHide-${person.name}'),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(44, 44),
                onPressed: active && pick.include
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
