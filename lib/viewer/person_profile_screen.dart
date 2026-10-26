import 'package:flutter/cupertino.dart';
import 'package:flutter/rendering.dart' show RenderAbstractViewport;
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../photos/conversation_store.dart';
import '../photos/known_names.dart';
import '../photos/name_parts.dart';
import '../photos/person.dart';
import '../photos/face_identity.dart';
import '../photos/person_detail.dart';
import '../photos/person_owner.dart';
import '../photos/people_zip.dart' show undatedImport;
import '../photos/person_store.dart';
import '../photos/words_file.dart';
import '../photos/words_store.dart';
import '../storage/asset_record_store.dart';
import '../vault/keys.dart';
import '../vault/passcode_tags.dart';
import '../vault/passphrase_sheet.dart';
import 'conversation_screen.dart';
import 'custom_fields_editor.dart';
import 'person_event_sheet.dart';
import 'person_traits_editor.dart';
import 'known_as_screen.dart';
import 'profile_chip.dart';
import 'private_album_gate.dart';
import 'profile_impression.dart';
import 'profile_people_list_screen.dart';
import 'profile_previews.dart';
import 'profile_relationships.dart';
import 'profile_section.dart';
import 'profile_summary.dart';
import 'undo_toast.dart';
import 'person_avatar.dart';
import 'person_avatar_picker.dart';
import 'person_timeline_screen.dart';
import 'person_change_log_screen.dart';
import 'person_graph_screen.dart';
import 'person_history_detail_screen.dart';
import 'person_page_screen.dart';
import 'person_picker_sheet.dart';
import 'search_picker_sheet.dart';
import 'words_screen.dart';

export 'profile_section.dart'
    show
        profileSectionAddKey,
        profileSectionPromptKey,
        profileSectionHeaderKey,
        profileSectionEditKey;

/// The full editable profile behind a person page's name chevron.
///
/// Name, a summary card and a pinned row of jumps, then by how often each
/// part is wanted: About, Chats and Words, Relationships and Groups, Work,
/// Life (places, events, impression, more details), and name parts and
/// utilities last. Every section folds; an empty one is a single "Add" row.
///
/// Everything below the name belongs to a passcode rather than to the
/// person — four digits on the keypad in the nav bar switch which set is on
/// screen, and digits nobody has used show an empty one. Identity and photos
/// are visible either way. See `person_detail.dart` and
/// IMPLEMENTATION_PLAN.md T7.3-T7.7.
class PersonProfileScreen extends StatefulWidget {
  const PersonProfileScreen({
    super.key,
    required this.person,
    required this.personStore,
    required this.assetRecordStore,
    this.vaultKeys,
    this.autofocusName = false,
    this.conversationStore,
    this.wordsStore,
    this.onOpenPhotos,
  });

  /// The photos count on the summary card. From their page, back to it;
  /// absent, their page is opened.
  final VoidCallback? onOpenPhotos;

  final ConversationStore? conversationStore;
  final WordsStore? wordsStore;

  final Person person;
  final PersonStore personStore;
  final AssetRecordStore assetRecordStore;

  /// Where the four digits become a key. App-wide and shared with the
  /// private album: one passphrase, set from whichever screen asks first.
  final VaultKeys? vaultKeys;

  /// Straight into the name field with the keyboard up — how a brand new
  /// person arrives here, where the only thing missing is the name.
  final bool autofocusName;

  @override
  State<PersonProfileScreen> createState() => _PersonProfileScreenState();
}

class _PersonProfileScreenState extends State<PersonProfileScreen> {
  late Person _person = widget.person;
  late final _first = TextEditingController(text: widget.person.firstName);
  late final _middle = TextEditingController(text: widget.person.middleName);
  late final _last = TextEditingController(text: widget.person.lastName);
  late final TextEditingController _name = TextEditingController(
    text: _person.name,
  );
  late final TextEditingController _bio = TextEditingController(
    text: _detail.bio,
  );
  late final TextEditingController _hint = TextEditingController(
    text: _detail.hint,
  );

  /// Which set of details is on screen. The open one until somebody types
  /// four digits, and then theirs — empty if nothing has been kept there,
  /// which is indistinguishable from digits that open nothing.
  PersonScope _scope = PersonScope.open;
  String get _namespace => _scope.passcodeHash;
  AlbumKeys? get _keys => _scope.keys;
  PersonDetail _detail = PersonDetail.empty;

  /// True while a set's details are on their way in after a switch: nothing
  /// on screen belongs to the set yet, so nothing may be saved into it.
  bool _loading = false;

  late final VaultKeys _vaultKeys = widget.vaultKeys ?? VaultKeys();
  late final ConversationStore _conversationStore =
      widget.conversationStore ?? ConversationStore();
  int _conversations = 0;
  ChatsPreviewData _chats = ChatsPreviewData.empty;
  late final WordsStore _wordsStore = widget.wordsStore ?? WordsStore();
  Map<WritingKind, int> _wordCounts = const {};
  List<WritingSummary> _latestWords = const [];
  int _photoCount = 0;
  Map<String, int> _sharedPhotos = const {};
  Map<String, Person> _peopleById = const {};

  /// Drawn links only, kept beside [_relationships] so the section's
  /// ranking runs when they change, not on every build.
  List<PersonRelationship> _explicit = const [];

  /// Sections in Edit, by id.
  final _editing = <String>{};
  final _undo = UndoToast();
  final _scroll = ScrollController();
  final _anchors = {
    for (final id in ['about', 'chats', 'words', 'people', 'work', 'life'])
      id: GlobalKey(),
  };
  final _fieldsKey = GlobalKey<CustomFieldsEditorState>();
  late final PersonOwner _owner = PersonOwner(widget.assetRecordStore);

  String? _ownerId;
  List<PersonRelationship> _relationships = const [];
  List<Person> _allPeople = const [];
  Map<String, String> _namesById = const {};
  List<PersonLocation> _locations = const [];
  List<PersonHistoryEntry> _education = const [];
  List<PersonHistoryEntry> _jobs = const [];
  List<PersonEvent> _events = const [];
  List<PersonGroup> _groups = const [];

  /// Every group in this set, so a profile can be added to one that already
  /// exists instead of retyping its name.
  Map<PersonGroup, List<String>> _allGroups = const {};

  @override
  void initState() {
    super.initState();
    _reload();
    _loadFormerNames();
    _loadChats();
    _loadWords();
  }

  /// Newest visible photo and newest chat message: with the events, what
  /// Last seen is worked out from. Never written down, so removing a photo
  /// moves it back.
  DateTime? _photoSeen;
  DateTime? _chatSeen;

  Future<void> _loadSeen() async {
    DateTime? photo;
    DateTime? chat;
    var count = 0;
    try {
      final ids = await widget.personStore.localIdsIn(_person.id);
      final shown = await widget.assetRecordStore.getVisibleByLocalIds(ids);
      count = shown.length;
      for (final r in shown.values) {
        if (undatedImport(r)) continue;
        if (photo == null || r.createdAt.isAfter(photo)) photo = r.createdAt;
      }
    } catch (_) {}
    try {
      chat = await _conversationStore.latestFor(_person.id);
    } catch (_) {}
    if (mounted) {
      setState(() {
        _photoSeen = photo;
        _chatSeen = chat;
        _photoCount = count;
      });
    }
  }

  Future<void> _loadWords() async {
    try {
      final counts = await _wordsStore.countsByKind(_person.id);
      final latest = counts.isEmpty
          ? const <WritingSummary>[]
          : await _wordsStore.page(_person.id, limit: 3);
      if (mounted) {
        setState(() {
          _wordCounts = counts;
          _latestWords = latest;
        });
      }
    } catch (_) {
      // No words database: nothing imported.
    }
  }

  Future<void> _openWords([WritingKind? kind]) => Navigator.of(context).push(
    CupertinoPageRoute<void>(
      builder: (_) =>
          WordsScreen(person: _person, store: _wordsStore, kind: kind),
    ),
  );

  int get _wordTotal => _wordCounts.values.fold(0, (n, v) => n + v);

  Widget _wordsSection() => WordsPreview(
    latest: _latestWords,
    total: _wordTotal,
    onOpenAll: _openWords,
    onOpen: (w) => Navigator.of(context).push(
      CupertinoPageRoute<void>(
        builder: (_) => WritingScreen(id: w.id, store: _wordsStore),
      ),
    ),
  );

  /// Count, newest message, per-app counts and per-year counts: four
  /// queries for the person however many chats they have.
  Future<void> _loadChats() async {
    try {
      final n = await _conversationStore.countFor(_person.id);
      if (n == 0) {
        if (mounted && _conversations != 0) {
          setState(() {
            _conversations = 0;
            _chats = ChatsPreviewData.empty;
          });
        }
        return;
      }
      final last = await _conversationStore.page(_person.id, limit: 1);
      final chats = await _conversationStore.chatsOf(_person.id);
      final bySource = <String, int>{};
      for (final c in chats) {
        bySource[c.source] = (bySource[c.source] ?? 0) + c.count;
      }
      if (!mounted) return;
      setState(() {
        _conversations = n;
        _chats = ChatsPreviewData(
          total: n,
          last: last.firstOrNull,
          bySource: bySource,
        );
      });
    } catch (_) {
      // No conversations database: nothing imported.
    }
  }

  Future<void> _openChats() async {
    await Navigator.of(context).push(
      CupertinoPageRoute<void>(
        builder: (_) =>
            ConversationScreen(person: _person, store: _conversationStore),
      ),
    );
  }

  /// First, middle and last, under the display name. Empty ones show what
  /// the name suggests, and one tap fills them in.
  Widget _nameParts(AppLocalizations l10n) {
    final suggested = suggestNameParts(_name.text);
    final empty =
        _first.text.isEmpty && _middle.text.isEmpty && _last.text.isEmpty;
    final hasSuggestion =
        suggested.first.isNotEmpty || suggested.last.isNotEmpty;
    Widget field(
      String key,
      TextEditingController controller,
      String label,
      String hint,
      Person Function(String) apply,
    ) => Expanded(
      child: CupertinoTextField(
        key: ValueKey('personNamePart-$key'),
        controller: controller,
        placeholder: hint.isEmpty ? label : hint,
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 14, color: CupertinoColors.white),
        decoration: BoxDecoration(
          color: const Color(0xFF2C2C2E),
          borderRadius: BorderRadius.circular(8),
        ),
        onChanged: (v) {
          _persist(apply(v.trim()));
          setState(() {});
        },
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 10, 24, 0),
      child: Column(
        children: [
          Row(
            children: [
              field(
                'first',
                _first,
                l10n.personFirstName,
                suggested.first,
                (v) => _person.copyWith(firstName: v),
              ),
              const SizedBox(width: 6),
              field(
                'middle',
                _middle,
                l10n.personMiddleName,
                suggested.middle,
                (v) => _person.copyWith(middleName: v),
              ),
              const SizedBox(width: 6),
              field(
                'last',
                _last,
                l10n.personLastName,
                suggested.last,
                (v) => _person.copyWith(lastName: v),
              ),
            ],
          ),
          if (empty && hasSuggestion)
            CupertinoButton(
              key: const ValueKey('personNamePartsSuggest'),
              padding: const EdgeInsets.only(top: 4),
              minimumSize: Size.zero,
              onPressed: () {
                _first.text = suggested.first;
                _middle.text = suggested.middle;
                _last.text = suggested.last;
                _persist(
                  _person.copyWith(
                    firstName: suggested.first,
                    middleName: suggested.middle,
                    lastName: suggested.last,
                  ),
                );
                setState(() {});
              },
              child: Text(
                l10n.personNamePartsUse,
                style: const TextStyle(fontSize: 13),
              ),
            ),
        ],
      ),
    );
  }

  /// Names they went by before: renamed from, or merged in.
  List<String> _formerNames = const [];

  /// What imports called them: names, and chats.
  List<KnownAs> _knownAs = const [];

  Future<void> _loadFormerNames() async {
    final names = await widget.personStore.formerNames(_person.id);
    final known = await widget.personStore.knownAsOf(_person.id);
    if (mounted) {
      setState(() {
        _formerNames = names;
        _knownAs = known;
      });
    }
  }

  /// Former and remembered names, each once; chats only when no name.
  List<String> get _alsoKnownAs {
    final names = <String>[];
    void add(String n) {
      if (!names.any((o) => nameKey(o) == nameKey(n))) names.add(n);
    }

    _formerNames.forEach(add);
    for (final k in _knownAs) {
      if (k.kind == KnownAs.name) add(k.value);
    }
    if (names.isEmpty) {
      for (final k in _knownAs) {
        add(k.value);
      }
    }
    return names;
  }

  Future<void> _openKnownAs() async {
    await Navigator.of(context).push(
      CupertinoPageRoute<void>(
        builder: (_) => KnownAsScreen(
          personId: _person.id,
          personStore: widget.personStore,
        ),
      ),
    );
    await _loadFormerNames();
  }

  @override
  void dispose() {
    _name.dispose();
    _first.dispose();
    _middle.dispose();
    _last.dispose();
    _bio.dispose();
    _hint.dispose();
    _undo.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    _loadSeen();
    final store = widget.personStore;
    final scope = _scope;
    final ns = scope.passcodeHash;
    final keys = scope.keys;
    final detail = await store.detailFor(
      _person.id,
      passcodeHash: ns,
      keys: keys,
    );
    final relationships = await store.relationshipsFor(
      _person.id,
      passcodeHash: ns,
      keys: keys,
    );
    final allPeople = await store.listAll();
    final locations = await store.locationsFor(
      _person.id,
      passcodeHash: ns,
      keys: keys,
    );
    final education = await store.historyFor(
      _person.id,
      HistoryCategory.education,
      passcodeHash: ns,
      keys: keys,
    );
    final jobs = await store.historyFor(
      _person.id,
      HistoryCategory.job,
      passcodeHash: ns,
      keys: keys,
    );
    final events = await store.eventsFor(
      _person.id,
      passcodeHash: ns,
      keys: keys,
    );
    final groups = await store.groupsFor(
      _person.id,
      passcodeHash: ns,
      keys: keys,
    );
    final allGroups = await store.allGroups(passcodeHash: ns, keys: keys);
    final ownerId = await _owner.id();
    final shared = await store.sharedPhotoCounts(_person.id);
    // Switched meanwhile: these are the other set's.
    if (!mounted || !identical(scope, _scope)) return;
    setState(() {
      _detail = detail;
      _allPeople = allPeople;
      _namesById = {for (final p in allPeople) p.id: p.name};
      _peopleById = {for (final p in allPeople) p.id: p};
      _sharedPhotos = shared;
      _locations = locations;
      _education = education;
      _jobs = jobs;
      _events = events;
      _groups = groups;
      _allGroups = allGroups;
      _ownerId = ownerId;
      // Shown beside the explicit ones rather than written down — see
      // [groupRelationships].
      _relationships = [
        ...relationships,
        ...groupRelationships(
          personId: _person.id,
          members: allGroups,
          explicit: relationships,
        ),
      ];
      _explicit = relationships;
      if (_bio.text != detail.bio) _bio.text = detail.bio;
      if (_hint.text != detail.hint) _hint.text = detail.hint;
    });
  }

  Future<void> _persistDetail(PersonDetail updated) async {
    if (_loading) return;
    setState(() => _detail = updated);
    await widget.personStore.saveDetail(_person.id, updated, scope: _scope);
  }

  Future<void> _persist(Person updated) async {
    setState(() => _person = updated);
    await widget.personStore.update(updated);
  }

  /// A face of theirs, or one of their photos cropped to their face where
  /// it's known; never the old box on a new picture, which would frame
  /// somebody's elbow.
  Future<void> _pickAvatar() async {
    final chosen = await Navigator.of(context)
        .push<({String localId, FaceRect? face})>(
          CupertinoPageRoute(
            builder: (_) => PersonAvatarPicker(
              person: _person,
              personStore: widget.personStore,
              assetRecordStore: widget.assetRecordStore,
            ),
          ),
        );
    if (chosen == null || !mounted) return;
    await _persist(
      _person.copyWith(
        avatarLocalId: chosen.localId,
        avatarFace: () => chosen.face,
      ),
    );
  }

  /// "+": pick (or type) a title first — school/employer name is never
  /// blank — then open the detail page for dates/notes/custom fields.
  Future<void> _addHistoryEntry(
    HistoryCategory category,
    String categoryLabel,
  ) async {
    final options = await widget.personStore.allHistoryTitles(
      category,
      passcodeHash: _namespace,
      keys: _keys,
    );
    if (!mounted) return;
    final title = await showSearchPickerSheet(
      context: context,
      title: categoryLabel,
      options: options,
    );
    if (title == null || title.isEmpty) return;
    final entry = PersonHistoryEntry(
      id: widget.personStore.newId(),
      personId: _person.id,
      category: category,
      title: title,
    );
    final scope = _scope;
    await widget.personStore.addHistoryEntry(entry, scope: scope);
    if (!mounted) return;
    await Navigator.of(context).push(
      CupertinoPageRoute(
        builder: (_) => PersonHistoryDetailScreen(
          entry: entry,
          categoryLabel: categoryLabel,
          personStore: widget.personStore,
          scope: scope,
        ),
      ),
    );
    await _reload();
  }

  Future<void> _openHistoryEntry(
    PersonHistoryEntry entry,
    String categoryLabel,
  ) async {
    await Navigator.of(context).push(
      CupertinoPageRoute(
        builder: (_) => PersonHistoryDetailScreen(
          entry: entry,
          categoryLabel: categoryLabel,
          personStore: widget.personStore,
          scope: _scope,
        ),
      ),
    );
    await _reload();
  }

  /// Switches which set of details is on screen.
  ///
  /// In the open set, this asks for four digits and shows whatever is kept
  /// under them — which for digits nobody has used is nothing at all, and
  /// looks the same. There is no wrong passcode to report, and deliberately
  /// no way to find out whether a set exists without opening it.
  ///
  /// Already inside a set, it goes back to the open one. No confirmation:
  /// nothing is being destroyed, and the way back is four digits.
  Future<void> _switchNamespace() async {
    if (_loading) return;
    if (_namespace != openNamespace) {
      await _enter(PersonScope.open);
      return;
    }

    // The key comes from the passphrase, which is the app's, not this
    // screen's. Nothing has asked for one yet on a phone that has never
    // used a private album, so this is where it gets asked.
    if ((await _vaultKeys.entries()).isEmpty) {
      if (!mounted) return;
      if (await showVaultSetupSheet(context, keys: _vaultKeys) == null) return;
    }
    if (!mounted) return;
    final passcode = await showPrivateAlbumPasscodeSheet(context);
    if (passcode == null) return;

    final tag = await PasscodeTags(
      records: widget.assetRecordStore,
      people: widget.personStore,
      vaultKeys: _vaultKeys,
    ).tagFor(passcode);
    var keys = await _vaultKeys.unlockAlbum(passcode, tag);
    if (keys == null) {
      // The passphrase is known *of* but cannot be derived on this phone —
      // which is exactly what Remove All App Data leaves behind, since it
      // drops the master keys and keeps the entries. Without this the keypad
      // took four digits and did nothing at all, silently, which is
      // indistinguishable from a feature that does not work.
      final known = await _vaultKeys.entries();
      if (known.isEmpty || !mounted) return;
      final unlocked = await showAddPassphraseSheet(
        context,
        keys: _vaultKeys,
        candidates: known,
      );
      if (!unlocked || !mounted) return;
      keys = await _vaultKeys.unlockAlbum(passcode, tag);
    }
    if (keys == null || !mounted) return;
    await _enter(PersonScope.sealed(tag, keys));
  }

  /// Shows [scope]'s set. The old one's details leave the screen first, so
  /// a keystroke during the load can't carry them into the new set.
  Future<void> _enter(PersonScope scope) async {
    setState(() {
      _scope = scope;
      _loading = true;
      _detail = PersonDetail.empty;
      _relationships = const [];
      _explicit = const [];
      _locations = const [];
      _education = const [];
      _jobs = const [];
      _events = const [];
      _groups = const [];
      _allGroups = const {};
      _bio.text = '';
      _hint.text = '';
    });
    try {
      await _reload();
    } finally {
      if (mounted && identical(scope, _scope)) {
        setState(() => _loading = false);
      }
    }
  }

  String _relationshipLabel(AppLocalizations l10n, RelationshipType type) =>
      relationshipTypeLabel(l10n, type);

  /// Label for the organization prompt — "Company" for colleague, "School"
  /// for schoolmate, generic "Organization" for other (church/club/...).
  String _organizationLabel(AppLocalizations l10n, RelationshipType type) =>
      switch (type) {
        RelationshipType.colleague => l10n.relationshipOrganizationCompanyLabel,
        RelationshipType.schoolmate => l10n.relationshipOrganizationSchoolLabel,
        _ => l10n.relationshipOrganizationOtherLabel,
      };

  Future<RelationshipType?> _pickRelationshipType() {
    final l10n = AppLocalizations.of(context)!;
    return showCupertinoModalPopup<RelationshipType>(
      context: context,
      builder: (context) => CupertinoActionSheet(
        title: Text(l10n.relationshipPickerTitle),
        actions: [
          for (final type in RelationshipType.values)
            CupertinoActionSheetAction(
              onPressed: () => Navigator.of(context).pop(type),
              child: Text(_relationshipLabel(l10n, type)),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.actionCancel),
        ),
      ),
    );
  }

  /// Shared by "+" (new relationship) and tapping an existing row (full
  /// re-pick of person + type + organization) — [existing] is removed
  /// first if the target person changed, so editing never leaves a stale
  /// link behind.
  Future<void> _addOrEditRelationship({PersonRelationship? existing}) async {
    final l10n = AppLocalizations.of(context)!;
    final linkedIds = _relationships
        .map((r) => r.relatedPersonId)
        .where((id) => id != existing?.relatedPersonId)
        .toSet();
    final candidates = _allPeople
        .where((p) => p.id != _person.id && !linkedIds.contains(p.id))
        .toList();
    final other = await showPersonPickerSheet(
      context: context,
      candidates: candidates,
      personStore: widget.personStore,
      ownerId: _ownerId,
    );
    if (other == null || !mounted) return;

    final type = await _pickRelationshipType();
    if (type == null) return;

    String? organization;
    if (relationshipNeedsOrganization(type)) {
      final orgOptions = await widget.personStore.allOrganizations(
        passcodeHash: _namespace,
        keys: _keys,
      );
      if (!mounted) return;
      organization = await showSearchPickerSheet(
        context: context,
        title: _organizationLabel(l10n, type),
        options: orgOptions,
        selected: existing?.organization,
      );
      if (organization == null) return;
    }

    if (existing != null && existing.relatedPersonId != other.id) {
      await widget.personStore.removeRelationship(
        _person.id,
        existing.relatedPersonId,
        scope: _scope,
      );
    }
    await widget.personStore.addRelationship(
      _person.id,
      other.id,
      type,
      organization: organization,
      scope: _scope,
    );
    await _reload();
  }

  /// Gone at once, with Undo — no dialog in the way of tidying a long list.
  Future<void> _removeRelationship(PersonRelationship r) async {
    final l10n = AppLocalizations.of(context)!;
    final scope = _scope;
    setState(() {
      _explicit = [
        for (final x in _explicit)
          if (x.relatedPersonId != r.relatedPersonId) x,
      ];
    });
    await widget.personStore.removeRelationship(
      _person.id,
      r.relatedPersonId,
      scope: scope,
    );
    if (!mounted) return;
    _undo.show(
      context,
      l10n.profileRemoved(_namesById[r.relatedPersonId] ?? '?'),
      () async {
        await widget.personStore.addRelationship(
          _person.id,
          r.relatedPersonId,
          r.type,
          organization: r.organization,
          scope: scope,
        );
        if (mounted) await _reload();
      },
    );
    await _reload();
  }

  /// Tapping a relationship row's name opens *that* person's page — editing
  /// the link itself (who/type/organization) is the separate pencil button.
  Future<void> _openRelatedPerson(PersonRelationship relationship) async {
    final other = _peopleById[relationship.relatedPersonId];
    if (other == null) return;
    await Navigator.of(context).push(
      CupertinoPageRoute(
        builder: (_) => PersonPageScreen(
          person: other,
          personStore: widget.personStore,
          assetRecordStore: widget.assetRecordStore,
        ),
      ),
    );
    await _reload();
  }

  /// Shared by "+" (adding a new entry) and tapping an existing row (editing
  /// it in place) — `existing` pre-fills the sheet and, on save, reuses its
  /// `id` so `PersonStore.addLocation`'s insert-or-replace updates it.
  Future<void> _editLocation({PersonLocation? existing}) async {
    final l10n = AppLocalizations.of(context)!;
    final placeController = TextEditingController(text: existing?.place ?? '');
    var kind = existing?.kind ?? LocationKind.origin;
    var since = existing?.since ?? DateTime.now();
    final saved = await showCupertinoModalPopup<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => CupertinoActionSheet(
          title: Text(
            existing == null ? l10n.locationAddTitle : l10n.locationEditTitle,
          ),
          message: Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Column(
              children: [
                CupertinoTextField(
                  controller: placeController,
                  placeholder: l10n.locationPlaceLabel,
                ),
                const SizedBox(height: 12),
                CupertinoSlidingSegmentedControl<LocationKind>(
                  groupValue: kind,
                  children: {
                    LocationKind.origin: Text(l10n.personProfileLocationOrigin),
                    LocationKind.relocation: Text(
                      l10n.personProfileLocationRelocation,
                    ),
                  },
                  onValueChanged: (value) =>
                      setState(() => kind = value ?? kind),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  height: 120,
                  child: CupertinoDatePicker(
                    mode: CupertinoDatePickerMode.date,
                    initialDateTime: since,
                    maximumDate: DateTime.now(),
                    minimumYear: 1900,
                    onDateTimeChanged: (value) => since = value,
                  ),
                ),
              ],
            ),
          ),
          actions: [
            CupertinoActionSheetAction(
              onPressed: () =>
                  Navigator.of(context)
                      .pop(placeController.text.trim().isNotEmpty),
              child: Text(
                existing == null ? l10n.actionAdd : l10n.settingsSaveButton,
              ),
            ),
          ],
          cancelButton: CupertinoActionSheetAction(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.actionCancel),
          ),
        ),
      ),
    );
    if (saved != true) return;
    await widget.personStore.addLocation(
      PersonLocation(
        id: existing?.id ?? widget.personStore.newId(),
        personId: _person.id,
        kind: kind,
        place: placeController.text.trim(),
        since: since,
      ),
      scope: _scope,
    );
    await _reload();
  }

  Future<void> _removeLocation(PersonLocation location) async {
    final l10n = AppLocalizations.of(context)!;
    final scope = _scope;
    setState(() {
      _locations = [
        for (final l in _locations)
          if (l.id != location.id) l,
      ];
    });
    await widget.personStore.removeLocation(location.id, scope: scope);
    if (!mounted) return;
    _undo.show(context, l10n.profileRemoved(location.place), () async {
      await widget.personStore.addLocation(location, scope: scope);
      if (mounted) await _reload();
    });
    await _reload();
  }

  Future<void> _editBirthDate() async {
    final l10n = AppLocalizations.of(context)!;
    final current = _detail.birthDate;
    var picked = current ?? DateTime(DateTime.now().year - 30);
    final saved = await showCupertinoModalPopup<bool>(
      context: context,
      builder: (context) => CupertinoActionSheet(
        title: Text(l10n.personProfileBirthDateTitle),
        message: SizedBox(
          height: 160,
          child: CupertinoDatePicker(
            mode: CupertinoDatePickerMode.date,
            initialDateTime: picked,
            maximumDate: DateTime.now(),
            minimumYear: 1900,
            onDateTimeChanged: (value) => picked = value,
          ),
        ),
        actions: [
          CupertinoActionSheetAction(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.settingsSaveButton),
          ),
          if (current != null)
            CupertinoActionSheetAction(
              isDestructiveAction: true,
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(l10n.actionClear),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.actionCancel),
        ),
      ),
    );
    if (saved == null) return;
    await _persistDetail(
      _detail.copyWith(birthDate: () => saved ? picked : null),
    );
  }

  Future<void> _pickGender() async {
    final l10n = AppLocalizations.of(context)!;
    // A Gender, or false for Clear.
    final selected = await showCupertinoModalPopup<Object>(
      context: context,
      builder: (context) => CupertinoActionSheet(
        title: Text(l10n.personProfileGenderLabel),
        actions: [
          CupertinoActionSheetAction(
            onPressed: () => Navigator.of(context).pop(Gender.male),
            child: Text(l10n.genderMale),
          ),
          CupertinoActionSheetAction(
            onPressed: () => Navigator.of(context).pop(Gender.female),
            child: Text(l10n.genderFemale),
          ),
          if (_detail.gender != null)
            CupertinoActionSheetAction(
              isDestructiveAction: true,
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(l10n.actionClear),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.actionCancel),
        ),
      ),
    );
    if (selected == null) return;
    await _persistDetail(
      _detail.copyWith(gender: () => selected is Gender ? selected : null),
    );
  }

  /// Plain text, no box — "30 years old · Male", each part its own tap
  /// target (age opens the birth date picker, gender opens a picker sheet).
  /// A reminder of *which* set this is, shown only from inside it.
  ///
  /// Outside, it would be proof that the set exists, which is the whole
  /// thing the keypad avoids saying. In here it is the opposite of a
  /// secret: somebody who keeps three sets needs to know which one they
  /// have opened.
  Widget _hintRow(AppLocalizations l10n) => Container(
    margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    decoration: BoxDecoration(
      // Tinted, because the alternative was a filled icon in the nav bar and
      // a placeholder — and on a profile that was empty to begin with, an
      // empty set looks exactly like the one you came from. Something has to
      // say plainly which set you are in.
      color: CupertinoColors.systemBlue.withValues(alpha: 0.18),
      borderRadius: BorderRadius.circular(10),
    ),
    child: Row(
      children: [
        const Icon(
          CupertinoIcons.number,
          size: 15,
          color: CupertinoColors.systemBlue,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: CupertinoTextField.borderless(
            controller: _hint,
            readOnly: _loading,
            placeholder: l10n.personProfileHintLabel,
            placeholderStyle: const TextStyle(
              fontSize: 13,
              color: CupertinoColors.systemGrey,
            ),
            style: const TextStyle(fontSize: 13, color: CupertinoColors.white),
            onChanged: (v) => _persistDetail(_detail.copyWith(hint: v)),
          ),
        ),
      ],
    ),
  );

  Widget _ageGenderRow(AppLocalizations l10n) {
    final age = ageFrom(_detail.birthDate);
    final genderText = switch (_detail.gender) {
      Gender.male => l10n.genderMale,
      Gender.female => l10n.genderFemale,
      null => l10n.personProfileGenderLabel,
    };
    const style = TextStyle(fontSize: 14, color: CupertinoColors.systemGrey);
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        GestureDetector(
          onTap: _editBirthDate,
          child: Text(
            age == null
                ? l10n.personProfileAgeLabel
                : l10n.personProfileAgeValue(age),
            style: style,
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 8),
          child: Text('·', style: style),
        ),
        GestureDetector(
          onTap: _pickGender,
          child: Text(genderText, style: style),
        ),
      ],
    );
  }

  List<PersonLocation> get _sortedLocations =>
      [..._locations]..sort((a, b) => a.since.compareTo(b.since));

  /// "{startYear} – {endYear|Present}" — the end year is when the *next*
  /// location starts (i.e. when they moved away), or "Present" for the most
  /// recent one. No Origin/Relocation label; that's implied by the order.
  String _locationRangeLabel(AppLocalizations l10n, int index) {
    final sorted = _sortedLocations;
    final start = DateFormat.y().format(sorted[index].since);
    final end = index + 1 < sorted.length
        ? DateFormat.y().format(sorted[index + 1].since)
        : l10n.personHistoryPresentLabel;
    return '$start – $end';
  }

  Future<void> _confirmDeletePerson() async {
    final l10n = AppLocalizations.of(context)!;
    // Their folder's code is `person:<id>:<digits>`, and the id goes with
    // them: deleting now would strand those photos for good.
    if (await personHasHiddenFolder(
      widget.assetRecordStore,
      _person.id,
      aliases: await widget.personStore.aliasesOf(_person.id),
    )) {
      if (!mounted) return;
      await showCupertinoDialog<void>(
        context: context,
        builder: (context) => CupertinoAlertDialog(
          title: Text(l10n.personProfileDeleteBlockedTitle),
          content: Text(l10n.personProfileDeleteBlockedBody),
          actions: [
            CupertinoDialogAction(
              isDefaultAction: true,
              onPressed: () => Navigator.of(context).pop(),
              child: Text(l10n.actionOk),
            ),
          ],
        ),
      );
      return;
    }
    if (!mounted) return;
    final confirmed = await showCupertinoDialog<bool>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: Text(l10n.personProfileDeleteConfirmTitle),
        content: Text(l10n.personProfileDeleteConfirmBody),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.actionCancel),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.actionDelete),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await widget.personStore.remove(_person.id);
    await forgetPersonFaces(_person.id);
    if (!mounted) return;
    // Just this screen. The person page beneath re-reads the person when
    // this one returns and pops itself when it's gone — popping it from
    // here too raced that, and two screens each popping one route took the
    // People list down with them, leaving an empty navigator.
    Navigator.of(context).pop();
  }

  bool _folded(String id) => profileFolded.contains(id);

  void _toggleFold(String id) => setState(() {
    if (!profileFolded.remove(id)) profileFolded.add(id);
  });

  void _toggleEdit(String id) => setState(() {
    if (!_editing.remove(id)) _editing.add(id);
  });

  /// Scrolls [id]'s section to just under the pinned jump bar.
  void _jump(String id) {
    final box = _anchors[id]?.currentContext?.findRenderObject();
    if (box == null || !_scroll.hasClients) return;
    final viewport = RenderAbstractViewport.maybeOf(box);
    if (viewport == null) return;
    final position = _scroll.position;
    final target =
        viewport.getOffsetToReveal(box, 0).offset - ProfileJumpBar.height;
    _scroll.animateTo(
      target.clamp(position.minScrollExtent, position.maxScrollExtent),
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
  }

  /// A section as slivers: the header and its body; folded, the header
  /// alone; [empty], one "Add" row in place of both.
  List<Widget> _section({
    required String id,
    required String title,
    required Widget Function() body,
    String? anchor,
    int? count,
    bool empty = false,
    String? emptyHint,
    VoidCallback? onAdd,
    bool editable = false,
    bool sliverBody = false,
  }) {
    Widget anchored(Widget child) => anchor == null
        ? child
        : KeyedSubtree(key: _anchors[anchor], child: child);
    if (empty && emptyHint != null) {
      return [
        SliverToBoxAdapter(
          child: anchored(
            ProfileEmptyRow(title: title, hint: emptyHint, onTap: onAdd),
          ),
        ),
      ];
    }
    final folded = _folded(id);
    return [
      SliverToBoxAdapter(
        child: anchored(
          ProfileSectionHeader(
            title: title,
            count: count,
            folded: folded,
            onToggle: () => _toggleFold(id),
            onAdd: onAdd,
            editing: _editing.contains(id),
            onEdit: editable ? () => _toggleEdit(id) : null,
          ),
        ),
      ),
      if (!folded) sliverBody ? body() : SliverToBoxAdapter(child: body()),
    ];
  }

  /// Latest of the date set by hand, any other event, their newest photo
  /// and newest chat — and which of them it is.
  (DateTime, String?)? _lastSeen(AppLocalizations l10n, DateTime? set) {
    DateTime? event;
    for (final e in _events) {
      if (e.isFixed || e.at == null || e.at!.isAfter(DateTime.now())) {
        continue;
      }
      if (event == null || e.at!.isAfter(event)) event = e.at;
    }
    final candidates = [
      if (set != null) (set, null),
      if (event != null) (event, l10n.eventsSeenFromEvent),
      if (_photoSeen case final at?) (at, l10n.eventsSeenFromPhoto),
      if (_chatSeen case final at?) (at, l10n.eventsSeenFromChat),
    ];
    final now = DateTime.now();
    candidates.removeWhere((c) => c.$1.isAfter(now));
    if (candidates.isEmpty) return null;
    return candidates.reduce((a, b) => b.$1.isAfter(a.$1) ? b : a);
  }

  Widget _summary(AppLocalizations l10n) {
    final firstMet = _events.where((e) => e.isFirstMet).firstOrNull?.at;
    final lastSeen = _lastSeen(
      l10n,
      _events.where((e) => e.isLastSeen).firstOrNull?.at,
    );
    final people = {for (final r in _relationships) r.relatedPersonId}.length;
    return ProfileSummaryCard(
      facts: profileFacts(
        l10n,
        detail: _detail,
        jobs: _jobs,
        locations: _locations,
        withAge: false,
      ),
      since: [
        if (firstMet != null) l10n.profileKnownSince(firstMet.year),
        if (lastSeen != null)
          l10n.profileLastContact(DateFormat.yMMMd().format(lastSeen.$1)),
      ],
      counts: [
        if (_photoCount > 0)
          ProfileCount(
            const ValueKey('profileCountPhotos'),
            CupertinoIcons.photo_on_rectangle,
            l10n.profileCountPhotos(_photoCount),
            widget.onOpenPhotos ?? _openPhotos,
          ),
        if (_conversations > 0)
          ProfileCount(
            const ValueKey('profileCountChats'),
            CupertinoIcons.chat_bubble_2,
            l10n.profileCountMessages(_conversations),
            () => _jump('chats'),
          ),
        if (_wordTotal > 0)
          ProfileCount(
            const ValueKey('profileCountWords'),
            CupertinoIcons.doc_text,
            l10n.profileCountWritings(_wordTotal),
            () => _jump('words'),
          ),
        if (people > 0)
          ProfileCount(
            const ValueKey('profileCountPeople'),
            CupertinoIcons.person_2,
            l10n.profileCountPeople(people),
            () => _jump('people'),
          ),
      ],
    );
  }

  Future<void> _openPhotos() => Navigator.of(context).push(
    CupertinoPageRoute<void>(
      builder: (_) => PersonPageScreen(
        person: _person,
        personStore: widget.personStore,
        assetRecordStore: widget.assetRecordStore,
      ),
    ),
  );

  Widget _identity(AppLocalizations l10n) => Column(
    children: [
      Center(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _pickAvatar,
          child: Stack(
            alignment: Alignment.bottomRight,
            children: [
              Hero(
                tag: personAvatarHeroTag(_person.id),
                child: PersonAvatar(
                  assetRecordStore: widget.assetRecordStore,
                  localId: _person.avatarLocalId,
                  face: _person.avatarFace,
                  size: 96,
                ),
              ),
              // Without this the circle is just a picture; people
              // don't try tapping pictures.
              Container(
                width: 28,
                height: 28,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: CupertinoColors.activeBlue,
                ),
                child: const Icon(
                  CupertinoIcons.camera_fill,
                  size: 14,
                  color: CupertinoColors.white,
                ),
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 12),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: CupertinoTextField.borderless(
          controller: _name,
          autofocus: widget.autofocusName,
          textAlign: TextAlign.center,
          placeholder: l10n.personProfileNameLabel,
          style: const TextStyle(
            fontSize: 26,
            fontWeight: FontWeight.bold,
            color: CupertinoColors.white,
          ),
          // A blank name is never written: the person keeps the last
          // one, rather than an empty row in People.
          onChanged: (v) {
            if (v.trim().isNotEmpty) _persist(_person.copyWith(name: v));
            // The parts' suggestions follow the name.
            setState(() {});
          },
        ),
      ),
      if (_alsoKnownAs case final names when names.isNotEmpty)
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          // Remembered ones can be forgotten there; former names can't.
          onTap: _knownAs.isEmpty ? null : _openKnownAs,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 2, 24, 0),
            child: Text(
              l10n.personAlsoKnownAs(names.join(', ')),
              key: const ValueKey('personAlsoKnownAs'),
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 13,
                color: CupertinoColors.systemGrey,
              ),
            ),
          ),
        ),
      const SizedBox(height: 8),
      if (_namespace != openNamespace) _hintRow(l10n),
      ?_ownerRelationLine(l10n),
      _ageGenderRow(l10n),
    ],
  );

  Widget _bioField(AppLocalizations l10n) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16),
    child: Container(
      padding: const EdgeInsets.all(12),
      decoration: profileCardDecoration,
      child: CupertinoTextField.borderless(
        controller: _bio,
        readOnly: _loading,
        maxLines: null,
        padding: EdgeInsets.zero,
        onTapOutside: (_) => FocusManager.instance.primaryFocus?.unfocus(),
        placeholder: l10n.personProfileBioEmpty,
        style: const TextStyle(fontSize: 15, color: CupertinoColors.white),
        onChanged: (v) => _persistDetail(_detail.copyWith(bio: v)),
      ),
    ),
  );

  Widget _placesSection(AppLocalizations l10n) {
    final sorted = _sortedLocations;
    return ProfileCard(
      children: [
        for (var i = 0; i < sorted.length; i++)
          ProfileDeletableRow(
            key: ValueKey('place:${sorted[i].id}'),
            editing: _editing.contains('places'),
            onDelete: () => _removeLocation(sorted[i]),
            child: CupertinoListTile(
              title: Text(sorted[i].place),
              additionalInfo: Text(_locationRangeLabel(l10n, i)),
              onTap: () => _editLocation(existing: sorted[i]),
            ),
          ),
      ],
    );
  }

  Widget _linkRow(String text, VoidCallback onTap, {Key? key}) =>
      CupertinoListTile(
        key: key,
        title: Text(text),
        trailing: const Icon(
          CupertinoIcons.chevron_forward,
          size: 18,
          color: CupertinoColors.systemGrey2,
        ),
        onTap: onTap,
      );

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final people = _explicit;
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(l10n.personProfileTitle),
        trailing: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: _switchNamespace,
          // A keypad, not a padlock. A padlock says something is locked,
          // which is the one thing this must not answer.
          child: Icon(
            _namespace == openNamespace
                ? CupertinoIcons.number
                : CupertinoIcons.number_circle_fill,
          ),
        ),
      ),
      child: SafeArea(
        child: CustomScrollView(
          controller: _scroll,
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.only(top: 16),
                child: _identity(l10n),
              ),
            ),
            SliverToBoxAdapter(child: _summary(l10n)),
            SliverPersistentHeader(
              pinned: true,
              delegate: ProfileJumpBar([
                ('about', l10n.profileJumpAbout),
                ('chats', l10n.profileJumpChats),
                ('people', l10n.profileJumpPeople),
                ('work', l10n.profileJumpWork),
                ('life', l10n.profileJumpLife),
              ], _jump),
            ),
            ..._section(
              id: 'about',
              anchor: 'about',
              title: l10n.profileAboutHeader,
              body: () => _bioField(l10n),
            ),
            ..._section(
              id: 'chats',
              anchor: 'chats',
              title: l10n.profileChatsHeader,
              empty: _conversations == 0,
              emptyHint: l10n.profileChatsPrompt,
              body: () => ChatsPreview(data: _chats, onOpen: _openChats),
            ),
            ..._section(
              id: 'words',
              anchor: 'words',
              title: l10n.wordsHeader,
              count: _wordTotal,
              empty: _wordCounts.isEmpty,
              emptyHint: l10n.wordsPrompt,
              body: _wordsSection,
            ),
            ..._section(
              id: 'relationships',
              anchor: 'people',
              title: l10n.personProfileRelationshipsHeader,
              count: people.length,
              empty: people.isEmpty,
              emptyHint: l10n.profileRelationshipsPrompt,
              onAdd: () => _addOrEditRelationship(),
              editable: true,
              sliverBody: true,
              body: () => ProfileRelationships(
                relationships: people,
                people: _peopleById,
                sharedPhotos: _sharedPhotos,
                assetRecordStore: widget.assetRecordStore,
                editing: _editing.contains('relationships'),
                typeLabel: (t) => _relationshipLabel(l10n, t),
                onOpen: _openRelatedPerson,
                onEdit: (r) => _addOrEditRelationship(existing: r),
                onDelete: _removeRelationship,
              ),
            ),
            ..._section(
              id: 'groups',
              title: l10n.groupsHeader,
              count: _groups.length,
              empty: _groups.isEmpty,
              emptyHint: l10n.groupsPromptHint,
              onAdd: _addToGroup,
              editable: true,
              body: () => _groupsSection(l10n),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.only(top: 8),
                child: ProfileCard(
                  children: [
                    _linkRow(
                      l10n.personProfileViewGraph,
                      () => Navigator.of(context).push(
                        CupertinoPageRoute(
                          builder: (_) => PersonGraphScreen(
                            personStore: widget.personStore,
                            assetRecordStore: widget.assetRecordStore,
                            focusPersonId: _person.id,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            ..._section(
              id: 'job',
              anchor: 'work',
              title: l10n.personProfileJobLabel,
              count: _jobs.length,
              empty: _jobs.isEmpty,
              emptyHint: l10n.personProfileJobPromptHint,
              onAdd: () => _addHistoryEntry(
                HistoryCategory.job,
                l10n.personProfileJobLabel,
              ),
              body: () => HistoryTimeline(
                entries: _jobs,
                onOpen: (e) => _openHistoryEntry(e, l10n.personProfileJobLabel),
              ),
            ),
            ..._section(
              id: 'education',
              title: l10n.personProfileEducationLabel,
              count: _education.length,
              empty: _education.isEmpty,
              emptyHint: l10n.personProfileEducationPromptHint,
              onAdd: () => _addHistoryEntry(
                HistoryCategory.education,
                l10n.personProfileEducationLabel,
              ),
              body: () => HistoryTimeline(
                entries: _education,
                onOpen: (e) =>
                    _openHistoryEntry(e, l10n.personProfileEducationLabel),
              ),
            ),
            ..._section(
              id: 'places',
              anchor: 'life',
              title: l10n.personProfileLocationHeader,
              count: _locations.length,
              empty: _locations.isEmpty,
              emptyHint: l10n.personProfileLocationPromptHint,
              onAdd: () => _editLocation(),
              editable: true,
              body: () => _placesSection(l10n),
            ),
            ..._section(
              id: 'events',
              title: l10n.eventsHeader,
              onAdd: () => _editEvent(),
              editable: _events.any((e) => !e.isFixed),
              body: () => _eventsSection(l10n),
            ),
            ..._section(
              id: 'impression',
              title: l10n.impressionHeader,
              body: () => ProfileImpression(
                impression: _detail.impression,
                onChanged: (i) =>
                    _persistDetail(_detail.copyWith(impression: i)),
              ),
            ),
            ..._moreDetails(l10n),
            ..._section(
              id: 'names',
              title: l10n.profileNamePartsHeader,
              body: () => _nameParts(l10n),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
                child: ProfileCard(
                  children: [
                    _linkRow(
                      l10n.timelineTitle,
                      () => Navigator.of(context).push(
                        CupertinoPageRoute<void>(
                          builder: (_) => PersonTimelineScreen(
                            person: _person,
                            personStore: widget.personStore,
                            assetRecordStore: widget.assetRecordStore,
                            conversationStore: _conversationStore,
                          ),
                        ),
                      ),
                      key: const ValueKey('personTimelineRow'),
                    ),
                    _linkRow(l10n.personChangesRow, () async {
                      await Navigator.of(context).push(
                        CupertinoPageRoute(
                          builder: (_) => PersonChangeLogScreen(
                            person: _person,
                            personStore: widget.personStore,
                          ),
                        ),
                      );
                      await _loadFormerNames();
                    }, key: const ValueKey('personChangesRow')),
                  ],
                ),
              ),
            ),
            ..._section(
              id: 'utilities',
              title: l10n.utilitiesHeader,
              body: () => _utilitiesSection(l10n),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.only(top: 24, bottom: 32),
                child: Center(
                  child: CupertinoButton(
                    onPressed: _confirmDeletePerson,
                    child: Text(
                      l10n.personProfileDeletePerson,
                      style: const TextStyle(color: CupertinoColors.systemRed),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The named traits and the free label/value pairs, under one header
  /// whose "+" suggests the usual labels.
  List<Widget> _moreDetails(AppLocalizations l10n) {
    const id = 'details';
    final folded = _folded(id);
    return [
      SliverToBoxAdapter(
        child: ProfileSectionHeader(
          title: l10n.customFieldsHeader,
          count: _detail.customFields.length,
          folded: folded,
          onToggle: () => _toggleFold(id),
          addKey: customFieldsAddKey,
          onAdd: () {
            if (folded) _toggleFold(id);
            WidgetsBinding.instance.addPostFrameCallback(
              (_) => _fieldsKey.currentState?.add(),
            );
          },
          editing: _editing.contains(id),
          onEdit: _detail.customFields.isEmpty ? null : () => _toggleEdit(id),
        ),
      ),
      if (!folded)
        SliverToBoxAdapter(
          child: CustomFieldsEditor(
            key: _fieldsKey,
            showHeader: false,
            editing: _editing.contains(id),
            suggestions: suggestedFieldLabels(l10n),
            initialFields: _detail.customFields,
            onChanged: (fields) =>
                _persistDetail(_detail.copyWith(customFields: fields)),
            underHeader: PersonTraitsEditor(
              traits: _detail.traits,
              background: profileCardBackground,
              decoration: profileCardDecoration,
              onChanged: (traits) =>
                  _persistDetail(_detail.copyWith(traits: traits)),
            ),
          ),
        ),
    ];
  }

  /// What happened, oldest first.
  ///
  /// "First met / knew at" is always the first row and cannot be removed.
  /// It is not written to the database until a date is put on it, so an
  /// empty one reads as a prompt rather than as something the app decided.
  Widget _eventsSection(AppLocalizations l10n) {
    final firstMet = _events.where((e) => e.isFirstMet).firstOrNull;
    final lastSeen = _events.where((e) => e.isLastSeen).firstOrNull;
    final rest = [
      for (final e in _events)
        if (!e.isFixed) e,
    ];
    return CupertinoListSection.insetGrouped(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      backgroundColor: profileCardBackground,
      decoration: profileCardDecoration,
      children: [
        CupertinoListTile(
          title: Text(l10n.eventsFirstMet),
          subtitle: Text(
            firstMet?.at == null
                ? l10n.eventsNotSet
                : _eventDate(firstMet!.at!),
          ),
          trailing: const Icon(
            CupertinoIcons.chevron_right,
            size: 16,
            color: CupertinoColors.systemGrey,
          ),
          onTap: () => _editEvent(
            existing:
                firstMet ??
                PersonEvent(
                  id: widget.personStore.newId(),
                  personId: _person.id,
                  type: PersonEventType.firstMet,
                ),
          ),
        ),
        CupertinoListTile(
          key: const ValueKey('profileLastSeen'),
          title: Text(l10n.eventsLastSeen),
          subtitle: Text(_seenText(l10n, lastSeen?.at)),
          trailing: const Icon(
            CupertinoIcons.chevron_right,
            size: 16,
            color: CupertinoColors.systemGrey,
          ),
          onTap: () => _editEvent(
            existing:
                lastSeen ??
                PersonEvent(
                  id: widget.personStore.newId(),
                  personId: _person.id,
                  type: PersonEventType.lastSeen,
                ),
          ),
        ),
        for (final event in rest)
          ProfileDeletableRow(
            key: ValueKey('event:${event.id}'),
            editing: _editing.contains('events'),
            onDelete: () => _removeEvent(l10n, event),
            child: CupertinoListTile(
              title: Text(eventTypeLabel(l10n, event.type)),
              subtitle: Text(
                [
                  if (event.at != null) _eventDate(event.at!),
                  if (event.tags.isNotEmpty) event.tags.join(', '),
                  if (event.notes.isNotEmpty) event.notes,
                ].join(' · '),
              ),
              trailing: const Icon(
                CupertinoIcons.chevron_right,
                size: 16,
                color: CupertinoColors.systemGrey,
              ),
              onTap: () => _editEvent(existing: event),
            ),
          ),
      ],
    );
  }

  static String _eventDate(DateTime at) => DateFormat.yMMMd().format(at);

  String _seenText(AppLocalizations l10n, DateTime? set) {
    final seen = _lastSeen(l10n, set);
    if (seen == null) return l10n.eventsNotSet;
    final (at, from) = seen;
    return from == null ? _eventDate(at) : '${_eventDate(at)} · $from';
  }

  Future<void> _removeEvent(AppLocalizations l10n, PersonEvent event) async {
    final scope = _scope;
    setState(() {
      _events = [
        for (final e in _events)
          if (e.id != event.id) e,
      ];
    });
    await widget.personStore.removeEvent(event.id, scope: scope);
    if (!mounted) return;
    _undo.show(
      context,
      l10n.profileRemoved(eventTypeLabel(l10n, event.type)),
      () async {
        await widget.personStore.saveEvent(event, scope: scope);
        if (mounted) await _reload();
      },
    );
    await _reload();
  }

  Future<void> _editEvent({PersonEvent? existing}) async {
    final draft =
        existing ??
        PersonEvent(
          id: widget.personStore.newId(),
          personId: _person.id,
          type: PersonEventType.other,
        );
    final saved = await showPersonEventSheet(
      context,
      event: draft,
      editing: existing != null,
    );
    if (saved == null) return;
    await widget.personStore.saveEvent(saved, scope: _scope);
    await _reload();
  }

  /// A section with nothing in it yet, showing what it would hold.
  ///
  /// The same shape as a real row so it reads as the first one rather than as
  /// a notice, and greyed so it is plainly not filled in.
  /// Which groups this person is in.
  ///
  /// A group is worth more than a label because membership *implies* the
  /// links: everybody in a family group is family to everybody else in it, so
  /// twenty colleagues are one group rather than 190 relationships typed by
  /// hand — and 190 to unpick when somebody changes job.
  Widget _groupsSection(AppLocalizations l10n) => ProfileCard(
    children: [
      for (final group in _groups)
        ProfileDeletableRow(
          key: ValueKey('group:${group.id}'),
          editing: _editing.contains('groups'),
          onDelete: () => _leaveGroup(l10n, group),
          child: CupertinoListTile(
            title: Text(_groupLinkTitle(l10n, group)),
            subtitle: Text(groupKindLabel(l10n, group.kind)),
            additionalInfo: Text(
              l10n.profileGroupPeople(_othersIn(group).length),
            ),
            trailing: const Icon(
              CupertinoIcons.chevron_forward,
              size: 18,
              color: CupertinoColors.systemGrey2,
            ),
            onTap: () => _openGroupPeople(l10n, group),
          ),
        ),
    ],
  );

  List<String> _othersIn(PersonGroup group) => [
    for (final id in _allGroups[group] ?? const <String>[])
      if (id != _person.id) id,
  ];

  /// "Colleagues at Acme": the links a group stands for, as one row.
  String _groupLinkTitle(AppLocalizations l10n, PersonGroup group) =>
      switch (group.kind) {
        GroupKind.family => l10n.profileGroupLinksFamily(group.name),
        GroupKind.company => l10n.profileGroupLinksCompany(group.name),
        GroupKind.school => l10n.profileGroupLinksSchool(group.name),
        GroupKind.circle => l10n.profileGroupLinksCircle(group.name),
      };

  /// Everyone the group links them to, most photos together first.
  Future<void> _openGroupPeople(AppLocalizations l10n, PersonGroup group) {
    final people = [for (final id in _othersIn(group)) ?_peopleById[id]]
      ..sort((a, b) {
        final s = (_sharedPhotos[b.id] ?? 0).compareTo(
          _sharedPhotos[a.id] ?? 0,
        );
        return s != 0 ? s : a.name.compareTo(b.name);
      });
    return Navigator.of(context).push(
      CupertinoPageRoute<void>(
        builder: (_) => ProfilePeopleListScreen(
          title: _groupLinkTitle(l10n, group),
          people: people,
          personStore: widget.personStore,
          assetRecordStore: widget.assetRecordStore,
        ),
      ),
    );
  }

  Future<void> _leaveGroup(AppLocalizations l10n, PersonGroup group) async {
    final scope = _scope;
    setState(() {
      _groups = [
        for (final g in _groups)
          if (g.id != group.id) g,
      ];
    });
    await widget.personStore.leaveGroup(_person.id, group.id, scope: scope);
    if (!mounted) return;
    _undo.show(context, l10n.profileLeftGroup(group.name), () async {
      await widget.personStore.joinGroup(_person.id, group, scope: scope);
      if (mounted) await _reload();
    });
    await _reload();
  }

  /// Join one that exists, or make one. Existing first: a second "Smiths"
  /// spelled differently is two families as far as the links are concerned.
  Future<void> _addToGroup() async {
    final l10n = AppLocalizations.of(context)!;
    final mine = {for (final g in _groups) g.id};
    final joinable = [
      for (final group in _allGroups.keys)
        if (!mine.contains(group.id)) group,
    ];
    final chosen = await showCupertinoModalPopup<({PersonGroup? group})>(
      context: context,
      builder: (sheetContext) => CupertinoActionSheet(
        title: Text(l10n.groupsPickTitle),
        actions: [
          for (final group in joinable)
            CupertinoActionSheetAction(
              onPressed: () => Navigator.of(sheetContext).pop((group: group)),
              child: Text(
                '${group.name} · ${groupKindLabel(l10n, group.kind)}',
              ),
            ),
          CupertinoActionSheetAction(
            onPressed: () => Navigator.of(sheetContext).pop((group: null)),
            child: Text(l10n.groupsNewTitle),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(sheetContext).pop(),
          child: Text(l10n.actionCancel),
        ),
      ),
    );
    if (chosen == null) return;
    final group = chosen.group ?? await _makeGroup(l10n);
    if (group == null) return;
    await widget.personStore.joinGroup(_person.id, group, scope: _scope);
    await _reload();
  }

  Future<PersonGroup?> _makeGroup(AppLocalizations l10n) async {
    final name = await showProfileTextPrompt(
      context,
      title: l10n.groupsNewTitle,
      placeholder: l10n.groupsNamePlaceholder,
    );
    if (name == null || name.isEmpty || !mounted) return null;
    final kind = await showCupertinoModalPopup<GroupKind>(
      context: context,
      builder: (sheetContext) => CupertinoActionSheet(
        title: Text(l10n.groupsKindLabel),
        actions: [
          for (final kind in GroupKind.values)
            CupertinoActionSheetAction(
              onPressed: () => Navigator.of(sheetContext).pop(kind),
              child: Text(groupKindLabel(l10n, kind)),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(sheetContext).pop(),
          child: Text(l10n.actionCancel),
        ),
      ),
    );
    if (kind == null) return null;
    return PersonGroup(id: widget.personStore.newId(), name: name, kind: kind);
  }

  /// How this person stands to you, in plain words, under their name.
  ///
  /// Direct links only, and nothing at all when there are none — a profile
  /// that says "Connected to you" about somebody two hops away is worse than
  /// one that says nothing.
  Widget? _ownerRelationLine(AppLocalizations l10n) {
    if (_person.id == _ownerId) return null;
    final relations = relationsToOwner(
      ownerId: _ownerId,
      relationships: _relationships,
    );
    if (relations.isEmpty) return null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 10),
      child: Text(
        relations.map((type) => _ownerRelationLabel(l10n, type)).join(' · '),
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 13, color: CupertinoColors.systemBlue),
      ),
    );
  }

  static String _ownerRelationLabel(
    AppLocalizations l10n,
    RelationshipType type,
  ) => switch (type) {
    RelationshipType.family => l10n.ownerRelationFamily,
    RelationshipType.spouse => l10n.ownerRelationSpouse,
    RelationshipType.parent => l10n.ownerRelationParent,
    RelationshipType.child => l10n.ownerRelationChild,
    RelationshipType.sibling => l10n.ownerRelationSibling,
    RelationshipType.friend => l10n.ownerRelationFriend,
    RelationshipType.colleague => l10n.ownerRelationColleague,
    RelationshipType.schoolmate => l10n.ownerRelationSchoolmate,
    RelationshipType.other => l10n.ownerRelationOther,
  };

  /// Odd jobs, at the bottom, above Delete Person.
  Widget _utilitiesSection(AppLocalizations l10n) =>
      CupertinoListSection.insetGrouped(
        margin: const EdgeInsets.symmetric(horizontal: 16),
        backgroundColor: profileCardBackground,
        decoration: profileCardDecoration,
        children: [
          CupertinoListTile(
            key: const ValueKey('utility-this-is-me'),
            title: Text(l10n.ownerThisIsMe),
            subtitle: Text(l10n.ownerThisIsMeNote),
            trailing: CupertinoSwitch(
              value: _person.id == _ownerId,
              onChanged: (on) async {
                await _owner.set(on ? _person.id : null);
                await _reload();
              },
            ),
          ),
        ],
      );
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

String relationshipTypeLabel(AppLocalizations l10n, RelationshipType type) =>
    switch (type) {
      RelationshipType.family => l10n.relationshipTypeFamily,
      RelationshipType.spouse => l10n.relationshipTypeSpouse,
      RelationshipType.parent => l10n.relationshipTypeParent,
      RelationshipType.child => l10n.relationshipTypeChild,
      RelationshipType.sibling => l10n.relationshipTypeSibling,
      RelationshipType.friend => l10n.relationshipTypeFriend,
      RelationshipType.colleague => l10n.relationshipTypeColleague,
      RelationshipType.schoolmate => l10n.relationshipTypeSchoolmate,
      RelationshipType.other => l10n.relationshipTypeOther,
    };
