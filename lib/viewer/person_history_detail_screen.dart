import 'package:flutter/cupertino.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../photos/person.dart';
import '../photos/person_store.dart';
import 'custom_fields_editor.dart';
import 'search_picker_sheet.dart';

const _cardBackground = Color(0xFF1C1C1E);
const _cardDecoration = BoxDecoration(
  color: Color(0xFF2C2C2E),
  borderRadius: BorderRadius.all(Radius.circular(10)),
);

/// One Education/Job entry's details: rename via the same searchable
/// pick-or-type screen used elsewhere, a start/end time range ("Present"
/// for an open-ended end), free-text notes, a timelined sub-history (roles
/// held / majors earned), projects (with tags), awards, user-defined
/// custom fields, and a delete option. Reached by tapping a row in the
/// profile's Education or Job section. See IMPLEMENTATION_PLAN.md T7.3.
class PersonHistoryDetailScreen extends StatefulWidget {
  const PersonHistoryDetailScreen({
    super.key,
    required this.entry,
    required this.categoryLabel,
    required this.personStore,
  });

  final PersonHistoryEntry entry;
  final String categoryLabel;
  final PersonStore personStore;

  @override
  State<PersonHistoryDetailScreen> createState() =>
      _PersonHistoryDetailScreenState();
}

class _PersonHistoryDetailScreenState extends State<PersonHistoryDetailScreen> {
  late PersonHistoryEntry _entry = widget.entry;
  late final TextEditingController _notes = TextEditingController(
    text: _entry.notes,
  );

  @override
  void dispose() {
    _notes.dispose();
    super.dispose();
  }

  Future<void> _persist(PersonHistoryEntry updated) async {
    setState(() => _entry = updated);
    await widget.personStore.addHistoryEntry(updated);
  }

  Future<void> _pickTitle() async {
    final options = await widget.personStore.allHistoryTitles(_entry.category);
    if (!mounted) return;
    final title = await showSearchPickerSheet(
      context: context,
      title: widget.categoryLabel,
      options: options,
      selected: _entry.title,
    );
    if (title == null || title.isEmpty) return;
    await _persist(_entry.copyWith(title: title));
  }

  Future<void> _pickStartDate() async {
    final l10n = AppLocalizations.of(context)!;
    var date = _entry.startDate ?? DateTime.now();
    final saved = await showCupertinoModalPopup<bool>(
      context: context,
      builder: (context) => CupertinoActionSheet(
        title: Text(l10n.personHistoryStartLabel),
        message: SizedBox(
          height: 180,
          child: CupertinoDatePicker(
            mode: CupertinoDatePickerMode.date,
            initialDateTime: date,
            maximumDate: DateTime.now(),
            minimumYear: 1900,
            onDateTimeChanged: (value) => date = value,
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
    await _persist(_entry.copyWith(startDate: () => date));
  }

  Future<void> _pickEndDate() async {
    final l10n = AppLocalizations.of(context)!;
    var ongoing = _entry.endDate == null;
    var date = _entry.endDate ?? DateTime.now();
    final saved = await showCupertinoModalPopup<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => CupertinoActionSheet(
          title: Text(l10n.personHistoryEndLabel),
          message: Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Column(
              children: [
                CupertinoSlidingSegmentedControl<bool>(
                  groupValue: ongoing,
                  children: {
                    true: Text(l10n.personHistoryPresentLabel),
                    false: Text(l10n.personHistorySpecificDateOption),
                  },
                  onValueChanged: (value) =>
                      setState(() => ongoing = value ?? ongoing),
                ),
                if (!ongoing)
                  SizedBox(
                    height: 180,
                    child: CupertinoDatePicker(
                      mode: CupertinoDatePickerMode.date,
                      initialDateTime: date,
                      maximumDate: DateTime.now(),
                      minimumYear: 1900,
                      onDateTimeChanged: (value) => date = value,
                    ),
                  ),
              ],
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
      ),
    );
    if (saved != true) return;
    await _persist(_entry.copyWith(endDate: () => ongoing ? null : date));
  }

  /// Shared add/edit sheet for both Titles (roles/majors) and Awards — a
  /// title, a description, and a start/"present"-or-end date range.
  Future<void> _editTimelineEntry({
    required List<TimelineEntry> list,
    required ValueChanged<List<TimelineEntry>> onSave,
    TimelineEntry? existing,
  }) async {
    final l10n = AppLocalizations.of(context)!;
    final titleController = TextEditingController(text: existing?.title ?? '');
    final descController = TextEditingController(
      text: existing?.description ?? '',
    );
    var start = existing?.startDate ?? DateTime.now();
    var ongoing = existing != null && existing.endDate == null;
    var end = existing?.endDate ?? DateTime.now();
    final saved = await showCupertinoModalPopup<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => CupertinoActionSheet(
          message: Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Column(
              children: [
                CupertinoTextField(
                  controller: titleController,
                  placeholder: l10n.personHistoryTitlePlaceholder,
                ),
                const SizedBox(height: 8),
                CupertinoTextField(
                  controller: descController,
                  placeholder: l10n.personHistoryDescriptionPlaceholder,
                  maxLines: 2,
                ),
                const SizedBox(height: 8),
                Text(
                  l10n.personHistoryStartLabel,
                  style: const TextStyle(color: CupertinoColors.systemGrey),
                ),
                SizedBox(
                  height: 120,
                  child: CupertinoDatePicker(
                    mode: CupertinoDatePickerMode.date,
                    initialDateTime: start,
                    maximumDate: DateTime.now(),
                    minimumYear: 1900,
                    onDateTimeChanged: (value) => start = value,
                  ),
                ),
                CupertinoSlidingSegmentedControl<bool>(
                  groupValue: ongoing,
                  children: {
                    true: Text(l10n.personHistoryPresentLabel),
                    false: Text(l10n.personHistorySpecificDateOption),
                  },
                  onValueChanged: (value) =>
                      setState(() => ongoing = value ?? ongoing),
                ),
                if (!ongoing)
                  SizedBox(
                    height: 120,
                    child: CupertinoDatePicker(
                      mode: CupertinoDatePickerMode.date,
                      initialDateTime: end,
                      maximumDate: DateTime.now(),
                      minimumYear: 1900,
                      onDateTimeChanged: (value) => end = value,
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            CupertinoActionSheetAction(
              onPressed: () =>
                  Navigator.of(context)
                      .pop(titleController.text.trim().isNotEmpty),
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
    final updatedItem = TimelineEntry(
      id: existing?.id ?? widget.personStore.newId(),
      title: titleController.text.trim(),
      description: descController.text.trim(),
      startDate: start,
      endDate: ongoing ? null : end,
    );
    final newList = existing == null
        ? [...list, updatedItem]
        : [
            for (final item in list)
              item.id == existing.id ? updatedItem : item,
          ];
    onSave(newList);
  }

  Future<void> _editProject({
    required List<CareerProject> list,
    required ValueChanged<List<CareerProject>> onSave,
    CareerProject? existing,
  }) async {
    final l10n = AppLocalizations.of(context)!;
    final nameController = TextEditingController(text: existing?.name ?? '');
    final descController = TextEditingController(
      text: existing?.description ?? '',
    );
    final tagsController = TextEditingController(
      text: existing?.tags.join(', ') ?? '',
    );
    var start = existing?.startDate ?? DateTime.now();
    var ongoing = existing != null && existing.endDate == null;
    var end = existing?.endDate ?? DateTime.now();
    final saved = await showCupertinoModalPopup<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => CupertinoActionSheet(
          message: Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Column(
              children: [
                CupertinoTextField(
                  controller: nameController,
                  placeholder: l10n.careerProjectNamePlaceholder,
                ),
                const SizedBox(height: 8),
                CupertinoTextField(
                  controller: descController,
                  placeholder: l10n.personHistoryDescriptionPlaceholder,
                  maxLines: 2,
                ),
                const SizedBox(height: 8),
                CupertinoTextField(
                  controller: tagsController,
                  placeholder: l10n.careerProjectTagsPlaceholder,
                ),
                const SizedBox(height: 8),
                Text(
                  l10n.personHistoryStartLabel,
                  style: const TextStyle(color: CupertinoColors.systemGrey),
                ),
                SizedBox(
                  height: 120,
                  child: CupertinoDatePicker(
                    mode: CupertinoDatePickerMode.date,
                    initialDateTime: start,
                    maximumDate: DateTime.now(),
                    minimumYear: 1900,
                    onDateTimeChanged: (value) => start = value,
                  ),
                ),
                CupertinoSlidingSegmentedControl<bool>(
                  groupValue: ongoing,
                  children: {
                    true: Text(l10n.personHistoryPresentLabel),
                    false: Text(l10n.personHistorySpecificDateOption),
                  },
                  onValueChanged: (value) =>
                      setState(() => ongoing = value ?? ongoing),
                ),
                if (!ongoing)
                  SizedBox(
                    height: 120,
                    child: CupertinoDatePicker(
                      mode: CupertinoDatePickerMode.date,
                      initialDateTime: end,
                      maximumDate: DateTime.now(),
                      minimumYear: 1900,
                      onDateTimeChanged: (value) => end = value,
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            CupertinoActionSheetAction(
              onPressed: () =>
                  Navigator.of(context)
                      .pop(nameController.text.trim().isNotEmpty),
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
    final tags = tagsController.text
        .split(',')
        .map((t) => t.trim())
        .where((t) => t.isNotEmpty)
        .toList();
    final updatedItem = CareerProject(
      id: existing?.id ?? widget.personStore.newId(),
      name: nameController.text.trim(),
      description: descController.text.trim(),
      tags: tags,
      startDate: start,
      endDate: ongoing ? null : end,
    );
    final newList = existing == null
        ? [...list, updatedItem]
        : [
            for (final item in list)
              item.id == existing.id ? updatedItem : item,
          ];
    onSave(newList);
  }

  String? _dateRangeLabel(
    AppLocalizations l10n,
    DateTime? start,
    DateTime? end, {
    required bool hasEnd,
  }) {
    if (start == null && !hasEnd) return null;
    final startLabel = start == null ? '' : DateFormat.y().format(start);
    final endLabel = end == null
        ? l10n.personHistoryPresentLabel
        : DateFormat.y().format(end);
    return startLabel.isEmpty ? endLabel : '$startLabel – $endLabel';
  }

  Future<void> _confirmDelete() async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showCupertinoDialog<bool>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: Text(l10n.personHistoryDeleteConfirmTitle),
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
    await widget.personStore.removeHistoryEntry(_entry.id);
    if (mounted) Navigator.of(context).pop();
  }

  Widget _sectionHeader(String title, {required VoidCallback onAdd}) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          title,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
        ),
        CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: onAdd,
          child: const Icon(CupertinoIcons.add_circled),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(widget.categoryLabel),
        // Every field here already auto-saves on change — this is just a
        // visible, deliberate "I'm done" affordance so it doesn't feel
        // like edits vanish into thin air.
        trailing: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.detailDoneButton),
        ),
      ),
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: 16),
          children: [
            CupertinoListSection.insetGrouped(
              margin: const EdgeInsets.symmetric(horizontal: 16),
              backgroundColor: _cardBackground,
              decoration: _cardDecoration,
              children: [
                CupertinoListTile(
                  title: Text(
                    _entry.title.isEmpty
                        ? l10n.personProfileNotSet
                        : _entry.title,
                  ),
                  trailing: const Icon(
                    CupertinoIcons.chevron_forward,
                    size: 18,
                    color: CupertinoColors.systemGrey2,
                  ),
                  onTap: _pickTitle,
                ),
                CupertinoListTile(
                  title: Text(l10n.personHistoryStartLabel),
                  trailing: Text(
                    _entry.startDate == null
                        ? l10n.personProfileNotSet
                        : DateFormat.yMMM().format(_entry.startDate!),
                    style: const TextStyle(color: CupertinoColors.systemGrey),
                  ),
                  onTap: _pickStartDate,
                ),
                CupertinoListTile(
                  title: Text(l10n.personHistoryEndLabel),
                  trailing: Text(
                    _entry.endDate == null
                        ? l10n.personHistoryPresentLabel
                        : DateFormat.yMMM().format(_entry.endDate!),
                    style: const TextStyle(color: CupertinoColors.systemGrey),
                  ),
                  onTap: _pickEndDate,
                ),
              ],
            ),
            const SizedBox(height: 20),
            CupertinoFormSection.insetGrouped(
              margin: const EdgeInsets.symmetric(horizontal: 16),
              backgroundColor: _cardBackground,
              decoration: _cardDecoration,
              children: [
                CupertinoTextFormFieldRow(
                  prefix: Text(l10n.personHistoryNotesLabel),
                  controller: _notes,
                  maxLines: null,
                  onChanged: (v) => _persist(_entry.copyWith(notes: v)),
                ),
              ],
            ),
            const SizedBox(height: 20),
            _sectionHeader(
              _entry.category == HistoryCategory.job
                  ? l10n.personHistoryTitlesHeaderJob
                  : l10n.personHistoryTitlesHeaderEducation,
              onAdd: () => _editTimelineEntry(
                list: _entry.titles,
                onSave: (list) => _persist(_entry.copyWith(titles: list)),
              ),
            ),
            if (_entry.titles.isNotEmpty)
              CupertinoListSection.insetGrouped(
                margin: const EdgeInsets.symmetric(horizontal: 16),
                backgroundColor: _cardBackground,
                decoration: _cardDecoration,
                children: [
                  for (final item in _entry.titles)
                    CupertinoListTile(
                      title: Text(item.title),
                      subtitle: switch (_dateRangeLabel(
                        l10n,
                        item.startDate,
                        item.endDate,
                        hasEnd: true,
                      )) {
                        final label? => Text(label),
                        null => null,
                      },
                      trailing: CupertinoButton(
                        padding: EdgeInsets.zero,
                        onPressed: () => _persist(
                          _entry.copyWith(
                            titles: _entry.titles
                                .where((t) => t.id != item.id)
                                .toList(),
                          ),
                        ),
                        child: const Icon(
                          CupertinoIcons.xmark_circle,
                          color: CupertinoColors.systemGrey,
                        ),
                      ),
                      onTap: () => _editTimelineEntry(
                        list: _entry.titles,
                        onSave: (list) =>
                            _persist(_entry.copyWith(titles: list)),
                        existing: item,
                      ),
                    ),
                ],
              ),
            const SizedBox(height: 20),
            _sectionHeader(
              l10n.personHistoryProjectsHeader,
              onAdd: () => _editProject(
                list: _entry.projects,
                onSave: (list) => _persist(_entry.copyWith(projects: list)),
              ),
            ),
            if (_entry.projects.isNotEmpty)
              CupertinoListSection.insetGrouped(
                margin: const EdgeInsets.symmetric(horizontal: 16),
                backgroundColor: _cardBackground,
                decoration: _cardDecoration,
                children: [
                  for (final project in _entry.projects)
                    CupertinoListTile(
                      title: Text(project.name),
                      subtitle: project.tags.isEmpty
                          ? null
                          : Text(project.tags.join(' · ')),
                      trailing: CupertinoButton(
                        padding: EdgeInsets.zero,
                        onPressed: () => _persist(
                          _entry.copyWith(
                            projects: _entry.projects
                                .where((p) => p.id != project.id)
                                .toList(),
                          ),
                        ),
                        child: const Icon(
                          CupertinoIcons.xmark_circle,
                          color: CupertinoColors.systemGrey,
                        ),
                      ),
                      onTap: () => _editProject(
                        list: _entry.projects,
                        onSave: (list) =>
                            _persist(_entry.copyWith(projects: list)),
                        existing: project,
                      ),
                    ),
                ],
              ),
            const SizedBox(height: 20),
            _sectionHeader(
              l10n.personHistoryAwardsHeader,
              onAdd: () => _editTimelineEntry(
                list: _entry.awards,
                onSave: (list) => _persist(_entry.copyWith(awards: list)),
              ),
            ),
            if (_entry.awards.isNotEmpty)
              CupertinoListSection.insetGrouped(
                margin: const EdgeInsets.symmetric(horizontal: 16),
                backgroundColor: _cardBackground,
                decoration: _cardDecoration,
                children: [
                  for (final award in _entry.awards)
                    CupertinoListTile(
                      title: Text(award.title),
                      subtitle: switch (_dateRangeLabel(
                        l10n,
                        award.startDate,
                        award.endDate,
                        hasEnd: true,
                      )) {
                        final label? => Text(label),
                        null => null,
                      },
                      trailing: CupertinoButton(
                        padding: EdgeInsets.zero,
                        onPressed: () => _persist(
                          _entry.copyWith(
                            awards: _entry.awards
                                .where((a) => a.id != award.id)
                                .toList(),
                          ),
                        ),
                        child: const Icon(
                          CupertinoIcons.xmark_circle,
                          color: CupertinoColors.systemGrey,
                        ),
                      ),
                      onTap: () => _editTimelineEntry(
                        list: _entry.awards,
                        onSave: (list) =>
                            _persist(_entry.copyWith(awards: list)),
                        existing: award,
                      ),
                    ),
                ],
              ),
            const SizedBox(height: 20),
            CustomFieldsEditor(
              initialFields: _entry.customFields,
              onChanged: (fields) =>
                  _persist(_entry.copyWith(customFields: fields)),
            ),
            const SizedBox(height: 32),
            Center(
              child: CupertinoButton(
                onPressed: _confirmDelete,
                child: Text(
                  l10n.personHistoryDeleteButton,
                  style: const TextStyle(color: CupertinoColors.systemRed),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
