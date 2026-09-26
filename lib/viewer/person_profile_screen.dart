import 'package:flutter/cupertino.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../photos/person.dart';
import '../photos/face_identity.dart';
import '../photos/person_detail.dart';
import '../photos/person_store.dart';
import '../storage/asset_record_store.dart';
import '../storage/passcode_hash.dart';
import '../vault/keys.dart';
import '../vault/passphrase_sheet.dart';
import 'custom_fields_editor.dart';
import 'person_event_sheet.dart';
import 'person_traits_editor.dart';
import 'private_album_gate.dart';
import 'person_avatar.dart';
import 'person_avatar_picker.dart';
import 'person_graph_screen.dart';
import 'person_history_detail_screen.dart';
import 'person_page_screen.dart';
import 'person_picker_sheet.dart';
import 'search_picker_sheet.dart';

/// The full editable profile behind a person page's name chevron.
///
/// Name and About, then Education and Job as their own pick-or-type
/// sections, Places Lived, More details, Impression, Events, and
/// Relationships last (where family and relatives live, as typed links
/// rather than a free-text field) with the link to the net graph beside
/// them.
///
/// Everything below the name belongs to a passcode rather than to the
/// person — four digits on the keypad in the nav bar switch which set is on
/// screen, and digits nobody has used show an empty one. Identity and photos
/// are visible either way. See `person_detail.dart` and
/// IMPLEMENTATION_PLAN.md T7.3-T7.7.
/// A section's own "+", findable by name rather than by counting — the
/// sections have been reordered twice now, and every positional lookup
/// silently pointed at the wrong one both times.
Key profileSectionAddKey(String title) => ValueKey('section-add:$title');

/// The blank first row a section shows before anything is in it.
Key profileSectionPromptKey(String title) => ValueKey('section-prompt:$title');

class PersonProfileScreen extends StatefulWidget {
  const PersonProfileScreen({
    super.key,
    required this.person,
    required this.personStore,
    required this.assetRecordStore,
    this.vaultKeys,
    this.autofocusName = false,
  });

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
  static const _cardBackground = Color(0xFF1C1C1E);
  static const _cardDecoration = BoxDecoration(
    color: Color(0xFF2C2C2E),
    borderRadius: BorderRadius.all(Radius.circular(10)),
  );

  late Person _person = widget.person;
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
  String _namespace = openNamespace;
  AlbumKeys? _keys;
  PersonDetail _detail = PersonDetail.empty;

  late final VaultKeys _vaultKeys = widget.vaultKeys ?? VaultKeys();
  List<PersonRelationship> _relationships = const [];
  List<Person> _allPeople = const [];
  List<PersonLocation> _locations = const [];
  List<PersonHistoryEntry> _education = const [];
  List<PersonHistoryEntry> _jobs = const [];
  List<PersonEvent> _events = const [];

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _name.dispose();
    _bio.dispose();
    _hint.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final store = widget.personStore;
    final ns = _namespace;
    final keys = _keys;
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
    if (!mounted) return;
    setState(() {
      _detail = detail;
      _relationships = relationships;
      _allPeople = allPeople;
      _locations = locations;
      _education = education;
      _jobs = jobs;
      _events = events;
      if (_bio.text != detail.bio) _bio.text = detail.bio;
      if (_hint.text != detail.hint) _hint.text = detail.hint;
    });
  }

  Future<void> _persistDetail(PersonDetail updated) async {
    setState(() => _detail = updated);
    await widget.personStore.saveDetail(
      _person.id,
      updated,
      passcodeHash: _namespace,
      keys: _keys,
    );
  }

  Future<void> _persist(Person updated) async {
    setState(() => _person = updated);
    await widget.personStore.update(updated);
  }

  /// Their photos, one tap, done. The face box goes with it: a crop only
  /// means anything on the photo it was tapped in, so carrying it over to
  /// a different picture would frame somebody's elbow.
  Future<void> _pickAvatar() async {
    final chosen = await Navigator.of(context).push<String>(
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
      _person.copyWith(avatarLocalId: chosen, avatarFace: () => null),
    );
  }

  /// "+": pick (or type) a title first — school/employer name is never
  /// blank — then open the detail page for dates/notes/custom fields.
  Future<void> _addHistoryEntry(
    HistoryCategory category,
    String categoryLabel,
  ) async {
    final options = await widget.personStore.allHistoryTitles(category);
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
    await widget.personStore.addHistoryEntry(entry);
    if (!mounted) return;
    await Navigator.of(context).push(
      CupertinoPageRoute(
        builder: (_) => PersonHistoryDetailScreen(
          entry: entry,
          categoryLabel: categoryLabel,
          personStore: widget.personStore,
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
    if (_namespace != openNamespace) {
      setState(() {
        _namespace = openNamespace;
        _keys = null;
      });
      await _reload();
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
    final keys = await _vaultKeys.unlockAlbum(passcode);
    if (keys == null || !mounted) return;
    setState(() {
      _namespace = hashPasscode(passcode);
      _keys = keys;
    });
    await _reload();
  }

  String _relationshipLabel(AppLocalizations l10n, RelationshipType type) =>
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
    );
    if (other == null || !mounted) return;

    final type = await _pickRelationshipType();
    if (type == null) return;

    String? organization;
    if (relationshipNeedsOrganization(type)) {
      final orgOptions = await widget.personStore.allOrganizations();
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
      );
    }
    await widget.personStore.addRelationship(
      _person.id,
      other.id,
      type,
      organization: organization,
    );
    await _reload();
  }

  Future<void> _removeRelationship(PersonRelationship relationship) async {
    final l10n = AppLocalizations.of(context)!;
    final name =
        _allPeople
            .where((p) => p.id == relationship.relatedPersonId)
            .map((p) => p.name)
            .firstOrNull ??
        '?';
    final confirmed = await showCupertinoDialog<bool>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: Text(l10n.relationshipDeleteConfirmTitle),
        content: Text(l10n.relationshipDeleteConfirmBody(name)),
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
    if (confirmed != true) return;
    await widget.personStore.removeRelationship(
      _person.id,
      relationship.relatedPersonId,
    );
    await _reload();
  }

  /// Tapping a relationship row's name opens *that* person's page — editing
  /// the link itself (who/type/organization) is the separate pencil button.
  Future<void> _openRelatedPerson(PersonRelationship relationship) async {
    final other = _allPeople
        .where((p) => p.id == relationship.relatedPersonId)
        .firstOrNull;
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
    );
    await _reload();
  }

  Future<void> _removeLocation(PersonLocation location) async {
    await widget.personStore.removeLocation(location.id);
    await _reload();
  }

  Future<void> _editBirthDate() async {
    final l10n = AppLocalizations.of(context)!;
    var picked = _detail.birthDate ?? DateTime(DateTime.now().year - 30);
    final saved = await showCupertinoModalPopup<bool>(
      context: context,
      builder: (context) => CupertinoActionSheet(
        title: Text(l10n.personProfileAgeLabel),
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
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l10n.actionCancel),
        ),
      ),
    );
    if (saved != true) return;
    await _persistDetail(_detail.copyWith(birthDate: () => picked));
  }

  Future<void> _pickGender() async {
    final l10n = AppLocalizations.of(context)!;
    final selected = await showCupertinoModalPopup<Gender>(
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
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.actionCancel),
        ),
      ),
    );
    if (selected == null) return;
    await _persistDetail(_detail.copyWith(gender: () => selected));
  }

  /// Plain text, no box — "30 years old · Male", each part its own tap
  /// target (age opens the birth date picker, gender opens a picker sheet).
  /// A reminder of *which* set this is, shown only from inside it.
  ///
  /// Outside, it would be proof that the set exists, which is the whole
  /// thing the keypad avoids saying. In here it is the opposite of a
  /// secret: somebody who keeps three sets needs to know which one they
  /// have opened.
  Widget _hintRow(AppLocalizations l10n) => Padding(
    padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
    child: CupertinoTextField.borderless(
      controller: _hint,
      textAlign: TextAlign.center,
      placeholder: l10n.personProfileHintLabel,
      placeholderStyle: const TextStyle(
        fontSize: 13,
        color: CupertinoColors.systemGrey2,
      ),
      style: const TextStyle(fontSize: 13, color: CupertinoColors.systemGrey),
      onChanged: (v) => _persistDetail(_detail.copyWith(hint: v)),
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

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
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
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: 16),
          children: [
            Center(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _pickAvatar,
                child: Stack(
                  alignment: Alignment.bottomRight,
                  children: [
                    PersonAvatar(
                      assetRecordStore: widget.assetRecordStore,
                      localId: _person.avatarLocalId,
                      face: _person.avatarFace,
                      size: 96,
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
            const SizedBox(height: 16),
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
                onChanged: (v) => _persist(_person.copyWith(name: v)),
              ),
            ),
            const SizedBox(height: 20),
            ...[
              if (_namespace != openNamespace) _hintRow(l10n),
              _ageGenderRow(l10n),
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: CupertinoTextField.borderless(
                  controller: _bio,
                  maxLines: null,
                  textAlign: TextAlign.center,
                  placeholder: l10n.personProfileBioEmpty,
                  style: const TextStyle(
                    fontSize: 15,
                    color: CupertinoColors.systemGrey,
                  ),
                  onChanged: (v) => _persistDetail(_detail.copyWith(bio: v)),
                ),
              ),
              const SizedBox(height: 20),
              _sectionHeader(
                l10n.personProfileEducationLabel,
                onAdd: () => _addHistoryEntry(
                  HistoryCategory.education,
                  l10n.personProfileEducationLabel,
                ),
              ),
              _historySection(
                _education,
                l10n.personProfileEducationLabel,
                category: HistoryCategory.education,
              ),
              const SizedBox(height: 20),
              _sectionHeader(
                l10n.personProfileJobLabel,
                onAdd: () => _addHistoryEntry(
                  HistoryCategory.job,
                  l10n.personProfileJobLabel,
                ),
              ),
              _historySection(
                _jobs,
                l10n.personProfileJobLabel,
                category: HistoryCategory.job,
              ),
              const SizedBox(height: 20),
              _sectionHeader(
                l10n.personProfileLocationHeader,
                onAdd: () => _editLocation(),
              ),
              if (_locations.isEmpty)
                _promptRow(
                  key: profileSectionPromptKey(
                    l10n.personProfileLocationHeader,
                  ),
                  title: l10n.personProfileLocationPrompt,
                  hint: l10n.personProfileLocationPromptHint,
                  onTap: () => _editLocation(),
                ),
              if (_locations.isNotEmpty)
                CupertinoListSection.insetGrouped(
                  margin: const EdgeInsets.symmetric(horizontal: 16),
                  backgroundColor: _cardBackground,
                  decoration: _cardDecoration,
                  children: [
                    for (var i = 0; i < _sortedLocations.length; i++)
                      CupertinoListTile(
                        title: Text(_sortedLocations[i].place),
                        subtitle: Text(_locationRangeLabel(l10n, i)),
                        trailing: CupertinoButton(
                          padding: EdgeInsets.zero,
                          onPressed: () => _removeLocation(_sortedLocations[i]),
                          child: const Icon(
                            CupertinoIcons.xmark_circle,
                            color: CupertinoColors.systemGrey,
                          ),
                        ),
                        onTap: () =>
                            _editLocation(existing: _sortedLocations[i]),
                      ),
                  ],
                ),
              const SizedBox(height: 20),
              PersonTraitsEditor(
                traits: _detail.traits,
                background: _cardBackground,
                decoration: _cardDecoration,
                onChanged: (traits) =>
                    _persistDetail(_detail.copyWith(traits: traits)),
              ),
              const SizedBox(height: 4),
              CustomFieldsEditor(
                initialFields: _detail.customFields,
                onChanged: (fields) =>
                    _persistDetail(_detail.copyWith(customFields: fields)),
              ),
              const SizedBox(height: 20),
              _sectionHeader(l10n.impressionHeader),
              _impressionSection(l10n),
              const SizedBox(height: 20),
              _sectionHeader(l10n.eventsHeader, onAdd: () => _editEvent()),
              _eventsSection(l10n),
              const SizedBox(height: 20),
              _sectionHeader(
                l10n.personProfileRelationshipsHeader,
                onAdd: () => _addOrEditRelationship(),
              ),
              for (final type in RelationshipType.values)
                if (_relationships.where((r) => r.type == type).toList()
                    case final group when group.isNotEmpty) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                    child: Text(
                      _relationshipLabel(l10n, type),
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: CupertinoColors.systemGrey,
                      ),
                    ),
                  ),
                  CupertinoListSection.insetGrouped(
                    margin: const EdgeInsets.symmetric(horizontal: 16),
                    backgroundColor: _cardBackground,
                    decoration: _cardDecoration,
                    children: [
                      for (final relationship in group)
                        CupertinoListTile(
                          title: Text(
                            _allPeople
                                    .where(
                                      (p) =>
                                          p.id == relationship.relatedPersonId,
                                    )
                                    .map((p) => p.name)
                                    .firstOrNull ??
                                '?',
                          ),
                          subtitle:
                              relationship.organization == null ||
                                  relationship.organization!.isEmpty
                              ? null
                              : Text(relationship.organization!),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              CupertinoButton(
                                padding: EdgeInsets.zero,
                                onPressed: () => _addOrEditRelationship(
                                  existing: relationship,
                                ),
                                child: const Icon(
                                  CupertinoIcons.pencil,
                                  size: 20,
                                  color: CupertinoColors.systemGrey,
                                ),
                              ),
                              const SizedBox(width: 12),
                              CupertinoButton(
                                padding: EdgeInsets.zero,
                                onPressed: () =>
                                    _removeRelationship(relationship),
                                child: const Icon(
                                  CupertinoIcons.xmark_circle,
                                  color: CupertinoColors.systemGrey,
                                ),
                              ),
                            ],
                          ),
                          onTap: () => _openRelatedPerson(relationship),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                ],
              CupertinoButton(
                padding: EdgeInsets.zero,
                onPressed: () => Navigator.of(context).push(
                  CupertinoPageRoute(
                    builder: (_) => PersonGraphScreen(
                      personStore: widget.personStore,
                      assetRecordStore: widget.assetRecordStore,
                      focusPersonId: _person.id,
                    ),
                  ),
                ),
                child: Text(l10n.personProfileViewGraph),
              ),
              const SizedBox(height: 20),
              const SizedBox(height: 32),
              Center(
                child: CupertinoButton(
                  onPressed: _confirmDeletePerson,
                  child: Text(
                    l10n.personProfileDeletePerson,
                    style: const TextStyle(color: CupertinoColors.systemRed),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String? _dateRangeLabel(AppLocalizations l10n, PersonHistoryEntry entry) {
    if (entry.startDate == null && entry.endDate == null) return null;
    final start = entry.startDate == null
        ? ''
        : DateFormat.y().format(entry.startDate!);
    final end = entry.endDate == null
        ? l10n.personHistoryPresentLabel
        : DateFormat.y().format(entry.endDate!);
    return start.isEmpty ? end : '$start – $end';
  }

  Widget _historySection(
    List<PersonHistoryEntry> entries,
    String categoryLabel, {
    HistoryCategory? category,
  }) {
    final l10n = AppLocalizations.of(context)!;
    // An empty section used to render nothing at all, so a fresh profile
    // showed a heading and a "+" and no clue what either was for. The row
    // names the fields instead, and tapping it is the same as tapping "+".
    if (entries.isEmpty) {
      return category == null
          ? const SizedBox.shrink()
          : _promptRow(
              key: profileSectionPromptKey(categoryLabel),
              title: category == HistoryCategory.education
                  ? l10n.personProfileEducationPrompt
                  : l10n.personProfileJobPrompt,
              hint: category == HistoryCategory.education
                  ? l10n.personProfileEducationPromptHint
                  : l10n.personProfileJobPromptHint,
              onTap: () => _addHistoryEntry(category, categoryLabel),
            );
    }
    return CupertinoListSection.insetGrouped(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      backgroundColor: _cardBackground,
      decoration: _cardDecoration,
      children: [
        for (final entry in entries)
          CupertinoListTile(
            title: Text(
              entry.latestTitle?.title ??
                  (entry.title.isEmpty
                      ? l10n.personProfileNotSet
                      : entry.title),
            ),
            subtitle: switch (_historySubtitle(l10n, entry)) {
              final label? => Text(label),
              null => null,
            },
            trailing: const Icon(
              CupertinoIcons.chevron_forward,
              size: 18,
              color: CupertinoColors.systemGrey2,
            ),
            onTap: () => _openHistoryEntry(entry, categoryLabel),
          ),
      ],
    );
  }

  /// School/employer name (already the top line if there's no [latestTitle]
  /// yet, so skipped then) plus the date range, "·"-joined.
  String? _historySubtitle(AppLocalizations l10n, PersonHistoryEntry entry) {
    final range = _dateRangeLabel(l10n, entry);
    final parts = [
      if (entry.latestTitle != null && entry.title.isNotEmpty) entry.title,
      ?range,
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  /// Impressions of somebody, not an assessment of them.
  ///
  /// Three scales and a set of tags, all optional and none scored. The
  /// scales are the ones a reader already has words for; the tags carry what
  /// a personality model would otherwise name, without naming it.
  Widget _impressionSection(AppLocalizations l10n) {
    final impression = _detail.impression;
    return Column(
      children: [
        CupertinoListSection.insetGrouped(
          margin: const EdgeInsets.symmetric(horizontal: 16),
          backgroundColor: _cardBackground,
          decoration: _cardDecoration,
          children: [
            _impressionRow(
              l10n,
              label: l10n.impressionOverallLabel,
              value: impression.overall,
              name: (level) => _overallLabel(l10n, level),
              onPicked: (level) => _persistDetail(
                _detail.copyWith(
                  impression: impression.copyWith(overall: () => level),
                ),
              ),
            ),
            _impressionRow(
              l10n,
              label: l10n.impressionSocialLabel,
              value: impression.socialEnergy,
              name: (level) => _socialLabel(l10n, level),
              onPicked: (level) => _persistDetail(
                _detail.copyWith(
                  impression: impression.copyWith(socialEnergy: () => level),
                ),
              ),
            ),
            _impressionRow(
              l10n,
              label: l10n.impressionIntroversionLabel,
              value: impression.introversion,
              name: (level) => _introversionLabel(l10n, level),
              onPicked: (level) => _persistDetail(
                _detail.copyWith(
                  impression: impression.copyWith(introversion: () => level),
                ),
              ),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              l10n.impressionTagsLabel,
              style: const TextStyle(
                fontSize: 13,
                color: CupertinoColors.systemGrey,
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final tag in impressionTags)
                _impressionTagChip(l10n, tag, impression),
            ],
          ),
        ),
      ],
    );
  }

  Widget _impressionRow(
    AppLocalizations l10n, {
    required String label,
    required ImpressionLevel? value,
    required String Function(ImpressionLevel) name,
    required ValueChanged<ImpressionLevel?> onPicked,
  }) => CupertinoListTile(
    title: Text(label),
    trailing: Text(
      value == null ? l10n.impressionNotSet : name(value),
      style: TextStyle(
        color: value == null
            ? CupertinoColors.systemGrey
            : CupertinoColors.white,
      ),
    ),
    onTap: () async {
      final picked = await showCupertinoModalPopup<({ImpressionLevel? level})>(
        context: context,
        builder: (sheetContext) => CupertinoActionSheet(
          title: Text(label),
          actions: [
            for (final level in ImpressionLevel.values)
              CupertinoActionSheetAction(
                onPressed: () => Navigator.of(sheetContext).pop((level: level)),
                child: Text(name(level)),
              ),
            // Clearing has to be possible: an impression recorded by accident
            // is worse than none, and this is somebody's view of a person.
            if (value != null)
              CupertinoActionSheetAction(
                isDestructiveAction: true,
                onPressed: () => Navigator.of(sheetContext).pop((level: null)),
                child: Text(l10n.impressionNotSet),
              ),
          ],
          cancelButton: CupertinoActionSheetAction(
            onPressed: () => Navigator.of(sheetContext).pop(),
            child: Text(l10n.actionCancel),
          ),
        ),
      );
      if (picked != null) onPicked(picked.level);
    },
  );

  Widget _impressionTagChip(
    AppLocalizations l10n,
    String tag,
    PersonImpression impression,
  ) {
    final on = impression.tags.contains(tag);
    return GestureDetector(
      onTap: () => _persistDetail(
        _detail.copyWith(
          impression: impression.copyWith(
            tags: on
                ? [
                    for (final t in impression.tags)
                      if (t != tag) t,
                  ]
                : [...impression.tags, tag],
          ),
        ),
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: on ? CupertinoColors.systemBlue : const Color(0xFF2C2C2E),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Text(
          _tagLabel(l10n, tag),
          style: TextStyle(
            fontSize: 13,
            color: on ? CupertinoColors.white : CupertinoColors.systemGrey,
          ),
        ),
      ),
    );
  }

  static String _overallLabel(AppLocalizations l10n, ImpressionLevel level) =>
      switch (level) {
        ImpressionLevel.veryLow => l10n.impressionOverallVeryLow,
        ImpressionLevel.low => l10n.impressionOverallLow,
        ImpressionLevel.middle => l10n.impressionOverallMiddle,
        ImpressionLevel.high => l10n.impressionOverallHigh,
        ImpressionLevel.veryHigh => l10n.impressionOverallVeryHigh,
      };

  static String _socialLabel(AppLocalizations l10n, ImpressionLevel level) =>
      switch (level) {
        ImpressionLevel.veryLow => l10n.impressionSocialVeryLow,
        ImpressionLevel.low => l10n.impressionSocialLow,
        ImpressionLevel.middle => l10n.impressionSocialMiddle,
        ImpressionLevel.high => l10n.impressionSocialHigh,
        ImpressionLevel.veryHigh => l10n.impressionSocialVeryHigh,
      };

  static String _introversionLabel(
    AppLocalizations l10n,
    ImpressionLevel level,
  ) => switch (level) {
    ImpressionLevel.veryLow => l10n.impressionIntroversionVeryLow,
    ImpressionLevel.low => l10n.impressionIntroversionLow,
    ImpressionLevel.middle => l10n.impressionIntroversionMiddle,
    ImpressionLevel.high => l10n.impressionIntroversionHigh,
    ImpressionLevel.veryHigh => l10n.impressionIntroversionVeryHigh,
  };

  static String _tagLabel(AppLocalizations l10n, String tag) => switch (tag) {
    'curious' => l10n.impressionTagCurious,
    'organised' => l10n.impressionTagOrganised,
    'spontaneous' => l10n.impressionTagSpontaneous,
    'empathetic' => l10n.impressionTagEmpathetic,
    'blunt' => l10n.impressionTagBlunt,
    'patient' => l10n.impressionTagPatient,
    'competitive' => l10n.impressionTagCompetitive,
    'generous' => l10n.impressionTagGenerous,
    'private' => l10n.impressionTagPrivate,
    'funny' => l10n.impressionTagFunny,
    'steady' => l10n.impressionTagSteady,
    _ => l10n.impressionTagIntense,
  };

  /// What happened, oldest first.
  ///
  /// "First met / knew at" is always the first row and cannot be removed.
  /// It is not written to the database until a date is put on it, so an
  /// empty one reads as a prompt rather than as something the app decided.
  Widget _eventsSection(AppLocalizations l10n) {
    final firstMet = _events.where((e) => e.isFirstMet).firstOrNull;
    final rest = [
      for (final e in _events)
        if (!e.isFirstMet) e,
    ];
    return CupertinoListSection.insetGrouped(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      backgroundColor: _cardBackground,
      decoration: _cardDecoration,
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
        for (final event in rest)
          CupertinoListTile(
            title: Text(eventTypeLabel(l10n, event.type)),
            subtitle: Text(
              [
                if (event.at != null) _eventDate(event.at!),
                if (event.tags.isNotEmpty) event.tags.join(', '),
                if (event.notes.isNotEmpty) event.notes,
              ].join(' · '),
            ),
            trailing: CupertinoButton(
              padding: EdgeInsets.zero,
              onPressed: () => _removeEvent(l10n, event),
              child: const Icon(
                CupertinoIcons.xmark_circle,
                color: CupertinoColors.systemGrey,
              ),
            ),
            onTap: () => _editEvent(existing: event),
          ),
      ],
    );
  }

  static String _eventDate(DateTime at) => DateFormat.yMMMd().format(at);

  Future<void> _removeEvent(AppLocalizations l10n, PersonEvent event) async {
    final confirmed = await showCupertinoDialog<bool>(
      context: context,
      builder: (dialogContext) => CupertinoAlertDialog(
        title: Text(l10n.eventsDeleteConfirmTitle),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.actionCancel),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.actionDelete),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await widget.personStore.removeEvent(event.id);
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
    final saved = await showPersonEventSheet(context, event: draft);
    if (saved == null) return;
    await widget.personStore.saveEvent(
      saved,
      passcodeHash: _namespace,
      keys: _keys,
    );
    await _reload();
  }

  /// A section with nothing in it yet, showing what it would hold.
  ///
  /// The same shape as a real row so it reads as the first one rather than as
  /// a notice, and greyed so it is plainly not filled in.
  Widget _promptRow({
    required Key key,
    required String title,
    required String hint,
    required VoidCallback onTap,
  }) => CupertinoListSection.insetGrouped(
    margin: const EdgeInsets.symmetric(horizontal: 16),
    backgroundColor: _cardBackground,
    decoration: _cardDecoration,
    children: [
      CupertinoListTile(
        key: key,
        title: Text(
          title,
          style: const TextStyle(color: CupertinoColors.systemGrey),
        ),
        subtitle: Text(
          hint,
          style: const TextStyle(color: CupertinoColors.systemGrey2),
        ),
        trailing: const Icon(
          CupertinoIcons.chevron_forward,
          size: 18,
          color: CupertinoColors.systemGrey2,
        ),
        onTap: onTap,
      ),
    ],
  );

  Widget _sectionHeader(String title, {VoidCallback? onAdd}) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          title,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
        ),
        if (onAdd != null)
          CupertinoButton(
            key: profileSectionAddKey(title),
            padding: EdgeInsets.zero,
            onPressed: onAdd,
            child: const Icon(CupertinoIcons.add_circled),
          ),
      ],
    ),
  );
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
