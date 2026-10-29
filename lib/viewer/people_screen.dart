import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:intl/intl.dart';

export '../photos/people_order.dart' show PeopleSort;

import '../l10n/app_localizations.dart';
import '../photos/ai_analysis_store.dart';
import '../photos/conversation_store.dart';
import '../photos/name_sound.dart';
import '../photos/person.dart';
import '../photos/face_identity.dart';
import '../photos/face_import.dart';
import '../photos/person_detail.dart';
import '../photos/person_store.dart';
import '../photos/fix_queue.dart';
import '../photos/people_order.dart';
import '../photos/people_unhide.dart';
import '../photos/storage_advice.dart';
import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import 'person_avatar.dart';
import 'profile_chip.dart';
import 'person_page_screen.dart';
import 'imported_group_screen.dart';
import 'search_picker_sheet.dart';
import 'person_profile_screen.dart';
import 'suggestion_action_screen.dart';
import 'group_screen.dart';
import 'group_picker.dart';
import 'merge_people_screen.dart' show mergePeopleInto;
import 'private_album_gate.dart';
import 'select_all.dart';
import 'ungrouped_people_screen.dart';

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
    this.conversationStore,
  });

  /// The library's, for Remove from iPhone and Optimize on several people
  /// at once; without it those two are not offered.
  final FixQueue? fixQueue;

  /// Null opens the app's own; a widget test passes a fake.
  final ConversationStore? conversationStore;

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

  /// Every photo tagged, hidden ones too: where someone sits in the list.
  /// Hiding their photos must not send them to the bottom, or out of sight.
  Map<String, int> _tagged = const {};

  /// Names each person went by before; search finds them by those too.
  Map<String, List<String>> _formerNames = const {};
  Map<String, String> _firstPhoto = const {};

  /// Every avatar on the page resolves from this, not a query of its own.
  /// Null when there is no record database (a test).
  Map<String, AssetRecord>? _recordsById;
  String _query = '';
  Map<PersonGroup, List<String>> _groups = const {};

  PeopleSort _sort = PeopleSort.lastSeen;
  bool _loaded = false;
  static const _sortKey = peopleSortKey;

  /// When each person was first and last known of: their First met / Last
  /// seen rows, else the earliest / latest dated event or tagged photo.
  Map<String, DateTime> _firstKnown = const {};
  Map<String, DateTime> _lastKnown = const {};

  /// The filters row; null is Any. They narrow together.
  MetBand? _met;
  PersonGroup? _group;

  /// No photos, no group, or no First met: the ones to fill in.
  Set<String> _inAGroup = const {};

  /// Open people in no group, most photos first: once per reload.
  List<Person> _ungrouped = const [];

  /// The biggest few, one tap each beside the Group dropdown.

  /// One size for every circle on this page. A named person and a face
  /// waiting for a name are the same kind of thing asked from two sides,
  /// and drawing them at two scales made the list look like two lists.
  static const _faceSize = 66.0;

  @override
  void initState() {
    super.initState();
    _reload();
    _loadChats();
    _loadFaceGroups();
    unawaited(
      _dropDerivedLastSeen().then((n) {
        if (n > 0 && mounted) _reload();
      }),
    );
    // Flagged people only: catches up an import or merge cut short.
    unawaited(
      applyConversationSpans(widget.personStore).then((changed) {
        if (changed && mounted) _reload();
      }),
    );
  }

  /// Once per install: Last seen dates that photos and chats wrote before
  /// it was worked out on the fly ([knownDates]), so removing a photo can
  /// move it back.
  Future<int> _dropDerivedLastSeen() async {
    const key = 'people.lastSeenDerivedDropped';
    try {
      final settings = widget.assetRecordStore;
      if (await settings.getAppState(key) == '1') return 0;
      final members = await widget.personStore.allMemberships();
      final taken = {
        for (final r in await settings.listAll())
          r.localId: r.createdAt.millisecondsSinceEpoch,
      };
      final chats = widget.conversationStore ?? ConversationStore();
      final n = await widget.personStore.dropDerivedLastSeen((id, at) async {
        final ms = at.millisecondsSinceEpoch;
        if ((members[id] ?? const []).any((p) => taken[p] == ms)) return true;
        try {
          return await chats.hasMessageAt(id, at);
        } catch (_) {
          return false;
        }
      });
      await settings.setAppState(key, '1');
      return n;
    } catch (_) {
      return 0;
    }
  }

  /// Messages per person: one grouped query, on opening and after an
  /// import — not with every reload, which no edit here changes.
  Map<String, int> _chats = const {};

  /// Imported face groups still waiting for a name, biggest first, and
  /// the records their faces draw from. Listed first in Faces to Name.
  List<StoredFaceGroup> _imported = const [];
  Map<String, AssetRecord> _importedRecords = const {};

  Future<void> _loadFaceGroups() async {
    final analysis = widget.aiAnalysisStore;
    if (analysis == null) return;
    try {
      final found = await loadFaceGroups(analysis, widget.assetRecordStore);
      if (!mounted) return;
      setState(() {
        _imported = found.groups;
        _importedRecords = found.records;
      });
      _pageTick.value++;
    } catch (_) {
      // No analysis database: nothing was imported.
    }
  }

  Future<void> _openImported(StoredFaceGroup group) async {
    var left = group.faces;
    await Navigator.of(context).push(
      CupertinoPageRoute<void>(
        builder: (_) => ImportedGroupScreen(
          group: group,
          records: _importedRecords,
          analysisStore: widget.aiAnalysisStore!,
          assetRecordStore: widget.assetRecordStore,
          personStore: widget.personStore,
          onOpenAsset: widget.onOpenAsset,
          onLeft: (faces) => left = faces,
        ),
      ),
    );
    if (!mounted) return;
    // At once from what the page reports; the full read follows.
    if (!identical(left, group.faces)) {
      setState(() {
        _imported = [
          for (final g in _imported)
            if (g.id != group.id)
              g
            else if (left.isNotEmpty)
              StoredFaceGroup(id: g.id, suggest: g.suggest, faces: left),
        ];
      });
      _pageTick.value++;
    }
    await _loadFaceGroups();
    await _reload();
  }

  Widget _importedRow(AppLocalizations l10n, StoredFaceGroup group) =>
      CupertinoListTile(
        key: ValueKey('people-imported-${group.id}'),
        leadingSize: _faceSize + 4,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: CupertinoColors.systemGrey, width: 1.5),
          ),
          padding: const EdgeInsets.all(2),
          child: PersonAvatar(
            assetRecordStore: widget.assetRecordStore,
            localId: group.faces.first.localId,
            face: group.faces.first.face,
            records: _importedRecords,
            size: _faceSize,
          ),
        ),
        title: Text(
          group.suggest == null
              ? l10n.peopleUnnamedFace
              : l10n.peopleSuggestedFace(group.suggest!),
          style: const TextStyle(color: CupertinoColors.systemGrey),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '${group.faces.length}',
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
        onTap: () => _openImported(group),
      );

  Future<void> _loadChats() async {
    try {
      final chats = await (widget.conversationStore ?? ConversationStore())
          .countsByPerson();
      if (mounted) setState(() => _chats = chats);
    } catch (_) {
      // No conversations database: nobody shows a chat.
    }
  }

  Future<void> _reload() async {
    final people = await widget.personStore.listAll();
    final records = await _records();
    // Counted over what may be shown: a hidden photo in the count gives
    // away that it exists.
    final visible = visibleIdsOf(records);
    final present = {for (final r in records) r.localId};
    final counts = <String, int>{};
    final taggedCounts = <String, int>{};
    final firstPhoto = <String, String>{};
    final tagged = <String>{};
    final members = _members = await widget.personStore.allMemberships();
    for (final person in people) {
      final shown = [
        for (final id in members[person.id] ?? const <String>[])
          if (visible.contains(id)) id,
      ];
      counts[person.id] = shown.length;
      taggedCounts[person.id] = [
        for (final id in members[person.id] ?? const <String>[])
          if (present.contains(id)) id,
      ].length;
      tagged.addAll(members[person.id] ?? const <String>[]);
      if (shown.isNotEmpty) firstPhoto[person.id] = shown.first;
    }
    final groups = await widget.personStore.allGroups();
    final formerNames = await widget.personStore.allFormerNames();
    final spans = await widget.personStore.openEventSpans();
    final byId = visibleRecordsOf(records);
    final (first: firstKnown, last: lastKnown) = knownDates(
      people,
      members,
      byId,
      spans,
      chats: await latestChats(widget.conversationStore),
    );
    final sort = await _loadSort();
    final messages = sort == PeopleSort.messages
        ? await messageCounts(widget.conversationStore)
        : _chats;
    sortPeople(
      people,
      sort,
      counts: taggedCounts,
      messages: messages,
      firstKnown: firstKnown,
      lastKnown: lastKnown,
    );
    if (!mounted) return;
    setState(() {
      _sort = sort;
      if (sort == PeopleSort.messages) _chats = messages;
      _firstKnown = firstKnown;
      _lastKnown = lastKnown;
      _groups = groups;
      _initials.clear();
      _inAGroup = {for (final ids in groups.values) ...ids};
      _ungrouped = [
        for (final p in people)
          if (!p.locked && !_inAGroup.contains(p.id)) p,
      ]..sort((a, b) => (counts[b.id] ?? 0).compareTo(counts[a.id] ?? 0));
      // The filter's group by id: a reload hands out new instances, and
      // the old one is no key into the new map.
      _group = groups.keys.where((g) => g.id == _group?.id).firstOrNull;
      _formerNames = formerNames;
      _people = people;
      _counts = counts;
      _tagged = taggedCounts;
      _firstPhoto = firstPhoto;
      _recordsById = records.isEmpty ? null : byId;
      _loaded = true;
    });
    _pageTick.value++;
  }

  Future<void> _openUngrouped() async {
    await Navigator.of(context).push(
      CupertinoPageRoute<void>(
        builder: (_) => UngroupedPeopleScreen(
          people: _ungrouped,
          personStore: widget.personStore,
          assetRecordStore: widget.assetRecordStore,
        ),
      ),
    );
    await _reload();
  }

  Future<PeopleSort> _loadSort() => loadPeopleSort(widget.assetRecordStore);

  Future<void> _setSort(PeopleSort sort) async {
    if (sort == PeopleSort.messages) {
      _chats = await messageCounts(widget.conversationStore);
      if (!mounted) return;
    }
    final people = [..._people];
    sortPeople(
      people,
      sort,
      counts: _tagged,
      messages: _chats,
      firstKnown: _firstKnown,
      lastKnown: _lastKnown,
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
    PeopleSort.messages => l10n.peopleSortMessages,
    PeopleSort.firstMet => l10n.peopleSortFirstMet,
    PeopleSort.lastSeen => l10n.peopleSortLastSeen,
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

  /// The toast's own auto-dismiss. Held so leaving the page takes it with
  /// us — a timer that fires into a disposed tree is a crash waiting for
  /// whoever navigates away inside five seconds.
  Timer? _undoTimer;
  OverlayEntry? _undoToast;

  @override
  void dispose() {
    _pageTick.dispose();
    _scroll.dispose();
    _undoTimer?.cancel();
    _undoToast?.remove();
    _undoToast = null;
    super.dispose();
  }

  /// A new selection is a new action: the last one's Undo would sit on
  /// the selection bar.
  void _dismissUndo() {
    _undoTimer?.cancel();
    _undoToast?.remove();
    _undoToast = null;
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

  /// Under the search box: one dropdown per filter, then the sort.
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

  /// Their profile photo stays out: hiding the rest shouldn't leave them
  /// a grey circle.
  Future<void> _hidePeople(Set<String> ids) async {
    final l10n = AppLocalizations.of(context)!;
    final faces = {
      for (final person in _people)
        if (ids.contains(person.id))
          ?(person.avatarLocalId ?? _firstPhoto[person.id]),
    };
    final (records: all, :owner) = _photosOf(ids);
    final records = [
      for (final r in all)
        if (!faces.contains(r.localId)) r,
    ];
    if (records.isEmpty) {
      return _note(
        all.isEmpty
            ? l10n.peopleBatchNothingToHide
            : l10n.peopleHideOnlyProfile,
      );
    }
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
    if (picked.isEmpty) return;
    final keep = picked.length == 1 ? picked.single : await _chooseKeep(picked);
    if (picked.length == 1 && keep != null) {
      final other = await _chooseMergeIn(keep);
      if (other == null) return;
      picked.add(other);
    }
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

  /// One picked: who merges into them.
  Future<Person?> _chooseMergeIn(Person keep) {
    final l10n = AppLocalizations.of(context)!;
    return showSearchPickerSheetOf<Person>(
      context: context,
      title: l10n.peopleMergeInTitle(keep.name),
      options: [
        for (final p in _people)
          if (p.id != keep.id) p,
      ],
      labelOf: (p) => p.name,
    );
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
    // What each had, to put back: their old row, or none (a new id).
    final before = <String, PersonEvent?>{};
    final made = <String>[];
    for (final id in _picked) {
      final events = await widget.personStore.eventsFor(id);
      final had = events.where((e) => e.type == type).firstOrNull;
      final eventId = had?.id ?? widget.personStore.newId();
      if (had == null) made.add(eventId);
      before[id] = had;
      await widget.personStore.saveEvent(
        PersonEvent(
          id: eventId,
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
    if (!mounted) return;
    _showUndo(AppLocalizations.of(context)!.peopleUndoDateSet(title), () async {
      for (final had in before.values) {
        if (had != null) {
          await widget.personStore.saveEvent(had, scope: PersonScope.open);
        }
      }
      for (final id in made) {
        await widget.personStore.removeEvent(id, scope: PersonScope.open);
      }
      if (mounted) await _reload();
    });
  }

  Future<void> _addPickedToGroup() => _addToGroup(_picked);

  /// Only groups somebody picked is in; everyone picked who is in it leaves.
  Future<void> _removePickedFromGroup() async {
    final l10n = AppLocalizations.of(context)!;
    final groups = [
      for (final MapEntry(key: g, value: ids) in _sortedGroups())
        if (ids.any(_picked.contains)) g,
    ];
    if (groups.isEmpty) return _note(l10n.peopleBatchNoGroups);
    final group = await showSearchPickerSheetOf<PersonGroup>(
      context: context,
      title: l10n.peopleBatchLeaveGroup,
      options: groups,
      labelOf: (g) => g.name,
      autofocus: false,
    );
    if (group == null || !mounted) return;
    final left = [
      for (final id in _groups[group] ?? const <String>[])
        if (_picked.contains(id)) id,
    ];
    for (final id in left) {
      await widget.personStore.leaveGroup(
        id,
        group.id,
        scope: PersonScope.open,
      );
    }
    if (!mounted) return;
    _endSelecting();
    await _reload();
    if (!mounted) return;
    _showUndo(l10n.peopleUndoGroupLeft(group.name), () async {
      for (final id in left) {
        await widget.personStore.joinGroup(id, group, scope: PersonScope.open);
      }
      if (mounted) await _reload();
    });
  }

  Future<void> _addToGroup(Set<String> ids) async {
    final picked = {...ids};
    final group = await addPeopleToGroup(
      context,
      personStore: widget.personStore,
      groups: _groups.keys,
      personIds: picked,
    );
    if (group == null || !mounted) return;
    final already = {
      for (final MapEntry(key: g, value: members) in _groups.entries)
        if (g.id == group.id) ...members,
    };
    if (_selecting) _endSelecting();
    await _reload();
    if (!mounted) return;
    final l10n = AppLocalizations.of(context)!;
    _showUndo(l10n.peopleUndoGroupAdded(group.name), () async {
      for (final id in picked.difference(already)) {
        await widget.personStore.leaveGroup(
          id,
          group.id,
          scope: PersonScope.open,
        );
      }
      if (mounted) await _reload();
    });
  }

  /// Holding a row starts select mode with that person picked.
  void _startSelecting(Person person) => setState(() {
    _selecting = true;
    _dismissUndo();
    _picked = {person.id};
  });

  Future<void> _renamePicked() async {
    final person = _people.where((p) => _picked.contains(p.id)).firstOrNull;
    if (_picked.length != 1 || person == null) return;
    _endSelecting();
    await _rename(person);
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
    if (!mounted) return;
    await _reload();
    if (!mounted) return;
    _showUndo(l10n.peopleUndoRenamed(trimmed), () async {
      final now = await widget.personStore.getById(person.id);
      if (now != null) {
        await widget.personStore.update(now.copyWith(name: person.name));
      }
      if (mounted) await _reload();
    });
  }

  /// Opens the same page Suggestions does, so the run is the queue's:
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
        builder: (_) => SuggestionActionScreen(
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
  final _pageTick = ValueNotifier<int>(0);
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

  List<MapEntry<PersonGroup, List<String>>> _sortedGroups() =>
      _groups.entries.toList()..sort(
        (a, b) => a.key.name.toLowerCase().compareTo(b.key.name.toLowerCase()),
      );

  /// Named, then its first people: a group is its members, so one with
  /// nobody in it isn't kept.
  Future<void> _newGroup() async {
    final l10n = AppLocalizations.of(context)!;
    final name = await showProfileTextPrompt(
      context,
      title: l10n.peopleNewGroup,
      placeholder: l10n.peopleNewGroupName,
    );
    if (name == null || name.isEmpty || !mounted) return;
    final chosen = await showSearchPickerSheetMulti<Person>(
      context: context,
      title: l10n.groupAddPeople,
      options: [
        for (final p in _people)
          if (!p.locked) p,
      ],
      labelOf: (p) => p.name,
    );
    if (chosen == null || chosen.isEmpty) return;
    final group = PersonGroup(
      id: widget.personStore.newId(),
      name: name,
      kind: GroupKind.circle,
    );
    for (final p in chosen) {
      await widget.personStore.joinGroup(p.id, group, scope: PersonScope.open);
    }
    if (mounted) await _reload();
  }

  Future<void> _openGroup(PersonGroup group) async {
    await Navigator.of(context).push(
      CupertinoPageRoute<void>(
        builder: (_) => GroupScreen(
          group: group,
          personStore: widget.personStore,
          assetRecordStore: widget.assetRecordStore,
        ),
      ),
    );
    if (mounted) await _reload();
  }

  static const _foldAt = 10;

  /// "Show all n" folded, "Show fewer" open: a long list folds back.
  Widget _foldToggle(
    AppLocalizations l10n,
    Key key,
    int total,
    bool open,
    VoidCallback onToggle,
  ) => total <= _foldAt
      ? const SizedBox.shrink()
      : CupertinoButton(
          key: key,
          onPressed: onToggle,
          child: Text(open ? l10n.peopleShowFewer : l10n.peopleShowAll(total)),
        );

  List<Widget> _groupRows(AppLocalizations l10n) => [
    CupertinoListTile(
      key: const ValueKey('people-new-group'),
      title: Text(
        l10n.peopleNewGroup,
        style: TextStyle(color: CupertinoTheme.of(context).primaryColor),
      ),
      onTap: _newGroup,
    ),
    for (final MapEntry(key: group, value: ids) in _sortedGroups())
      CupertinoListTile(
        key: ValueKey('people-group-${group.id}'),
        title: Text(group.name),
        subtitle: Text(groupKindLabel(l10n, group.kind)),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '${ids.length}',
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
        onTap: () => _openGroup(group),
      ),
  ];

  /// A row's own page, rebuilt with every reload.
  void _openSubpage(String title, Key key, List<Widget> Function() rows) {
    Navigator.of(context).push(
      CupertinoPageRoute<void>(
        builder: (_) => CupertinoPageScaffold(
          navigationBar: CupertinoNavigationBar(middle: Text(title)),
          child: SafeArea(
            child: ValueListenableBuilder<int>(
              valueListenable: _pageTick,
              builder: (_, _, _) => ListView(key: key, children: rows()),
            ),
          ),
        ),
      ),
    );
  }

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
              valueListenable: _pageTick,
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
          '${_imported.length}',
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
          Text(
            '${_imported.length}',
            style: const TextStyle(
              fontSize: 13,
              color: CupertinoColors.systemGrey,
            ),
          ),
        ],
      ),
    ),
    for (final group in _imported) _importedRow(l10n, group),
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

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final query = _query.trim().toLowerCase();
    final now = DateTime.now();
    // Searched: best match first, whatever the sort.
    final filtered = searchByNames(
      [
        for (final person in _people)
          if (_matchesFilter(person, now)) person,
      ],
      query,
      (p) => [p.name, ...?_formerNames[p.id]],
    );
    final narrowed = query.isNotEmpty || _met != null || _group != null;
    // No visible photo: one row to open, unless searched or filtered for,
    // or nobody has one yet.
    final fold = !narrowed && filtered.any((p) => (_tagged[p.id] ?? 0) > 0);
    final main = [
      for (final p in filtered)
        if (!fold || (_tagged[p.id] ?? 0) > 0) p,
    ];
    final bare = [
      for (final p in filtered)
        if (fold && (_tagged[p.id] ?? 0) == 0) p,
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
                key: const ValueKey('peopleAddPerson'),
                padding: EdgeInsets.zero,
                onPressed: _addPerson,
                child: const Icon(CupertinoIcons.add),
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
            if (_sort == PeopleSort.name &&
                folded.length == main.length &&
                main.length >= _indexFrom)
              Positioned(
                right: 0,
                top: 0,
                bottom: _selecting ? 140 : 0,
                child: _IndexStrip(
                  letters: {for (final p in folded) _initialOf(p)}.toList(),
                  onLetter: (l) => _jumpTo(l, folded),
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
                  onRename: _renamePicked,
                  onAddToGroup: _addPickedToGroup,
                  onLeaveGroup: _removePickedFromGroup,
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

  /// Headings by what the list is sorted by: initial, year met or seen.
  String? _headingOf(AppLocalizations l10n, Person p) {
    String year(DateTime? at) => at == null ? l10n.peopleNoDate : '${at.year}';
    return switch (_sort) {
      PeopleSort.name => _initialOf(p),
      PeopleSort.firstMet => year(_firstKnown[p.id]),
      PeopleSort.lastSeen => year(_lastKnown[p.id]),
      _ => null,
    };
  }

  final _headingKeys = <String, GlobalKey>{};

  /// Pinyin per name is not free; cleared with each reload.
  final _initials = <String, String>{};
  String _initialOf(Person p) => _initials[p.id] ??= nameInitial(p.name);

  List<Widget> _rowsWithHeadings(AppLocalizations l10n, List<Person> rows) {
    String? last;
    return [
      for (final p in rows) ...[
        if (_query.trim().isEmpty ? _headingOf(l10n, p) : null case final h?
            when h != last) ...[
          Padding(
            key: _headingKeys.putIfAbsent(h, GlobalKey.new),
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
            child: Text(
              last = h,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: CupertinoColors.systemGrey,
              ),
            ),
          ),
        ],
        _personRow(l10n, p),
      ],
    ];
  }

  static const _indexFrom = 20;

  /// The heading may not be built yet (the list is lazy): jump to about
  /// where it is, then onto it once it has been laid out.
  void _jumpTo(String letter, List<Person> rows) {
    void land() {
      final ctx = _headingKeys[letter]?.currentContext;
      if (ctx != null) Scrollable.ensureVisible(ctx);
    }

    if (_headingKeys[letter]?.currentContext == null) {
      final at = rows.indexWhere((p) => _initialOf(p) == letter);
      if (at < 0 || !_scroll.hasClients) return;
      final pos = _scroll.position;
      pos.jumpTo(pos.maxScrollExtent * at / rows.length);
      WidgetsBinding.instance.addPostFrameCallback((_) => land());
    } else {
      land();
    }
  }

  Widget _personRow(AppLocalizations l10n, Person person) => GestureDetector(
    key: ValueKey('people-row-${person.id}'),
    onLongPress: _selecting ? null : () => _startSelecting(person),
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
      // Beside the name: a mark that they have chats, not a count of them
      // next to the photo count.
      title: Row(
        children: [
          Flexible(child: Text(person.name, overflow: TextOverflow.ellipsis)),
          if ((_chats[person.id] ?? 0) > 0)
            Padding(
              key: ValueKey('people-chats-${person.id}'),
              padding: const EdgeInsets.only(left: 6),
              child: const Icon(
                CupertinoIcons.chat_bubble_2,
                size: 16,
                color: CupertinoColors.systemGrey,
              ),
            ),
        ],
      ),
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
            autocorrect: false,
            // Not autofocused: the page is a list you came to read,
            // and a keyboard covering half of it on arrival is a
            // dismissal to do before you can look at anything.
            onChanged: (v) => setState(() => _query = v),
          ),
        ),
      if (_people.isNotEmpty) _filterRow(l10n),
      if (_people.isNotEmpty && query.isEmpty)
        CupertinoListTile(
          key: const ValueKey('people-groups-row'),
          leading: const Icon(
            CupertinoIcons.person_3,
            color: CupertinoColors.systemGrey,
          ),
          title: Text(l10n.peopleGroupsRow),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${_groups.length}',
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
          onTap: () => _openSubpage(
            l10n.peopleGroupsRow,
            const ValueKey('people-groups-page'),
            () => _groupRows(l10n),
          ),
        ),
      // Things to sort out first, the list itself after.
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
              const Icon(
                CupertinoIcons.chevron_forward,
                size: 18,
                color: CupertinoColors.systemGrey2,
              ),
            ],
          ),
          onTap: () => _openSubpage(
            l10n.peopleNoPhotosRow,
            const ValueKey('people-bare-page'),
            () => [
              for (final p in _people)
                if ((_tagged[p.id] ?? 0) == 0) _personRow(l10n, p),
            ],
          ),
        ),
      if (_ungrouped.isNotEmpty && query.isEmpty)
        CupertinoListTile(
          key: const ValueKey('people-ungrouped-row'),
          leading: const Icon(
            CupertinoIcons.person_3_fill,
            color: CupertinoColors.systemGrey,
          ),
          title: Text(l10n.ungroupedTitle),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${_ungrouped.length}',
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
          onTap: _openUngrouped,
        ),
      if (_imported.isNotEmpty && query.isEmpty) _facesRow(l10n),
      if (_people.isNotEmpty) _sectionHeading(l10n.peopleSectionNamed),
      if (!_loaded)
        const Padding(
          padding: EdgeInsets.only(top: 48),
          child: CupertinoActivityIndicator(),
        )
      else if (_people.isEmpty && _imported.isEmpty)
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
        ..._rowsWithHeadings(l10n, folded),
      if (folded.length < main.length || _showAllPeople)
        _foldToggle(
          l10n,
          const ValueKey('people-show-all'),
          main.length,
          _showAllPeople,
          () => setState(() => _showAllPeople = !_showAllPeople),
        ),
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
          if (count == 1)
            CupertinoActionSheetAction(
              key: const ValueKey('peopleBatchRename'),
              onPressed: () => run(sheet, onRename),
              child: Text(l10n.peopleMenuRename),
            ),
          CupertinoActionSheetAction(
            key: const ValueKey('peopleBatchGroup'),
            onPressed: () => run(sheet, onAddToGroup),
            child: Text(l10n.peopleBatchAddToGroup),
          ),
          CupertinoActionSheetAction(
            key: const ValueKey('peopleBatchLeaveGroup'),
            onPressed: () => run(sheet, onLeaveGroup),
            child: Text(l10n.peopleBatchLeaveGroup),
          ),
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
    required this.onRename,
    required this.onAddToGroup,
    required this.onLeaveGroup,
    required this.onDelete,
    required this.onFreeUp,
    required this.onOptimize,
  });

  final int count;
  final VoidCallback onHide;
  final VoidCallback onUnhide;
  final VoidCallback onMerge;
  final VoidCallback onEdit;
  final VoidCallback onRename;
  final VoidCallback onAddToGroup;
  final VoidCallback onLeaveGroup;
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
                onMerge,
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

/// A–Z down the right edge; a tap or a drag lands on that letter.
class _IndexStrip extends StatelessWidget {
  const _IndexStrip({required this.letters, required this.onLetter});

  final List<String> letters;
  final void Function(String) onLetter;

  static const _row = 15.0;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final top = (box.maxHeight - letters.length * _row) / 2;
      void at(double dy) {
        final i = ((dy - top) / _row).floor();
        onLetter(letters[i.clamp(0, letters.length - 1)]);
      }

      return GestureDetector(
        key: const ValueKey('people-index'),
        behavior: HitTestBehavior.opaque,
        onTapDown: (d) => at(d.localPosition.dy),
        onVerticalDragUpdate: (d) => at(d.localPosition.dy),
        child: SizedBox(
          width: 20,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (final l in letters)
                SizedBox(
                  height: _row,
                  child: Center(
                    child: Text(
                      l,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: CupertinoTheme.of(context).primaryColor,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    },
  );
}
