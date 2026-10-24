import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:intl/intl.dart';

export '../photos/people_order.dart' show PeopleSort;

import '../l10n/app_localizations.dart';
import '../photos/ai_analysis_store.dart';
import '../photos/person.dart';
import '../photos/face_grouping.dart';
import '../photos/face_identity.dart';
import '../photos/person_detail.dart';
import '../photos/person_store.dart';
import '../photos/unnamed_faces.dart';
import '../photos/fix_queue.dart';
import '../photos/people_order.dart';
import '../photos/people_unhide.dart';
import '../photos/storage_advice.dart';
import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import 'person_avatar.dart';
import 'profile_chip.dart';
import 'person_page_screen.dart';
import 'face_group_screen.dart';
import 'search_picker_sheet.dart';
import 'person_picker_sheet.dart';
import 'person_profile_screen.dart';
import 'flagged_action_screen.dart';
import 'merge_people_screen.dart' show mergePeopleInto;
import 'private_album_gate.dart';
import 'select_all.dart';
import 'people_zip_screen.dart';
import 'profile_transfer_screen.dart';

/// Collections' "People" row: named [Person] profiles (T7.1-T7.3), each with
/// a photo count, plus a link down to the on-device people-*count* grouping
/// for finding more faces to name. See IMPLEMENTATION_PLAN.md Phase 7.
class PeopleScreen extends StatefulWidget {
  const PeopleScreen({
    super.key,
    required this.personStore,
    required this.assetRecordStore,
    this.aiAnalysisStore,
    this.faceIdentity,
    this.onOpenAsset,
    this.fixQueue,
  });

  /// The library's, for Remove from iPhone and Optimize on several people
  /// at once; without it those two are not offered.
  final FixQueue? fixQueue;

  final PersonStore personStore;
  final AssetRecordStore assetRecordStore;
  final AiAnalysisStore? aiAnalysisStore;

  /// Remembers a face once it's named, so the next photo of them can be
  /// guessed. Absent, naming still works — it just teaches nothing.
  final FaceIdentityService? faceIdentity;

  final Future<void> Function(String localId)? onOpenAsset;

  @override
  State<PeopleScreen> createState() => _PeopleScreenState();
}

/// How long ago they were first known of, in whole years.
enum MetBand {
  thisYear(0, 1),
  within5(1, 5),
  from5(5, 10),
  from10(10, 20),
  over20(20, 1000);

  const MetBand(this.from, this.until);
  final int from;
  final int until;

  bool holds(int years) => years >= from && years < until;
}

int _yearsSince(DateTime at, DateTime now) {
  var years = now.year - at.year;
  if (now.month < at.month || (now.month == at.month && now.day < at.day)) {
    years--;
  }
  return years;
}

class _PeopleScreenState extends State<PeopleScreen> {
  List<Person> _people = const [];
  Map<String, int> _counts = const {};

  /// Names each person went by before; search finds them by those too.
  Map<String, List<String>> _formerNames = const {};
  Map<String, String> _firstPhoto = const {};

  /// Every avatar on the page resolves from this, not a query of its own.
  /// Null when there is no record database (a test).
  Map<String, AssetRecord>? _recordsById;
  List<UnnamedFace> _unnamedFaces = const [];

  /// How many there are altogether — [_unnamedFaces] is the first sixty.
  /// Without it the section reads the same whether the scan has found
  /// twenty faces or four hundred.
  int _facesFound = 0;
  String _query = '';
  Map<PersonGroup, List<String>> _groups = const {};
  Map<String, PersonDetail> _details = const {};

  PeopleSort _sort = PeopleSort.lastSeen;
  bool _loaded = false;
  static const _sortKey = peopleSortKey;

  /// When each person was first and last known of: their First met / Last
  /// seen rows, else the earliest / latest dated event or tagged photo.
  Map<String, DateTime> _firstKnown = const {};
  Map<String, DateTime> _lastKnown = const {};

  /// The filters row; null is Any. They narrow together.
  Gender? _gender;
  MetBand? _met;
  PersonGroup? _group;

  /// This is the page you open to work through them, so it shows far more
  /// than the home row's handful. Each one is a person, not a face, and
  /// they are ordered biggest pile first — so a list this long is mostly
  /// a long tail of one-offs below the names worth giving.
  static const _unnamedFacesShown = 60;

  /// One size for every circle on this page. A named person and a face
  /// waiting for a name are the same kind of thing asked from two sides,
  /// and drawing them at two scales made the list look like two lists.
  static const _faceSize = 66.0;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final people = await widget.personStore.listAll();
    final records = await _records();
    // Counted over what may be shown: a hidden photo in the count gives
    // away that it exists.
    final visible = visibleIdsOf(records);
    final counts = <String, int>{};
    final firstPhoto = <String, String>{};
    final tagged = <String>{};
    final members = _members = await widget.personStore.allMemberships();
    for (final person in people) {
      final shown = [
        for (final id in members[person.id] ?? const <String>[])
          if (visible.contains(id)) id,
      ];
      counts[person.id] = shown.length;
      tagged.addAll(members[person.id] ?? const <String>[]);
      if (shown.isNotEmpty) firstPhoto[person.id] = shown.first;
    }
    final groups = await widget.personStore.allGroups();
    final formerNames = await widget.personStore.allFormerNames();
    final details = await widget.personStore.openDetails();
    final spans = await widget.personStore.openEventSpans();
    final byId = visibleRecordsOf(records);
    final (first: firstKnown, last: lastKnown) = knownDates(
      people,
      members,
      byId,
      spans,
    );
    final sort = await _loadSort();
    final unnamed = await _loadUnnamedFaces(records, tagged, {
      for (final p in people) p.id: p.name,
    });
    sortPeople(
      people,
      sort,
      counts: counts,
      firstKnown: firstKnown,
      lastKnown: lastKnown,
      born: _bornOf(details),
    );
    if (!mounted) return;
    setState(() {
      _sort = sort;
      _firstKnown = firstKnown;
      _lastKnown = lastKnown;
      _groups = groups;
      _formerNames = formerNames;
      _details = details;
      _people = people;
      _counts = counts;
      _firstPhoto = firstPhoto;
      _recordsById = records.isEmpty ? null : byId;
      _loaded = true;
      _unnamedFaces = unnamed.faces;
      _facesFound = unnamed.found;
    });
    _facesTick.value++;
  }

  static Map<String, DateTime> _bornOf(Map<String, PersonDetail> details) => {
    for (final MapEntry(:key, :value) in details.entries) key: ?value.birthDate,
  };

  Future<PeopleSort> _loadSort() => loadPeopleSort(widget.assetRecordStore);

  Future<void> _setSort(PeopleSort sort) async {
    final people = [..._people];
    sortPeople(
      people,
      sort,
      counts: _counts,
      firstKnown: _firstKnown,
      lastKnown: _lastKnown,
      born: _bornOf(_details),
    );
    setState(() {
      _sort = sort;
      _people = people;
    });
    try {
      await widget.assetRecordStore.setAppState(_sortKey, sort.name);
    } catch (_) {
      // No app-state table (a widget test): this visit only.
    }
  }

  static String _sortLabel(AppLocalizations l10n, PeopleSort s) => switch (s) {
    PeopleSort.photos => l10n.peopleSortPhotos,
    PeopleSort.firstMet => l10n.peopleSortFirstMet,
    PeopleSort.lastSeen => l10n.peopleSortLastSeen,
    PeopleSort.age => l10n.peopleSortAge,
    PeopleSort.name => l10n.peopleSortName,
  };

  void _showSort() {
    final l10n = AppLocalizations.of(context)!;
    String label(PeopleSort s) => _sortLabel(l10n, s);
    showCupertinoModalPopup<void>(
      context: context,
      builder: (sheet) => CupertinoActionSheet(
        title: Text(l10n.peopleSortTitle),
        actions: [
          for (final s in PeopleSort.values)
            CupertinoActionSheetAction(
              key: ValueKey('peopleSort-${s.name}'),
              isDefaultAction: s == _sort,
              onPressed: () {
                Navigator.of(sheet).pop();
                _setSort(s);
              },
              child: Text(s == _sort ? '✓ ${label(s)}' : label(s)),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(sheet).pop(),
          child: Text(l10n.actionCancel),
        ),
      ),
    );
  }

  /// Every record, or none where there's no record database (a widget
  /// test, no platform channel) — the page is still the list of people.
  Future<List<AssetRecord>> _records() async {
    try {
      return await widget.assetRecordStore.listAll();
    } catch (_) {
      return const [];
    }
  }

  /// The same strangers the home page's People row offers, on the page
  /// that row's "More" leads to — naming somebody is the one thing you
  /// come here to do, and sending you back to the home screen to do it was
  /// the wrong way round.
  Future<UnnamedFaces> _loadUnnamedFaces(
    List<AssetRecord> records,
    Set<String> tagged,
    Map<String, String> peopleById,
  ) async {
    final analysisStore = widget.aiAnalysisStore;
    if (analysisStore == null || records.isEmpty) {
      return (faces: const <UnnamedFace>[], found: 0);
    }
    try {
      return await findUnnamedFaces(
        analysisStore: analysisStore,
        records: records,
        taggedLocalIds: tagged,
        peopleById: peopleById,
        limit: _unnamedFacesShown,
      );
    } catch (_) {
      // No record database to read (a widget test, no platform channel) —
      // the page is still the list of people, which is what it's for.
      return (faces: const <UnnamedFace>[], found: 0);
    }
  }

  /// Opens the face as a person who doesn't exist yet — their photos
  /// gathered, nothing written down until a name is given. Falls back to
  /// the picker when there's no grouping to show, which is what "add this
  /// face to somebody I've already named" needs anyway.
  Future<void> _nameFace(UnnamedFace face) async {
    final analysisStore = widget.aiAnalysisStore;
    final identity = widget.faceIdentity;
    if (analysisStore == null || identity == null) {
      final picked = await nameFace(
        context: context,
        personStore: widget.personStore,
        face: face,
        identity: identity,
        assetRecordStore: widget.assetRecordStore,
      );
      if (picked != null && mounted) await _reload();
      return;
    }
    final created = await Navigator.of(context).push<Person>(
      CupertinoPageRoute(
        builder: (_) => FaceGroupScreen(
          seed: face,
          personStore: widget.personStore,
          assetRecordStore: widget.assetRecordStore,
          grouping: FaceGrouping(analysisStore: analysisStore),
          faceIdentity: identity,
        ),
      ),
    );
    if (created != null && mounted) await _reload();
  }

  /// The other question about a face: "this is somebody I already named."
  /// Kept as the ✓ row action, where the app has a guess to confirm.
  Future<void> _pickPersonFor(UnnamedFace face) async {
    final picked = await nameFace(
      context: context,
      personStore: widget.personStore,
      face: face,
      identity: widget.faceIdentity,
      assetRecordStore: widget.assetRecordStore,
    );
    if (picked != null && mounted) await _reload();
  }

  /// One tap, because the app already has a name for this face and the row
  /// is showing it. Undoable, for exactly that reason.
  final _accepting = <String>{};

  Future<void> _acceptSuggestion(UnnamedFace face) async {
    final personId = face.suggestedPersonId;
    final name = face.suggestedName;
    if (personId == null || name == null) return;
    if (!_accepting.add(face.localId)) return;
    final l10n = AppLocalizations.of(context)!;
    await widget.personStore.addAssets(personId, [face.localId]);
    final identity = widget.faceIdentity;
    if (identity != null) {
      final record =
          _recordsById?[face.localId] ??
          await widget.assetRecordStore.getByLocalId(face.localId);
      if (record != null) {
        await identity.remember(
          record: record,
          face: face.face,
          personId: personId,
        );
      }
    }
    if (!mounted) return;
    await _reload();
    _accepting.remove(face.localId);
    if (!mounted) return;
    _showUndo(l10n.peopleSuggestionAccepted(name), () async {
      await widget.personStore.removeAsset(personId, face.localId);
      // The descriptor goes back too. Undo that only unlinked the photo
      // would leave the face in the reference set, pulling later photos
      // towards the person just rejected.
      await identity?.unremember(localId: face.localId, face: face.face);
      if (mounted) await _reload();
    });
  }

  /// The toast's own auto-dismiss. Held so leaving the page takes it with
  /// us — a timer that fires into a disposed tree is a crash waiting for
  /// whoever navigates away inside five seconds.
  Timer? _undoTimer;
  OverlayEntry? _undoToast;

  @override
  void dispose() {
    _facesTick.dispose();
    _scroll.dispose();
    _undoTimer?.cancel();
    _undoToast?.remove();
    _undoToast = null;
    super.dispose();
  }

  void _showUndo(String message, Future<void> Function() undo) {
    final l10n = AppLocalizations.of(context)!;
    final overlay = Overlay.of(context);
    // One at a time: accepting two guesses quickly should leave one toast
    // about the second, not two stacked on the same spot.
    _undoTimer?.cancel();
    _undoToast?.remove();
    late final OverlayEntry entry;
    var dismissed = false;
    void close() {
      if (dismissed) return;
      dismissed = true;
      _undoTimer?.cancel();
      if (identical(_undoToast, entry)) _undoToast = null;
      entry.remove();
    }

    entry = OverlayEntry(
      builder: (context) => Positioned(
        left: 16,
        right: 16,
        bottom: MediaQuery.of(context).padding.bottom + 24,
        child: CupertinoPopupSurface(
          isSurfacePainted: true,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
            child: Row(
              children: [
                Expanded(child: Text(message, maxLines: 1)),
                CupertinoButton(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  minimumSize: Size.zero,
                  onPressed: () {
                    close();
                    unawaited(undo());
                  },
                  child: Text(l10n.actionUndo),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    overlay.insert(entry);
    _undoToast = entry;
    _undoTimer = Timer(const Duration(seconds: 5), close);
  }

  bool _matchesFilter(Person person, DateTime now) {
    if (_gender case final gender? when _details[person.id]?.gender != gender) {
      return false;
    }
    if (_met case final band?) {
      final at = _firstKnown[person.id];
      if (at == null || !band.holds(_yearsSince(at, now))) return false;
    }
    if (_group case final group?) {
      if (!(_groups[group] ?? const []).contains(person.id)) return false;
    }
    return true;
  }

  Widget _sectionHeading(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
    child: Text(
      text,
      style: const TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: CupertinoColors.systemGrey,
      ),
    ),
  );

  /// Under the search box: one dropdown per filter, then the sort. Gender
  /// and age come from the open profile only — a list anybody can see must
  /// not narrow by something a passcode opens.
  Widget _filterRow(AppLocalizations l10n) {
    String metLabel(MetBand b) => switch (b) {
      MetBand.thisYear => l10n.peopleMetThisYear,
      MetBand.over20 => l10n.peopleMetOver(20),
      _ => l10n.peopleMetRange(b.from, b.until),
    };
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Row(
        children: [
          _FilterPill(
            key: const ValueKey('people-filter-gender'),
            label: switch (_gender) {
              Gender.male => l10n.peopleFilterMale,
              Gender.female => l10n.peopleFilterFemale,
              null => l10n.peopleFilterGender,
            },
            active: _gender != null,
            onTap: () => _pickOne<Gender>(
              title: l10n.peopleFilterGender,
              options: Gender.values,
              current: _gender,
              labelOf: (g) => g == Gender.male
                  ? l10n.peopleFilterMale
                  : l10n.peopleFilterFemale,
              onPicked: (g) => setState(() => _gender = g),
            ),
          ),
          _FilterPill(
            key: const ValueKey('people-filter-met'),
            label: _met == null ? l10n.peopleFilterMet : metLabel(_met!),
            active: _met != null,
            onTap: () => _pickOne<MetBand>(
              title: l10n.peopleFilterMet,
              options: MetBand.values,
              current: _met,
              labelOf: metLabel,
              onPicked: (b) => setState(() => _met = b),
            ),
          ),
          if (_groups.isNotEmpty)
            _FilterPill(
              key: const ValueKey('people-filter-group'),
              label: _group?.name ?? l10n.peopleFilterGroup,
              active: _group != null,
              onTap: _pickGroup,
            ),
          _FilterPill(
            key: const ValueKey('peopleSortMenu'),
            icon: CupertinoIcons.arrow_up_arrow_down,
            label: _sortLabel(l10n, _sort),
            active: false,
            onTap: _showSort,
          ),
        ],
      ),
    );
  }

  /// Any, then each option, the current one ticked.
  void _pickOne<T>({
    required String title,
    required List<T> options,
    required T? current,
    required String Function(T) labelOf,
    required void Function(T?) onPicked,
  }) {
    final l10n = AppLocalizations.of(context)!;
    showCupertinoModalPopup<void>(
      context: context,
      builder: (sheet) => CupertinoActionSheet(
        title: Text(title),
        actions: [
          CupertinoActionSheetAction(
            key: const ValueKey('people-filter-any'),
            isDefaultAction: current == null,
            onPressed: () {
              Navigator.of(sheet).pop();
              onPicked(null);
            },
            child: Text(
              current == null
                  ? '✓ ${l10n.peopleFilterAny}'
                  : l10n.peopleFilterAny,
            ),
          ),
          for (final option in options)
            CupertinoActionSheetAction(
              key: ValueKey('people-filter-option-$option'),
              isDefaultAction: option == current,
              onPressed: () {
                Navigator.of(sheet).pop();
                onPicked(option);
              },
              child: Text(
                option == current ? '✓ ${labelOf(option)}' : labelOf(option),
              ),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(sheet).pop(),
          child: Text(l10n.actionCancel),
        ),
      ),
    );
  }

  /// Off everyone; nobody is removed. The open set's only — a sealed set's
  /// groups are its own.
  Future<void> _deleteGroup(PersonGroup group) async {
    final l10n = AppLocalizations.of(context)!;
    final ok = await showCupertinoDialog<bool>(
      context: context,
      builder: (dialog) => CupertinoAlertDialog(
        title: Text(l10n.peopleDeleteGroupTitle(group.name)),
        content: Text(l10n.peopleDeleteGroupBody(_groups[group]?.length ?? 0)),
        actions: [
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () => Navigator.of(dialog).pop(false),
            child: Text(l10n.actionCancel),
          ),
          CupertinoDialogAction(
            key: const ValueKey('peopleDeleteGroupConfirm'),
            isDestructiveAction: true,
            onPressed: () => Navigator.of(dialog).pop(true),
            child: Text(l10n.actionDelete),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await widget.personStore.deleteGroup(group.id, scope: PersonScope.open);
    setState(() => _group = null);
    await _reload();
  }

  /// A searchable list, not a chip or a row per group: there can be
  /// hundreds of them.
  Future<void> _pickGroup() async {
    final l10n = AppLocalizations.of(context)!;
    final current = _group;
    final groups = _groups.keys.toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    const any = PersonGroup(id: '', name: '', kind: GroupKind.circle);
    final picked = await showSearchPickerSheetOf<PersonGroup>(
      context: context,
      title: l10n.peopleFilterGroup,
      options: groups,
      labelOf: (g) =>
          '${g.name} · ${groupKindLabel(l10n, g.kind)} · '
          '${_groups[g]?.length ?? 0}',
      isSelected: (g) => g.id == current?.id,
      clearLabel: current == null ? null : l10n.peopleFilterAny,
      clearValue: current == null ? null : any,
    );
    if (picked == null || !mounted) return;
    setState(() => _group = picked.id.isEmpty ? null : picked);
  }

  // ---------------------------------------------------------------- select

  Map<String, List<String>> _members = const {};
  bool _selecting = false;
  Set<String> _picked = const {};

  void _toggle(Person person) => setState(() {
    final next = {..._picked};
    if (!next.remove(person.id)) next.add(person.id);
    _picked = next;
  });

  void _endSelecting() => setState(() {
    _selecting = false;
    _picked = const {};
  });

  /// The picked people's photos that are shown, each once: a photo of two
  /// of them belongs to whichever comes first in the list.
  ({List<AssetRecord> records, Map<String, String> owner}) _photosOfPicked() =>
      _photosOf(_picked);

  ({List<AssetRecord> records, Map<String, String> owner}) _photosOf(
    Set<String> ids,
  ) {
    final owner = <String, String>{};
    final records = <AssetRecord>[];
    for (final person in _people) {
      if (!ids.contains(person.id)) continue;
      for (final id in _members[person.id] ?? const <String>[]) {
        final record = _recordsById?[id];
        if (record == null || owner.containsKey(id)) continue;
        owner[id] = person.id;
        records.add(record);
      }
    }
    return (records: records, owner: owner);
  }

  Future<void> _note(String message) => showCupertinoDialog<void>(
    context: context,
    builder: (dialog) => CupertinoAlertDialog(
      content: Text(message),
      actions: [
        CupertinoDialogAction(
          onPressed: () => Navigator.of(dialog).pop(),
          child: Text(AppLocalizations.of(context)!.actionOk),
        ),
      ],
    ),
  );

  /// Each into their own hidden folder, one code for all of them.
  Future<void> _hidePicked() => _hidePeople(_picked);

  Future<void> _hidePeople(Set<String> ids) async {
    final l10n = AppLocalizations.of(context)!;
    final (:records, :owner) = _photosOf(ids);
    if (records.isEmpty) return _note(l10n.peopleBatchNothingToHide);
    final hidden = await hideIntoPrivateAlbum(
      context,
      assetRecordStore: widget.assetRecordStore,
      records: records,
      codeForRecord: (digits, r) => personAlbumCode(owner[r.localId]!, digits),
      onSettled: () {
        if (mounted) _reload();
      },
    );
    if (!mounted) return;
    if (hidden) _endSelecting();
    await _reload();
  }

  Future<void> _unhidePicked() async {
    final l10n = AppLocalizations.of(context)!;
    final digits = await showPrivateAlbumPasscodeSheet(
      context,
      title: l10n.peopleBatchUnhideTitle,
    );
    if (digits == null || !mounted) return;
    final ids = [
      for (final person in _people)
        if (_picked.contains(person.id)) person.id,
    ];
    final result = await PeopleUnhide(
      store: widget.assetRecordStore,
      personStore: widget.personStore,
    ).run(ids, digits);
    if (!mounted) return;
    await _reload();
    if (!mounted) return;
    await _note(
      [
        if (result.returned == 0 && result.failed == 0 && result.skipped == 0)
          l10n.peopleBatchUnhideNone
        else
          l10n.peopleBatchUnhideDone(result.returned),
        if (result.failed > 0) l10n.peopleBatchUnhideFailed(result.failed),
        if (result.skipped > 0) l10n.peopleBatchUnhideSkipped(result.skipped),
      ].join('\n'),
    );
    if (result.returned > 0) _endSelecting();
  }

  /// Twice asked: a profile, its details and links don't come back. Anyone
  /// with a hidden folder is left, as on their profile.
  Future<void> _deletePicked() async {
    final l10n = AppLocalizations.of(context)!;
    final picked = [
      for (final person in _people)
        if (_picked.contains(person.id)) person,
    ];
    if (picked.isEmpty) return;
    Future<bool> ask(String title, String body, String action, Key key) async =>
        await showCupertinoDialog<bool>(
          context: context,
          builder: (dialog) => CupertinoAlertDialog(
            title: Text(title),
            content: Text(body),
            actions: [
              CupertinoDialogAction(
                isDefaultAction: true,
                onPressed: () => Navigator.of(dialog).pop(false),
                child: Text(l10n.actionCancel),
              ),
              CupertinoDialogAction(
                key: key,
                isDestructiveAction: true,
                onPressed: () => Navigator.of(dialog).pop(true),
                child: Text(action),
              ),
            ],
          ),
        ) ==
        true;
    if (!await ask(
      l10n.peopleBatchDeleteTitle(picked.length),
      l10n.personProfileDeleteConfirmBody,
      l10n.actionDelete,
      const ValueKey('peopleBatchDeleteConfirm'),
    )) {
      return;
    }
    if (!mounted) return;
    if (!await ask(
      l10n.peopleBatchDeleteAgainTitle(picked.length),
      picked.map((p) => p.name).join(', '),
      l10n.peopleBatchDeleteAgain(picked.length),
      const ValueKey('peopleBatchDeleteConfirmAgain'),
    )) {
      return;
    }
    final blocked = await peopleWithHiddenFolders(widget.assetRecordStore, {
      for (final p in picked) p.id: await widget.personStore.aliasesOf(p.id),
    });
    for (final person in picked) {
      if (blocked.contains(person.id)) continue;
      await widget.personStore.remove(person.id);
      await forgetPersonFaces(
        person.id,
        analysisStore: widget.faceIdentity?.analysisStore,
      );
    }
    if (!mounted) return;
    _endSelecting();
    await _reload();
    if (blocked.isNotEmpty && mounted) {
      await _note(
        l10n.peopleBatchDeleteBlocked(
          picked
              .where((p) => blocked.contains(p.id))
              .map((p) => p.name)
              .join(', '),
        ),
      );
    }
  }

  /// Asks which picked person stays; the rest fold into them.
  Future<void> _mergePicked() async {
    final picked = [
      for (final person in _people)
        if (_picked.contains(person.id)) person,
    ];
    if (picked.length < 2) return;
    final keep = await _chooseKeep(picked);
    if (keep == null || !mounted) return;
    final merged = await mergePeopleInto(
      context,
      keep: keep,
      gone: [
        for (final p in picked)
          if (p.id != keep.id) p,
      ],
      personStore: widget.personStore,
      assetRecordStore: widget.assetRecordStore,
      aiAnalysisStore: widget.aiAnalysisStore,
    );
    if (!mounted) return;
    if (merged) _endSelecting();
    await _reload();
  }

  Future<Person?> _chooseKeep(List<Person> picked) {
    final l10n = AppLocalizations.of(context)!;
    return showCupertinoModalPopup<Person>(
      context: context,
      builder: (sheet) => CupertinoActionSheet(
        title: Text(l10n.peopleMergeKeepTitle),
        message: Text(l10n.peopleMergeKeepBody),
        actions: [
          for (final person in picked)
            CupertinoActionSheetAction(
              key: ValueKey('peopleMergeKeep-${person.id}'),
              onPressed: () => Navigator.of(sheet).pop(person),
              child: Text(
                '${person.name} · '
                '${l10n.mergePeoplePhotos(_counts[person.id] ?? 0)}',
              ),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(sheet).pop(),
          child: Text(l10n.actionCancel),
        ),
      ),
    );
  }

  // ------------------------------------------------------------ batch edit

  /// One value set on everyone picked: First met, Last seen, or a group.
  Future<void> _editPicked() async {
    final l10n = AppLocalizations.of(context)!;
    final action = await showCupertinoModalPopup<String>(
      context: context,
      builder: (sheet) => CupertinoActionSheet(
        title: Text(l10n.selectionTitle(_picked.length)),
        actions: [
          for (final (key, label) in [
            ('firstMet', l10n.peopleBatchSetFirstMet),
            ('lastSeen', l10n.peopleBatchSetLastSeen),
            ('group', l10n.peopleBatchAddToGroup),
          ])
            CupertinoActionSheetAction(
              key: ValueKey('peopleEdit-$key'),
              onPressed: () => Navigator.of(sheet).pop(key),
              child: Text(label),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(sheet).pop(),
          child: Text(l10n.actionCancel),
        ),
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'firstMet':
        await _setFixedOnPicked(PersonEventType.firstMet, l10n.eventsFirstMet);
      case 'lastSeen':
        await _setFixedOnPicked(PersonEventType.lastSeen, l10n.eventsLastSeen);
      case 'group':
        await _addPickedToGroup();
    }
  }

  Future<DateTime?> _pickDate(String title) {
    final l10n = AppLocalizations.of(context)!;
    var value = DateTime.now();
    return showCupertinoModalPopup<DateTime>(
      context: context,
      builder: (sheet) => Container(
        height: 300,
        color: CupertinoDynamicColor.resolve(
          CupertinoColors.systemBackground,
          sheet,
        ),
        child: SafeArea(
          top: false,
          child: Column(
            children: [
              Row(
                children: [
                  CupertinoButton(
                    onPressed: () => Navigator.of(sheet).pop(),
                    child: Text(l10n.actionCancel),
                  ),
                  Expanded(
                    child: Text(
                      title,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  CupertinoButton(
                    key: const ValueKey('peopleEditDateDone'),
                    onPressed: () => Navigator.of(sheet).pop(value),
                    child: Text(l10n.selectionDone),
                  ),
                ],
              ),
              Expanded(
                child: CupertinoDatePicker(
                  mode: CupertinoDatePickerMode.date,
                  initialDateTime: value,
                  maximumDate: DateTime.now().add(const Duration(days: 1)),
                  onDateTimeChanged: (d) => value = d,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Bounded by the people picked: a read and a write each.
  Future<void> _setFixedOnPicked(PersonEventType type, String title) async {
    final at = await _pickDate(title);
    if (at == null || !mounted) return;
    for (final id in _picked) {
      final events = await widget.personStore.eventsFor(id);
      final had = events.where((e) => e.type == type).firstOrNull;
      await widget.personStore.saveEvent(
        PersonEvent(
          id: had?.id ?? widget.personStore.newId(),
          personId: id,
          type: type,
          at: at,
          tags: had?.tags ?? const [],
          notes: had?.notes ?? '',
        ),
        scope: PersonScope.open,
      );
    }
    if (!mounted) return;
    _endSelecting();
    await _reload();
  }

  Future<void> _addPickedToGroup() async {
    final l10n = AppLocalizations.of(context)!;
    final groups = _groups.keys.toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    final group = await showSearchPickerSheetOf<PersonGroup>(
      context: context,
      title: l10n.peopleBatchAddToGroup,
      options: groups,
      labelOf: (g) => g.name,
      autofocus: false,
      createLabel: (query) =>
          query.trim().isEmpty ||
              groups.any((g) => g.name.toLowerCase() == query.toLowerCase())
          ? null
          : l10n.personPickerNewNamed(query.trim()),
      onCreate: (query) async => PersonGroup(
        id: widget.personStore.newId(),
        name: query.trim(),
        kind: GroupKind.circle,
      ),
    );
    if (group == null || !mounted) return;
    for (final id in _picked) {
      await widget.personStore.joinGroup(id, group, scope: PersonScope.open);
    }
    if (!mounted) return;
    _endSelecting();
    await _reload();
  }

  // ------------------------------------------------------------ row menu

  Future<void> _personMenu(Person person) async {
    final l10n = AppLocalizations.of(context)!;
    final action = await showCupertinoModalPopup<String>(
      context: context,
      builder: (sheet) => CupertinoActionSheet(
        title: Text(person.name),
        actions: [
          for (final (key, label) in [
            ('select', l10n.peopleMenuSelect),
            ('rename', l10n.peopleMenuRename),
            ('merge', l10n.peopleMenuMerge),
            ('hide', l10n.peopleMenuHideAll),
          ])
            CupertinoActionSheetAction(
              key: ValueKey('peopleMenu-$key'),
              onPressed: () => Navigator.of(sheet).pop(key),
              child: Text(label),
            ),
          CupertinoActionSheetAction(
            key: const ValueKey('peopleMenu-delete'),
            isDestructiveAction: true,
            onPressed: () => Navigator.of(sheet).pop('delete'),
            child: Text(l10n.personProfileDeletePerson),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(sheet).pop(),
          child: Text(l10n.actionCancel),
        ),
      ),
    );
    if (!mounted) return;
    switch (action) {
      case 'select':
        setState(() {
          _selecting = true;
          _picked = {person.id};
        });
      case 'rename':
        await _rename(person);
      case 'merge':
        await _mergeWith(person);
      case 'hide':
        await _hidePeople({person.id});
      case 'delete':
        await _delete(person);
    }
  }

  Future<void> _rename(Person person) async {
    final l10n = AppLocalizations.of(context)!;
    final controller = TextEditingController(text: person.name);
    final name = await showCupertinoDialog<String>(
      context: context,
      builder: (dialog) => CupertinoAlertDialog(
        title: Text(l10n.peopleMenuRename),
        content: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: CupertinoTextField(
            key: const ValueKey('peopleRenameField'),
            controller: controller,
            autofocus: true,
            onSubmitted: (v) => Navigator.of(dialog).pop(v),
          ),
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(dialog).pop(),
            child: Text(l10n.actionCancel),
          ),
          CupertinoDialogAction(
            key: const ValueKey('peopleRenameSave'),
            isDefaultAction: true,
            onPressed: () => Navigator.of(dialog).pop(controller.text),
            child: Text(l10n.actionOk),
          ),
        ],
      ),
    );
    controller.dispose();
    final trimmed = name?.trim() ?? '';
    if (trimmed.isEmpty || trimmed == person.name || !mounted) return;
    await widget.personStore.update(person.copyWith(name: trimmed));
    if (mounted) await _reload();
  }

  /// Picks any number of others, then who of them all stays.
  Future<void> _mergeWith(Person person) async {
    final l10n = AppLocalizations.of(context)!;
    final others = [
      for (final p in _people)
        if (p.id != person.id) p,
    ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    final chosen = await showSearchPickerSheetMulti<Person>(
      context: context,
      title: l10n.peopleMergeWithTitle(person.name),
      options: others,
      labelOf: (p) =>
          '${p.name} · ${l10n.mergePeoplePhotos(_counts[p.id] ?? 0)}',
    );
    if (chosen == null || chosen.isEmpty || !mounted) return;
    final all = [person, ...chosen];
    final keep = await _chooseKeep(all);
    if (keep == null || !mounted) return;
    await mergePeopleInto(
      context,
      keep: keep,
      gone: [
        for (final p in all)
          if (p.id != keep.id) p,
      ],
      personStore: widget.personStore,
      assetRecordStore: widget.assetRecordStore,
      aiAnalysisStore: widget.aiAnalysisStore,
    );
    if (mounted) await _reload();
  }

  /// As the profile's Delete: refused while their hidden folder holds
  /// photos, since its code dies with their id.
  Future<void> _delete(Person person) async {
    final l10n = AppLocalizations.of(context)!;
    if (await personHasHiddenFolder(
      widget.assetRecordStore,
      person.id,
      aliases: await widget.personStore.aliasesOf(person.id),
    )) {
      if (!mounted) return;
      return _note(l10n.personProfileDeleteBlockedBody);
    }
    if (!mounted) return;
    final ok = await showCupertinoDialog<bool>(
      context: context,
      builder: (dialog) => CupertinoAlertDialog(
        title: Text(l10n.personProfileDeleteConfirmTitle),
        content: Text(l10n.personProfileDeleteConfirmBody),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(dialog).pop(false),
            child: Text(l10n.actionCancel),
          ),
          CupertinoDialogAction(
            key: const ValueKey('peopleDeleteConfirm'),
            isDestructiveAction: true,
            onPressed: () => Navigator.of(dialog).pop(true),
            child: Text(l10n.actionDelete),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await widget.personStore.remove(person.id);
    await forgetPersonFaces(
      person.id,
      analysisStore: widget.faceIdentity?.analysisStore,
    );
    if (mounted) await _reload();
  }

  /// Opens the same page Flagged Items does, so the run is the queue's:
  /// the bucket is checked live before any local copy goes.
  Future<void> _freeUpPicked() async {
    final queue = widget.fixQueue;
    if (queue == null) return;
    final l10n = AppLocalizations.of(context)!;
    final flags = [
      for (final r in _photosOfPicked().records)
        if (r.isFullyBackedUp && worthMeasuring(r))
          Flag.storage(
            StorageItem(
              record: r,
              bytes: 0,
              name: r.localId,
              appOwned: r.sourcePath != null,
              issues: const {StorageIssue.onDevice},
              fixes: const [StorageFix.removeFromDevice],
            ),
          ),
    ];
    if (flags.isEmpty) return _note(l10n.peopleBatchNothingToFree);
    await _openAction(queue, FlagSolution.removeFromDevice, flags);
  }

  /// What the last storage scan found worth shrinking among their photos.
  Future<void> _optimizePicked() async {
    final queue = widget.fixQueue;
    if (queue == null) return;
    final l10n = AppLocalizations.of(context)!;
    final ids = _photosOfPicked().owner.keys.toSet();
    final scan = await queue.advisor.cached();
    if (!mounted) return;
    final flags = [
      for (final item in scan.items)
        if (ids.contains(item.record.localId) &&
            item.fixes.contains(StorageFix.optimize))
          Flag.storage(item.withFix(StorageFix.optimize)),
    ];
    if (flags.isEmpty) return _note(l10n.peopleBatchNothingToOptimize);
    await _openAction(queue, FlagSolution.optimize, flags);
  }

  Future<void> _openAction(
    FixQueue queue,
    FlagSolution solution,
    List<Flag> flags,
  ) async {
    await Navigator.of(context).push(
      CupertinoPageRoute<void>(
        builder: (_) => FlaggedActionScreen(
          solution: solution,
          flags: flags,
          queue: queue,
          onOpenAsset: widget.onOpenAsset,
        ),
      ),
    );
    if (mounted) await _reload();
  }

  /// Bumped on every reload, so the faces page re-reads [_unnamedFaces].
  final _facesTick = ValueNotifier<int>(0);
  final _scroll = ScrollController();

  void _toTop() {
    if (!_scroll.hasClients) return;
    _scroll.animateTo(
      0,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  /// Folded to [_foldAt] until asked; a search or filter shows every match.
  bool _showAllPeople = false;
  bool _showBare = false;
  static const _foldAt = 20;

  /// The faces get their own page; here they are one row, above the list.
  void _openFaces() {
    final l10n = AppLocalizations.of(context)!;
    Navigator.of(context).push(
      CupertinoPageRoute<void>(
        builder: (_) => CupertinoPageScaffold(
          navigationBar: CupertinoNavigationBar(
            middle: Text(l10n.peopleUnnamedHeading),
          ),
          child: SafeArea(
            child: ValueListenableBuilder<int>(
              valueListenable: _facesTick,
              builder: (_, _, _) => ListView(
                key: const ValueKey('people-faces-page'),
                children: [..._unnamedFaceRows(l10n)],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _facesRow(AppLocalizations l10n) => CupertinoListTile(
    key: const ValueKey('people-faces-row'),
    leading: const Icon(
      CupertinoIcons.person_crop_circle_badge_plus,
      color: CupertinoColors.systemIndigo,
    ),
    title: Text(l10n.peopleUnnamedHeading),
    trailing: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '$_facesFound',
          style: const TextStyle(color: CupertinoColors.systemGrey),
        ),
        const SizedBox(width: 4),
        const Icon(
          CupertinoIcons.chevron_forward,
          size: 18,
          color: CupertinoColors.systemGrey2,
        ),
      ],
    ),
    onTap: _openFaces,
  );

  List<Widget> _unnamedFaceRows(AppLocalizations l10n) => [
    Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              l10n.peopleUnnamedHeading,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ),
          // The list is capped; this is how many there are.
          Text(
            '$_facesFound',
            style: const TextStyle(
              fontSize: 13,
              color: CupertinoColors.systemGrey,
            ),
          ),
        ],
      ),
    ),
    for (final face in _unnamedFaces)
      CupertinoListTile(
        key: ValueKey('face:${face.localId}:${face.face.encode()}'),
        // `CupertinoListTile` clamps its leading widget to 28pt unless
        // told otherwise, so every size set on the avatar below was being
        // thrown away. That, not the avatar, is why these stayed tiny.
        leadingSize: _faceSize + 4,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        // Much bigger than a named person's 44pt row avatar, deliberately:
        // that one is a reminder of somebody you know, this one is the
        // whole question. A face cropped out of a photo is a small patch
        // of it to begin with — at 40 and again at 64 there wasn't enough
        // of it to answer "who is this?" from, so the row is as tall as
        // the face needs rather than as short as a list row usually is.
        leading: Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: CupertinoColors.systemGrey, width: 1.5),
          ),
          padding: const EdgeInsets.all(2),
          child: PersonAvatar(
            assetRecordStore: widget.assetRecordStore,
            localId: face.localId,
            face: face.face,
            records: _recordsById,
            size: _faceSize,
          ),
        ),
        title: Text(
          face.hasSuggestion
              ? l10n.peopleSuggestedFace(face.suggestedName!)
              : l10n.peopleUnnamedFace,
          style: const TextStyle(color: CupertinoColors.systemGrey),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // How many faces this circle stands for. Reads like a named
            // person's photo count, because it is about to become one.
            if (face.alike > 1)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Text(
                  '${face.alike}',
                  style: const TextStyle(color: CupertinoColors.systemGrey),
                ),
              ),
            // Two different questions, so two different controls. The
            // row asks "who is this?" and opens the group. This asks the
            // narrower one: ✓ where the app already has a name to
            // confirm, otherwise "add this face to somebody I've named".
            CupertinoButton(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: const Size(44, 44),
              onPressed: face.hasSuggestion
                  ? () => _acceptSuggestion(face)
                  : () => _pickPersonFor(face),
              child: Icon(
                face.hasSuggestion
                    ? CupertinoIcons.checkmark_circle_fill
                    : CupertinoIcons.person_crop_circle_badge_plus,
                size: 24,
                color: CupertinoColors.activeBlue,
              ),
            ),
            const Icon(
              CupertinoIcons.chevron_forward,
              size: 18,
              color: CupertinoColors.systemGrey2,
            ),
          ],
        ),
        onTap: () => _nameFace(face),
      ),
  ];

  /// Straight to the profile with the keyboard in the name field, rather
  /// than a dialog asking for a name and then a page asking for everything
  /// else. The person is real from the first keystroke — the profile
  /// writes each field as it's typed, and there is nothing here that a
  /// "Save" button would do.
  ///
  /// Leaving the name blank is how you back out: a nameless person is one
  /// nobody started, so it's dropped on the way out rather than left in
  /// the list as an untitled row.
  Future<void> _addPerson() async {
    final person = await widget.personStore.create(name: '');
    if (!mounted) return;
    await Navigator.of(context).push(
      CupertinoPageRoute(
        builder: (_) => PersonProfileScreen(
          person: person,
          personStore: widget.personStore,
          assetRecordStore: widget.assetRecordStore,
          autofocusName: true,
        ),
      ),
    );
    final saved = await widget.personStore.getById(person.id);
    // Dropped only when nothing else was written: a blank name must not
    // take places, links or notes already entered with it.
    if ((saved?.name ?? '').trim().isEmpty &&
        !await widget.personStore.hasAnyRecord(person.id) &&
        !await personHasHiddenFolder(widget.assetRecordStore, person.id)) {
      await widget.personStore.remove(person.id);
      await forgetPersonFaces(
        person.id,
        analysisStore: widget.faceIdentity?.analysisStore,
      );
    }
    if (!mounted) return;
    await _reload();
  }

  void _openPerson(Person person) {
    Navigator.of(context)
        .push(
          CupertinoPageRoute(
            builder: (_) => PersonPageScreen(
              person: person,
              personStore: widget.personStore,
              assetRecordStore: widget.assetRecordStore,
              aiAnalysisStore: widget.aiAnalysisStore,
              faceIdentity: widget.faceIdentity,
            ),
          ),
        )
        .then((_) => _reload());
  }

  /// Reloads on the way back: an import adds people to the list behind it.
  Future<void> _openProfileTransfer([ProfileTransferStart? start]) async {
    await Navigator.of(context).push(
      CupertinoPageRoute(
        builder: (_) => ProfileTransferScreen(
          personStore: widget.personStore,
          start: start,
        ),
      ),
    );
    if (mounted) await _reload();
  }

  Future<void> _openPeopleZip() async {
    await Navigator.of(context).push(
      CupertinoPageRoute<void>(
        builder: (_) => PeopleZipScreen(
          personStore: widget.personStore,
          assetRecordStore: widget.assetRecordStore,
        ),
      ),
    );
    if (mounted) await _reload();
  }

  /// Adding somebody, and the whole registry in and out as a spreadsheet.
  void _showMenu() {
    final l10n = AppLocalizations.of(context)!;
    showCupertinoModalPopup<void>(
      context: context,
      builder: (sheet) => CupertinoActionSheet(
        actions: [
          if (_group case final group?)
            CupertinoActionSheetAction(
              key: const ValueKey('peopleDeleteGroup'),
              isDestructiveAction: true,
              onPressed: () {
                Navigator.of(sheet).pop();
                _deleteGroup(group);
              },
              child: Text(l10n.peopleDeleteGroup(group.name)),
            ),
          CupertinoActionSheetAction(
            key: const ValueKey('peopleSelectMode'),
            onPressed: () {
              Navigator.of(sheet).pop();
              setState(() => _selecting = true);
            },
            child: Text(l10n.peopleSelectMenu),
          ),
          CupertinoActionSheetAction(
            key: const ValueKey('peopleAddPerson'),
            onPressed: () {
              Navigator.of(sheet).pop();
              _addPerson();
            },
            child: Text(l10n.peopleAddPerson),
          ),
          CupertinoActionSheetAction(
            key: const ValueKey('peopleCsvImport'),
            onPressed: () {
              Navigator.of(sheet).pop();
              _openProfileTransfer(ProfileTransferStart.import);
            },
            child: Text(l10n.peopleCsvImport),
          ),
          CupertinoActionSheetAction(
            key: const ValueKey('peopleZipImport'),
            onPressed: () {
              Navigator.of(sheet).pop();
              _openPeopleZip();
            },
            child: Text(l10n.peopleZipMenu),
          ),
          CupertinoActionSheetAction(
            key: const ValueKey('peopleCsvExport'),
            onPressed: () {
              Navigator.of(sheet).pop();
              _openProfileTransfer(ProfileTransferStart.export);
            },
            child: Text(l10n.peopleCsvExport),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(sheet).pop(),
          child: Text(l10n.actionCancel),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final query = _query.trim().toLowerCase();
    final now = DateTime.now();
    final filtered = [
      for (final person in _people)
        if (query.isEmpty ||
            person.name.toLowerCase().contains(query) ||
            (_formerNames[person.id] ?? const []).any(
              (n) => n.toLowerCase().contains(query),
            ))
          if (_matchesFilter(person, now)) person,
    ];
    final narrowed =
        query.isNotEmpty || _gender != null || _met != null || _group != null;
    // No visible photo: one row to open, unless searched or filtered for,
    // or nobody has one yet.
    final fold = !narrowed && filtered.any((p) => (_counts[p.id] ?? 0) > 0);
    final main = [
      for (final p in filtered)
        if (!fold || (_counts[p.id] ?? 0) > 0) p,
    ];
    final bare = [
      for (final p in filtered)
        if (fold && (_counts[p.id] ?? 0) == 0) p,
    ];
    final folded = _showAllPeople || narrowed
        ? main
        : main.take(_foldAt).toList();
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        // The bar's middle takes you back to the top; the status bar no
        // longer does (see [_scroll]).
        middle: GestureDetector(
          key: const ValueKey('peopleToTop'),
          behavior: HitTestBehavior.opaque,
          onTap: _toTop,
          child: SizedBox(
            width: 220,
            height: 44,
            child: Center(child: Text(l10n.peopleScreenTitle)),
          ),
        ),
        leading: _selecting
            ? SelectAllButton(
                total: filtered.length,
                selectedCount: _picked.length,
                onSelectNext: () =>
                    setState(() => _picked = {for (final p in filtered) p.id}),
                onDeselectAll: () => setState(() => _picked = const {}),
              )
            : null,
        trailing: _selecting
            ? SelectionDoneButton(
                key: const ValueKey('peopleSelectionDone'),
                onPressed: _endSelecting,
              )
            : CupertinoButton(
                key: const ValueKey('peopleMenu'),
                padding: EdgeInsets.zero,
                onPressed: _showMenu,
                child: const Icon(CupertinoIcons.ellipsis_circle),
              ),
      ),
      child: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: CupertinoScrollbar(
                controller: _scroll,
                child: _list(l10n, query, filtered, main, folded, bare),
              ),
            ),
            if (_selecting)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: _PeopleSelectionBar(
                  count: _picked.length,
                  onHide: _hidePicked,
                  onUnhide: _unhidePicked,
                  onMerge: _mergePicked,
                  onEdit: _editPicked,
                  onDelete: _deletePicked,
                  onFreeUp: widget.fixQueue == null ? null : _freeUpPicked,
                  onOptimize: widget.fixQueue == null ? null : _optimizePicked,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _personRow(AppLocalizations l10n, Person person) => GestureDetector(
    key: ValueKey('people-row-${person.id}'),
    onLongPress: _selecting ? null : () => _personMenu(person),
    child: CupertinoListTile(
      key: ValueKey(person.id),
      // Same size as the faces below, and for the same
      // reason: `CupertinoListTile` clamps its leading widget
      // to 28pt unless told, so a named person's 44 was being
      // thrown away and the two halves of one list were
      // drawn at two different scales.
      leadingSize: _faceSize + 4,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      leading: PersonAvatar.forPerson(
        assetRecordStore: widget.assetRecordStore,
        person: person,
        firstTaggedLocalId: _firstPhoto[person.id],
        records: _recordsById,
        size: _faceSize,
      ),
      title: Text(person.name),
      subtitle: switch ((
        _sort,
        _firstKnown[person.id],
        _lastKnown[person.id],
      )) {
        (PeopleSort.firstMet, final at?, _) => Text(
          l10n.peopleMetOn(DateFormat.yMMMd().format(at)),
        ),
        (PeopleSort.lastSeen, _, final at?) => Text(
          l10n.peopleSeenOn(DateFormat.yMMMd().format(at)),
        ),
        _ => null,
      },
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '${_counts[person.id] ?? 0}',
            style: const TextStyle(color: CupertinoColors.systemGrey),
          ),
          const SizedBox(width: 4),
          if (_selecting)
            Icon(
              _picked.contains(person.id)
                  ? CupertinoIcons.checkmark_circle_fill
                  : CupertinoIcons.circle,
              key: ValueKey('people-pick-${person.id}'),
              size: 22,
              color: _picked.contains(person.id)
                  ? CupertinoTheme.of(context).primaryColor
                  : CupertinoColors.systemGrey2,
            )
          else
            const Icon(
              CupertinoIcons.chevron_forward,
              size: 18,
              color: CupertinoColors.systemGrey2,
            ),
        ],
      ),
      onTap: _selecting ? () => _toggle(person) : () => _openPerson(person),
    ),
  );

  Widget _list(
    AppLocalizations l10n,
    String query,
    List<Person> filtered,
    List<Person> main,
    List<Person> folded,
    List<Person> bare,
  ) => ListView(
    // Its own controller, not the primary one: a tap just above the ⋯
    // button reads as a status-bar tap and scrolled the list to the top.
    controller: _scroll,
    children: [
      if (_people.isNotEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: CupertinoSearchTextField(
            // Not autofocused: the page is a list you came to read,
            // and a keyboard covering half of it on arrival is a
            // dismissal to do before you can look at anything.
            onChanged: (v) => setState(() => _query = v),
          ),
        ),
      if (_people.isNotEmpty) _filterRow(l10n),
      if (_unnamedFaces.isNotEmpty && query.isEmpty) _facesRow(l10n),
      if (_people.isNotEmpty) _sectionHeading(l10n.peopleSectionNamed),
      if (!_loaded)
        const Padding(
          padding: EdgeInsets.only(top: 48),
          child: CupertinoActivityIndicator(),
        )
      else if (_people.isEmpty && _unnamedFaces.isEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 48),
          child: Center(
            child: Text(
              l10n.peopleEmpty,
              style: const TextStyle(color: CupertinoColors.systemGrey),
            ),
          ),
        )
      else if (_people.isNotEmpty && filtered.isEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 48),
          child: Center(
            child: Text(
              l10n.peopleSearchEmpty,
              style: const TextStyle(color: CupertinoColors.systemGrey),
            ),
          ),
        )
      else
        for (final person in folded) _personRow(l10n, person),
      if (folded.length < main.length)
        CupertinoButton(
          key: const ValueKey('people-show-all'),
          onPressed: () => setState(() => _showAllPeople = true),
          child: Text(l10n.peopleShowAll(main.length)),
        ),
      if (bare.isNotEmpty)
        CupertinoListTile(
          key: const ValueKey('people-no-photos-row'),
          leading: const Icon(
            CupertinoIcons.person_crop_circle,
            color: CupertinoColors.systemGrey,
          ),
          title: Text(l10n.peopleNoPhotosRow),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${bare.length}',
                style: const TextStyle(color: CupertinoColors.systemGrey),
              ),
              const SizedBox(width: 4),
              Icon(
                _showBare
                    ? CupertinoIcons.chevron_down
                    : CupertinoIcons.chevron_forward,
                size: 18,
                color: CupertinoColors.systemGrey2,
              ),
            ],
          ),
          onTap: () => setState(() => _showBare = !_showBare),
        ),
      if (_showBare)
        for (final person in bare) _personRow(l10n, person),
      const SizedBox(height: 16),
      SizedBox(height: _selecting ? 140 : 24),
    ],
  );
}

class _PeopleSelectionBar extends StatelessWidget {
  /// The rarer ones, and Delete away from a slip of the thumb.
  void _more(BuildContext context, AppLocalizations l10n) {
    void run(BuildContext sheet, VoidCallback action) {
      Navigator.of(sheet).pop();
      action();
    }

    showCupertinoModalPopup<void>(
      context: context,
      builder: (sheet) => CupertinoActionSheet(
        title: Text(l10n.selectionTitle(count)),
        actions: [
          if (onFreeUp case final freeUp?)
            CupertinoActionSheetAction(
              key: const ValueKey('peopleBatchFreeUp'),
              onPressed: () => run(sheet, freeUp),
              child: Text(l10n.peopleBatchFreeUp),
            ),
          if (onOptimize case final optimize?)
            CupertinoActionSheetAction(
              key: const ValueKey('peopleBatchOptimize'),
              onPressed: () => run(sheet, optimize),
              child: Text(l10n.peopleBatchOptimize),
            ),
          CupertinoActionSheetAction(
            key: const ValueKey('peopleBatchDelete'),
            isDestructiveAction: true,
            onPressed: () => run(sheet, onDelete),
            child: Text(l10n.actionDelete),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(sheet).pop(),
          child: Text(l10n.actionCancel),
        ),
      ),
    );
  }

  const _PeopleSelectionBar({
    required this.count,
    required this.onHide,
    required this.onUnhide,
    required this.onMerge,
    required this.onEdit,
    required this.onDelete,
    required this.onFreeUp,
    required this.onOptimize,
  });

  final int count;
  final VoidCallback onHide;
  final VoidCallback onUnhide;
  final VoidCallback onMerge;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback? onFreeUp;
  final VoidCallback? onOptimize;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    Widget action(
      IconData icon,
      String label,
      VoidCallback? onPressed,
      Key key,
    ) => Expanded(
      child: CupertinoButton(
        key: key,
        padding: const EdgeInsets.symmetric(vertical: 8),
        onPressed: count == 0 ? null : onPressed,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 22),
            const SizedBox(height: 2),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
    );
    return Container(
      decoration: BoxDecoration(
        color: CupertinoDynamicColor.resolve(
          CupertinoColors.systemBackground,
          context,
        ),
        border: Border(
          top: BorderSide(
            color: CupertinoDynamicColor.resolve(
              CupertinoColors.separator,
              context,
            ),
          ),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    count == 0
                        ? l10n.peopleSelectHint
                        : l10n.selectionTitle(count),
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
          Row(
            children: [
              action(
                CupertinoIcons.eye_slash,
                l10n.libraryHide,
                onHide,
                const ValueKey('peopleBatchHide'),
              ),
              action(
                CupertinoIcons.eye,
                l10n.peopleBatchUnhide,
                onUnhide,
                const ValueKey('peopleBatchUnhide'),
              ),
              action(
                CupertinoIcons.person_2,
                l10n.peopleBatchMerge,
                count < 2 ? null : onMerge,
                const ValueKey('peopleBatchMerge'),
              ),
              action(
                CupertinoIcons.pencil,
                l10n.peopleBatchEdit,
                onEdit,
                const ValueKey('peopleBatchEdit'),
              ),
              action(
                CupertinoIcons.ellipsis_circle,
                l10n.selectionMore,
                () => _more(context, l10n),
                const ValueKey('peopleBatchMore'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// One dropdown in the filters row: its value when set, its name when not.
class _FilterPill extends StatelessWidget {
  const _FilterPill({
    super.key,
    required this.label,
    required this.active,
    required this.onTap,
    this.icon,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final accent = CupertinoTheme.of(context).primaryColor;
    final color = active ? CupertinoColors.white : CupertinoColors.label;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
          decoration: BoxDecoration(
            color: active
                ? accent
                : CupertinoDynamicColor.resolve(
                    CupertinoColors.tertiarySystemFill,
                    context,
                  ),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(
                  icon,
                  size: 14,
                  color: CupertinoDynamicColor.resolve(color, context),
                ),
                const SizedBox(width: 4),
              ],
              Text(
                label,
                style: TextStyle(
                  fontSize: 14,
                  color: CupertinoDynamicColor.resolve(color, context),
                ),
              ),
              Icon(
                CupertinoIcons.chevron_down,
                size: 12,
                color: CupertinoDynamicColor.resolve(color, context),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
