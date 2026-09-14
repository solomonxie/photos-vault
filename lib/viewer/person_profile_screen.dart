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
import 'person_history_detail_screen.dart';
import 'person_picker_screen.dart';
import 'string_picker_screen.dart';

/// The full editable profile behind a person page's name chevron: Name/About,
/// Education and Job as their own pick-or-type sections, an optional
/// passcode+hint lock over those sections (photos and identity stay visible
/// either way — see DESIGN.md's risk note), Relationships (family/relatives
/// lives here, as typed links, not a free-text field) with a link to the net
/// graph, and Places Lived (always last). See IMPLEMENTATION_PLAN.md
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
  static const _cardBackground = Color(0xFF1C1C1E);
  static const _cardDecoration = BoxDecoration(color: Color(0xFF2C2C2E), borderRadius: BorderRadius.all(Radius.circular(10)));

  late Person _person = widget.person;
  late final TextEditingController _name = TextEditingController(text: _person.name);
  late final TextEditingController _bio = TextEditingController(text: _person.bio);

  bool _unlocked = false;
  List<PersonRelationship> _relationships = const [];
  List<Person> _allPeople = const [];
  List<PersonLocation> _locations = const [];
  List<PersonHistoryEntry> _education = const [];
  List<PersonHistoryEntry> _jobs = const [];

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _name.dispose();
    _bio.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final relationships = await widget.personStore.relationshipsFor(_person.id);
    final allPeople = await widget.personStore.listAll();
    final locations = await widget.personStore.locationsFor(_person.id);
    final education = await widget.personStore.historyFor(_person.id, HistoryCategory.education);
    final jobs = await widget.personStore.historyFor(_person.id, HistoryCategory.job);
    if (!mounted) return;
    setState(() {
      _relationships = relationships;
      _allPeople = allPeople;
      _locations = locations;
      _education = education;
      _jobs = jobs;
    });
  }

  Future<void> _persist(Person updated) async {
    setState(() => _person = updated);
    await widget.personStore.update(updated);
  }

  /// "+": pick (or type) a title first — school/employer name is never
  /// blank — then open the detail page for dates/notes/custom fields.
  Future<void> _addHistoryEntry(HistoryCategory category, String categoryLabel) async {
    final options = await widget.personStore.allHistoryTitles(category);
    if (!mounted) return;
    final title = await Navigator.of(context).push<String>(
      CupertinoPageRoute(builder: (_) => StringPickerScreen(title: categoryLabel, options: options)),
    );
    if (title == null || title.isEmpty) return;
    final entry = PersonHistoryEntry(id: widget.personStore.newId(), personId: _person.id, category: category, title: title);
    await widget.personStore.addHistoryEntry(entry);
    if (!mounted) return;
    await Navigator.of(context).push(
      CupertinoPageRoute(
        builder: (_) => PersonHistoryDetailScreen(entry: entry, categoryLabel: categoryLabel, personStore: widget.personStore),
      ),
    );
    await _reload();
  }

  Future<void> _openHistoryEntry(PersonHistoryEntry entry, String categoryLabel) async {
    await Navigator.of(context).push(
      CupertinoPageRoute(
        builder: (_) => PersonHistoryDetailScreen(entry: entry, categoryLabel: categoryLabel, personStore: widget.personStore),
      ),
    );
    await _reload();
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

  String _relationshipLabel(AppLocalizations l10n, RelationshipType type) => switch (type) {
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
  String _organizationLabel(AppLocalizations l10n, RelationshipType type) => switch (type) {
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
        cancelButton: CupertinoActionSheetAction(onPressed: () => Navigator.of(context).pop(), child: Text(l10n.actionCancel)),
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
    final candidates = _allPeople.where((p) => p.id != _person.id && !linkedIds.contains(p.id)).toList();
    final other = await Navigator.of(context).push<Person>(
      CupertinoPageRoute(builder: (_) => PersonPickerScreen(candidates: candidates, personStore: widget.personStore)),
    );
    if (other == null || !mounted) return;

    final type = await _pickRelationshipType();
    if (type == null) return;

    String? organization;
    if (relationshipNeedsOrganization(type)) {
      final orgOptions = await widget.personStore.allOrganizations();
      if (!mounted) return;
      organization = await Navigator.of(context).push<String>(
        CupertinoPageRoute(
          builder: (_) => StringPickerScreen(
            title: _organizationLabel(l10n, type),
            options: orgOptions,
            initialQuery: existing?.organization ?? '',
          ),
        ),
      );
      if (organization == null) return;
    }

    if (existing != null && existing.relatedPersonId != other.id) {
      await widget.personStore.removeRelationship(_person.id, existing.relatedPersonId);
    }
    await widget.personStore.addRelationship(_person.id, other.id, type, organization: organization);
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
              backgroundColor: _cardBackground,
              decoration: _cardDecoration,
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
                backgroundColor: _cardBackground,
                decoration: _cardDecoration,
                children: [
                  CupertinoTextFormFieldRow(
                    prefix: Text(l10n.personProfileBioLabel),
                    controller: _bio,
                    maxLines: null,
                    onChanged: (v) => _persist(_person.copyWith(bio: v)),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              _sectionHeader(
                l10n.personProfileEducationLabel,
                onAdd: () => _addHistoryEntry(HistoryCategory.education, l10n.personProfileEducationLabel),
              ),
              _historySection(_education, l10n.personProfileEducationLabel),
              const SizedBox(height: 20),
              _sectionHeader(
                l10n.personProfileJobLabel,
                onAdd: () => _addHistoryEntry(HistoryCategory.job, l10n.personProfileJobLabel),
              ),
              _historySection(_jobs, l10n.personProfileJobLabel),
              const SizedBox(height: 20),
              _sectionHeader(l10n.personProfileRelationshipsHeader, onAdd: () => _addOrEditRelationship()),
              for (final type in RelationshipType.values)
                if (_relationships.where((r) => r.type == type).toList() case final group when group.isNotEmpty) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                    child: Text(
                      _relationshipLabel(l10n, type),
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: CupertinoColors.systemGrey),
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
                            _allPeople.where((p) => p.id == relationship.relatedPersonId).map((p) => p.name).firstOrNull ?? '?',
                          ),
                          subtitle: relationship.organization == null || relationship.organization!.isEmpty
                              ? null
                              : Text(relationship.organization!),
                          trailing: CupertinoButton(
                            padding: EdgeInsets.zero,
                            onPressed: () => _removeRelationship(relationship),
                            child: const Icon(CupertinoIcons.xmark_circle, color: CupertinoColors.systemGrey),
                          ),
                          onTap: () => _addOrEditRelationship(existing: relationship),
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
              _sectionHeader(l10n.personProfileLocationHeader, onAdd: () => _editLocation()),
              if (_locations.isNotEmpty)
                CupertinoListSection.insetGrouped(
                  margin: const EdgeInsets.symmetric(horizontal: 16),
                  backgroundColor: _cardBackground,
                  decoration: _cardDecoration,
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

  String? _dateRangeLabel(AppLocalizations l10n, PersonHistoryEntry entry) {
    if (entry.startDate == null && entry.endDate == null) return null;
    final start = entry.startDate == null ? '' : DateFormat.y().format(entry.startDate!);
    final end = entry.endDate == null ? l10n.personHistoryPresentLabel : DateFormat.y().format(entry.endDate!);
    return start.isEmpty ? end : '$start – $end';
  }

  Widget _historySection(List<PersonHistoryEntry> entries, String categoryLabel) {
    if (entries.isEmpty) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context)!;
    return CupertinoListSection.insetGrouped(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      backgroundColor: _cardBackground,
      decoration: _cardDecoration,
      children: [
        for (final entry in entries)
          CupertinoListTile(
            title: Text(entry.title.isEmpty ? l10n.personProfileNotSet : entry.title),
            subtitle: switch (_dateRangeLabel(l10n, entry)) { final label? => Text(label), null => null },
            trailing: const Icon(CupertinoIcons.chevron_forward, size: 18, color: CupertinoColors.systemGrey2),
            onTap: () => _openHistoryEntry(entry, categoryLabel),
          ),
      ],
    );
  }

  Widget _sectionHeader(String title, {VoidCallback? onAdd}) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        if (onAdd != null)
          CupertinoButton(padding: EdgeInsets.zero, onPressed: onAdd, child: const Icon(CupertinoIcons.add_circled)),
      ],
    ),
  );
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
