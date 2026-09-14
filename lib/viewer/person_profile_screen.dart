import 'package:flutter/cupertino.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../photos/person.dart';
import '../photos/person_store.dart';
import '../storage/asset_record_store.dart';
import '../storage/passcode_hash.dart';
import 'passcode_prompt.dart';
import 'person_avatar.dart';
import 'person_graph_screen.dart';

/// The full editable profile behind a person page's name chevron: bio
/// fields (education/job/about), an optional passcode+hint lock over those
/// fields (photos and identity stay visible either way — see DESIGN.md's
/// risk note), relationships to other people (family/relatives lives here,
/// as typed links, not a free-text field) with a link to the net graph, and
/// geolocation location history. See IMPLEMENTATION_PLAN.md T7.3-T7.7.
class PersonProfileScreen extends StatefulWidget {
  const PersonProfileScreen({super.key, required this.person, required this.personStore, required this.assetRecordStore});

  final Person person;
  final PersonStore personStore;
  final AssetRecordStore assetRecordStore;

  @override
  State<PersonProfileScreen> createState() => _PersonProfileScreenState();
}

class _PersonProfileScreenState extends State<PersonProfileScreen> {
  late Person _person = widget.person;
  late final TextEditingController _name = TextEditingController(text: _person.name);
  late final TextEditingController _education = TextEditingController(text: _person.education);
  late final TextEditingController _job = TextEditingController(text: _person.job);
  late final TextEditingController _bio = TextEditingController(text: _person.bio);

  bool _unlocked = false;
  List<PersonRelationship> _relationships = const [];
  List<Person> _allPeople = const [];
  List<PersonLocation> _locations = const [];

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final relationships = await widget.personStore.relationshipsFor(_person.id);
    final allPeople = await widget.personStore.listAll();
    final locations = await widget.personStore.locationsFor(_person.id);
    if (!mounted) return;
    setState(() {
      _relationships = relationships;
      _allPeople = allPeople;
      _locations = locations;
    });
  }

  Future<void> _persist(Person updated) async {
    setState(() => _person = updated);
    await widget.personStore.update(updated);
  }

  bool get _fieldsVisible => !_person.locked || _unlocked;

  Future<void> _handleLockTap() async {
    final l10n = AppLocalizations.of(context)!;
    if (!_person.locked) {
      final result = await showSetPasscodeSheet(context);
      if (result == null) return;
      await _persist(
        _person.copyWith(
          locked: true,
          passcodeHash: () => hashPasscode(result.passcode),
          passcodeHint: () => result.hint,
        ),
      );
      setState(() => _unlocked = false);
      return;
    }
    if (!_unlocked) {
      final entered = await showEnterPasscodeSheet(context, hint: _person.passcodeHint);
      if (entered == null) return;
      if (hashPasscode(entered) != _person.passcodeHash) {
        if (!mounted) return;
        await showCupertinoDialog<void>(
          context: context,
          builder: (context) => CupertinoAlertDialog(
            content: Text(l10n.personProfileWrongPasscode),
            actions: [CupertinoDialogAction(onPressed: () => Navigator.of(context).pop(), child: Text(l10n.actionCancel))],
          ),
        );
        return;
      }
      setState(() => _unlocked = true);
      return;
    }
    final confirmed = await showCupertinoDialog<bool>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: Text(l10n.personProfileRemoveLockTitle),
        actions: [
          CupertinoDialogAction(onPressed: () => Navigator.of(context).pop(false), child: Text(l10n.actionCancel)),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.actionDelete),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _persist(_person.copyWith(locked: false, passcodeHash: () => null, passcodeHint: () => null));
  }

  /// Prompts for a name and creates a brand-new [Person] — no photo
  /// required, same as `PeopleScreen`'s "+". Used when linking a relative
  /// who isn't in the photo registry yet.
  Future<Person?> _createPerson() async {
    final l10n = AppLocalizations.of(context)!;
    final controller = TextEditingController();
    final name = await showCupertinoDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => CupertinoAlertDialog(
          title: Text(l10n.peopleNamePromptTitle),
          content: Padding(
            padding: const EdgeInsets.only(top: 12),
            child: CupertinoTextField(controller: controller, autofocus: true, onChanged: (_) => setState(() {})),
          ),
          actions: [
            CupertinoDialogAction(onPressed: () => Navigator.of(context).pop(), child: Text(l10n.actionCancel)),
            CupertinoDialogAction(
              onPressed: controller.text.trim().isEmpty ? null : () => Navigator.of(context).pop(controller.text.trim()),
              child: Text(l10n.actionAdd),
            ),
          ],
        ),
      ),
    );
    if (name == null || name.isEmpty) return null;
    final created = await widget.personStore.create(name: name);
    if (mounted) setState(() => _allPeople = [..._allPeople, created]);
    return created;
  }

  /// The relationship "+" popup: pick an existing person from [candidates],
  /// or "New Person…" to create one on the spot (no photo required).
  Future<Person?> _pickOrCreatePerson(List<Person> candidates) async {
    final l10n = AppLocalizations.of(context)!;
    Person? picked;
    var wantsNew = false;
    await showCupertinoModalPopup<void>(
      context: context,
      builder: (sheetContext) => CupertinoActionSheet(
        title: Text(l10n.relationshipPickerTitle),
        actions: [
          CupertinoActionSheetAction(
            onPressed: () {
              wantsNew = true;
              Navigator.of(sheetContext).pop();
            },
            child: Text(l10n.personProfileNewPersonOption),
          ),
          for (final p in candidates)
            CupertinoActionSheetAction(
              onPressed: () {
                picked = p;
                Navigator.of(sheetContext).pop();
              },
              child: Text(p.name),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(sheetContext).pop(),
          child: Text(l10n.actionCancel),
        ),
      ),
    );
    if (wantsNew) return mounted ? _createPerson() : null;
    return picked;
  }

  String _relationshipLabel(AppLocalizations l10n, RelationshipType type) => switch (type) {
    RelationshipType.family => l10n.relationshipTypeFamily,
    RelationshipType.spouse => l10n.relationshipTypeSpouse,
    RelationshipType.parent => l10n.relationshipTypeParent,
    RelationshipType.child => l10n.relationshipTypeChild,
    RelationshipType.sibling => l10n.relationshipTypeSibling,
    RelationshipType.friend => l10n.relationshipTypeFriend,
    RelationshipType.colleague => l10n.relationshipTypeColleague,
    RelationshipType.other => l10n.relationshipTypeOther,
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
        cancelButton: CupertinoActionSheetAction(onPressed: () => Navigator.of(context).pop(), child: Text(l10n.actionCancel)),
      ),
    );
  }

  Future<void> _addRelationship() async {
    final linkedIds = _relationships.map((r) => r.relatedPersonId).toSet();
    final candidates = _allPeople.where((p) => p.id != _person.id && !linkedIds.contains(p.id)).toList();
    final other = await _pickOrCreatePerson(candidates);
    if (other == null || !mounted) return;
    final type = await _pickRelationshipType();
    if (type == null) return;
    await widget.personStore.addRelationship(_person.id, other.id, type);
    await _reload();
  }

  /// Tapping an existing relationship row re-picks its type — `addRelationship`
  /// replaces the row (same personId/relatedPersonId), so this doubles as edit.
  Future<void> _editRelationship(PersonRelationship relationship) async {
    final type = await _pickRelationshipType();
    if (type == null) return;
    await widget.personStore.addRelationship(_person.id, relationship.relatedPersonId, type);
    await _reload();
  }

  Future<void> _removeRelationship(PersonRelationship relationship) async {
    await widget.personStore.removeRelationship(_person.id, relationship.relatedPersonId);
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
          title: Text(existing == null ? l10n.locationAddTitle : l10n.locationEditTitle),
          message: Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Column(
              children: [
                CupertinoTextField(controller: placeController, placeholder: l10n.locationPlaceLabel),
                const SizedBox(height: 12),
                CupertinoSlidingSegmentedControl<LocationKind>(
                  groupValue: kind,
                  children: {
                    LocationKind.origin: Text(l10n.personProfileLocationOrigin),
                    LocationKind.relocation: Text(l10n.personProfileLocationRelocation),
                  },
                  onValueChanged: (value) => setState(() => kind = value ?? kind),
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
              onPressed: () => Navigator.of(context).pop(placeController.text.trim().isNotEmpty),
              child: Text(existing == null ? l10n.actionAdd : l10n.settingsSaveButton),
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

  Future<void> _confirmDeletePerson() async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showCupertinoDialog<bool>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: Text(l10n.personProfileDeleteConfirmTitle),
        content: Text(l10n.personProfileDeleteConfirmBody),
        actions: [
          CupertinoDialogAction(onPressed: () => Navigator.of(context).pop(false), child: Text(l10n.actionCancel)),
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
    if (!mounted) return;
    // Pops both this profile screen and the person page beneath it (a
    // single shared `Navigator`, no nesting) — lands back on the People
    // list, which no longer has anything to show for the deleted person.
    final navigator = Navigator.of(context);
    navigator.pop();
    navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(l10n.personProfileTitle),
        trailing: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: _handleLockTap,
          child: Icon(
            !_person.locked
                ? CupertinoIcons.lock_open
                : (_unlocked ? CupertinoIcons.lock_open_fill : CupertinoIcons.lock_fill),
          ),
        ),
      ),
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: 16),
          children: [
            Center(child: PersonAvatar(assetRecordStore: widget.assetRecordStore, localId: _person.avatarLocalId, size: 96)),
            const SizedBox(height: 20),
            CupertinoFormSection.insetGrouped(
              margin: const EdgeInsets.symmetric(horizontal: 16),
              children: [
                CupertinoTextFormFieldRow(
                  prefix: Text(l10n.personProfileNameLabel),
                  controller: _name,
                  onChanged: (v) => _persist(_person.copyWith(name: v)),
                ),
              ],
            ),
            const SizedBox(height: 20),
            if (!_fieldsVisible)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
                child: Column(
                  children: [
                    const Icon(CupertinoIcons.lock_fill, size: 32, color: CupertinoColors.systemGrey),
                    const SizedBox(height: 8),
                    Text(l10n.personProfileLockedNote, style: const TextStyle(color: CupertinoColors.systemGrey)),
                    if ((_person.passcodeHint ?? '').isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          l10n.personProfileHintPrefix(_person.passcodeHint!),
                          style: const TextStyle(color: CupertinoColors.systemGrey),
                        ),
                      ),
                    const SizedBox(height: 12),
                    CupertinoButton.filled(onPressed: _handleLockTap, child: Text(l10n.personProfileUnlockButton)),
                  ],
                ),
              )
            else ...[
              CupertinoFormSection.insetGrouped(
                margin: const EdgeInsets.symmetric(horizontal: 16),
                children: [
                  CupertinoTextFormFieldRow(
                    prefix: Text(l10n.personProfileEducationLabel),
                    controller: _education,
                    onChanged: (v) => _persist(_person.copyWith(education: v)),
                  ),
                  CupertinoTextFormFieldRow(
                    prefix: Text(l10n.personProfileJobLabel),
                    controller: _job,
                    onChanged: (v) => _persist(_person.copyWith(job: v)),
                  ),
                  CupertinoTextFormFieldRow(
                    prefix: Text(l10n.personProfileBioLabel),
                    controller: _bio,
                    maxLines: null,
                    onChanged: (v) => _persist(_person.copyWith(bio: v)),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              _sectionHeader(l10n.personProfileRelationshipsHeader, onAdd: _addRelationship),
              CupertinoListSection.insetGrouped(
                margin: const EdgeInsets.symmetric(horizontal: 16),
                backgroundColor: const Color(0xFF1C1C1E),
                decoration: const BoxDecoration(color: Color(0xFF2C2C2E), borderRadius: BorderRadius.all(Radius.circular(10))),
                children: [
                  for (final relationship in _relationships)
                    CupertinoListTile(
                      title: Text(
                        _allPeople.where((p) => p.id == relationship.relatedPersonId).map((p) => p.name).firstOrNull ?? '?',
                      ),
                      subtitle: Text(_relationshipLabel(l10n, relationship.type)),
                      trailing: CupertinoButton(
                        padding: EdgeInsets.zero,
                        onPressed: () => _removeRelationship(relationship),
                        child: const Icon(CupertinoIcons.xmark_circle, color: CupertinoColors.systemGrey),
                      ),
                      onTap: () => _editRelationship(relationship),
                    ),
                  CupertinoListTile(
                    title: Center(child: Text(l10n.personProfileViewGraph, style: const TextStyle(color: CupertinoColors.activeBlue))),
                    onTap: () => Navigator.of(context).push(
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
              const SizedBox(height: 20),
              _sectionHeader(l10n.personProfileLocationHeader, onAdd: () => _editLocation()),
              if (_locations.isNotEmpty)
                CupertinoListSection.insetGrouped(
                  margin: const EdgeInsets.symmetric(horizontal: 16),
                  backgroundColor: const Color(0xFF1C1C1E),
                  decoration: const BoxDecoration(color: Color(0xFF2C2C2E), borderRadius: BorderRadius.all(Radius.circular(10))),
                  children: [
                    for (final location in _locations)
                      CupertinoListTile(
                        title: Text(location.place),
                        subtitle: Text(
                          '${location.kind == LocationKind.origin ? l10n.personProfileLocationOrigin : l10n.personProfileLocationRelocation} · ${DateFormat.yMMM().format(location.since)}',
                        ),
                        trailing: CupertinoButton(
                          padding: EdgeInsets.zero,
                          onPressed: () => _removeLocation(location),
                          child: const Icon(CupertinoIcons.xmark_circle, color: CupertinoColors.systemGrey),
                        ),
                        onTap: () => _editLocation(existing: location),
                      ),
                  ],
                ),
              const SizedBox(height: 32),
              Center(
                child: CupertinoButton(
                  onPressed: _confirmDeletePerson,
                  child: Text(l10n.personProfileDeletePerson, style: const TextStyle(color: CupertinoColors.systemRed)),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _sectionHeader(String title, {required VoidCallback onAdd}) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        CupertinoButton(padding: EdgeInsets.zero, onPressed: onAdd, child: const Icon(CupertinoIcons.add_circled)),
      ],
    ),
  );
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
