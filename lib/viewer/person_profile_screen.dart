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
/// fields (education/job/about/family), an optional passcode+hint lock over
/// those fields (photos and identity stay visible either way — see
/// DESIGN.md's risk note), relationships to other people with a link to the
/// net graph, and geolocation movement history. See IMPLEMENTATION_PLAN.md
/// T7.3-T7.7.
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
  late final TextEditingController _relatives = TextEditingController(text: _person.relativesNote);

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

  Future<Person?> _pickPerson(List<Person> candidates) => showCupertinoModalPopup<Person>(
    context: context,
    builder: (context) => CupertinoActionSheet(
      actions: [
        for (final p in candidates)
          CupertinoActionSheetAction(onPressed: () => Navigator.of(context).pop(p), child: Text(p.name)),
      ],
      cancelButton: CupertinoActionSheetAction(
        onPressed: () => Navigator.of(context).pop(),
        child: Text(AppLocalizations.of(context)!.actionCancel),
      ),
    ),
  );

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
    if (candidates.isEmpty) return;
    final other = await _pickPerson(candidates);
    if (other == null || !mounted) return;
    final type = await _pickRelationshipType();
    if (type == null) return;
    await widget.personStore.addRelationship(_person.id, other.id, type);
    await _reload();
  }

  Future<void> _removeRelationship(PersonRelationship relationship) async {
    await widget.personStore.removeRelationship(_person.id, relationship.relatedPersonId);
    await _reload();
  }

  Future<void> _addLocation() async {
    final l10n = AppLocalizations.of(context)!;
    final placeController = TextEditingController();
    var kind = LocationKind.origin;
    var since = DateTime.now();
    final saved = await showCupertinoModalPopup<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => CupertinoActionSheet(
          title: Text(l10n.locationAddTitle),
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
              child: Text(l10n.actionAdd),
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
      PersonLocation(id: widget.personStore.newId(), personId: _person.id, kind: kind, place: placeController.text.trim(), since: since),
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
          padding: const EdgeInsets.all(16),
          children: [
            Center(child: PersonAvatar(assetRecordStore: widget.assetRecordStore, localId: _person.avatarLocalId, size: 96)),
            const SizedBox(height: 16),
            _label(l10n.personProfileNameLabel),
            CupertinoTextField(
              controller: _name,
              onChanged: (v) => _persist(_person.copyWith(name: v)),
            ),
            const SizedBox(height: 16),
            if (!_fieldsVisible)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
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
              _label(l10n.personProfileEducationLabel),
              CupertinoTextField(controller: _education, onChanged: (v) => _persist(_person.copyWith(education: v))),
              const SizedBox(height: 16),
              _label(l10n.personProfileJobLabel),
              CupertinoTextField(controller: _job, onChanged: (v) => _persist(_person.copyWith(job: v))),
              const SizedBox(height: 16),
              _label(l10n.personProfileBioLabel),
              CupertinoTextField(controller: _bio, maxLines: 3, onChanged: (v) => _persist(_person.copyWith(bio: v))),
              const SizedBox(height: 16),
              _label(l10n.personProfileRelativesLabel),
              CupertinoTextField(
                controller: _relatives,
                maxLines: 2,
                onChanged: (v) => _persist(_person.copyWith(relativesNote: v)),
              ),
              const SizedBox(height: 24),
              _sectionHeader(l10n.personProfileRelationshipsHeader, onAdd: _addRelationship),
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
                ),
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
              const SizedBox(height: 24),
              _sectionHeader(l10n.personProfileLocationHeader, onAdd: _addLocation),
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
                ),
              const SizedBox(height: 32),
              CupertinoButton(
                onPressed: _confirmDeletePerson,
                child: Text(l10n.personProfileDeletePerson, style: const TextStyle(color: CupertinoColors.systemRed)),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _label(String text) =>
      Padding(padding: const EdgeInsets.only(bottom: 4), child: Text(text, style: const TextStyle(color: CupertinoColors.systemGrey)));

  Widget _sectionHeader(String title, {required VoidCallback onAdd}) => Row(
    mainAxisAlignment: MainAxisAlignment.spaceBetween,
    children: [
      Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
      CupertinoButton(padding: EdgeInsets.zero, onPressed: onAdd, child: const Icon(CupertinoIcons.add_circled)),
    ],
  );
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
