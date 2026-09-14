import 'package:flutter/cupertino.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../photos/person.dart';
import '../photos/person_store.dart';
import 'string_picker_screen.dart';

/// One Education/Job entry's details: rename via the same searchable
/// pick-or-type screen used elsewhere, a start/end time range ("Present"
/// for an open-ended end), free-text notes, user-defined custom fields, and
/// a delete option. Reached by tapping a row in the profile's Education or
/// Job section. See IMPLEMENTATION_PLAN.md T7.3.
class PersonHistoryDetailScreen extends StatefulWidget {
  const PersonHistoryDetailScreen({super.key, required this.entry, required this.categoryLabel, required this.personStore});

  final PersonHistoryEntry entry;
  final String categoryLabel;
  final PersonStore personStore;

  @override
  State<PersonHistoryDetailScreen> createState() => _PersonHistoryDetailScreenState();
}

class _PersonHistoryDetailScreenState extends State<PersonHistoryDetailScreen> {
  late PersonHistoryEntry _entry = widget.entry;
  late final TextEditingController _notes = TextEditingController(text: _entry.notes);
  late List<({TextEditingController label, TextEditingController value})> _fieldControllers = _controllersFor(
    _entry.customFields,
  );
  bool _deleted = false;

  List<({TextEditingController label, TextEditingController value})> _controllersFor(List<PersonCustomField> fields) => [
    for (final field in fields) (label: TextEditingController(text: field.label), value: TextEditingController(text: field.value)),
  ];

  @override
  void dispose() {
    _notes.dispose();
    for (final pair in _fieldControllers) {
      pair.label.dispose();
      pair.value.dispose();
    }
    super.dispose();
  }

  Future<void> _persist(PersonHistoryEntry updated) async {
    setState(() => _entry = updated);
    await widget.personStore.addHistoryEntry(updated);
  }

  Future<void> _pickTitle() async {
    final options = await widget.personStore.allHistoryTitles(_entry.category);
    if (!mounted) return;
    final title = await Navigator.of(context).push<String>(
      CupertinoPageRoute(
        builder: (_) => StringPickerScreen(title: widget.categoryLabel, options: options, initialQuery: _entry.title),
      ),
    );
    if (title == null) return;
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
          CupertinoActionSheetAction(onPressed: () => Navigator.of(context).pop(true), child: Text(l10n.settingsSaveButton)),
        ],
        cancelButton: CupertinoActionSheetAction(onPressed: () => Navigator.of(context).pop(false), child: Text(l10n.actionCancel)),
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
                  children: {true: Text(l10n.personHistoryPresentLabel), false: Text(l10n.personHistorySpecificDateOption)},
                  onValueChanged: (value) => setState(() => ongoing = value ?? ongoing),
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
            CupertinoActionSheetAction(onPressed: () => Navigator.of(context).pop(true), child: Text(l10n.settingsSaveButton)),
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

  void _addCustomField() {
    setState(() {
      _fieldControllers = [..._fieldControllers, (label: TextEditingController(), value: TextEditingController())];
    });
    _persistCustomFields();
  }

  void _removeCustomField(int index) {
    final removed = _fieldControllers[index];
    setState(() => _fieldControllers = [..._fieldControllers]..removeAt(index));
    removed.label.dispose();
    removed.value.dispose();
    _persistCustomFields();
  }

  void _persistCustomFields() {
    final fields = [
      for (final pair in _fieldControllers) PersonCustomField(label: pair.label.text, value: pair.value.text),
    ];
    _persist(_entry.copyWith(customFields: fields));
  }

  Future<void> _confirmDelete() async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showCupertinoDialog<bool>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: Text(l10n.personHistoryDeleteConfirmTitle),
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
    await widget.personStore.removeHistoryEntry(_entry.id);
    _deleted = true;
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return PopScope(
      onPopInvokedWithResult: (didPop, result) {
        if (didPop && !_deleted) _persistCustomFields();
      },
      child: CupertinoPageScaffold(
        navigationBar: CupertinoNavigationBar(middle: Text(widget.categoryLabel)),
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: 16),
            children: [
              CupertinoListSection.insetGrouped(
                margin: const EdgeInsets.symmetric(horizontal: 16),
                backgroundColor: const Color(0xFF1C1C1E),
                decoration: const BoxDecoration(color: Color(0xFF2C2C2E), borderRadius: BorderRadius.all(Radius.circular(10))),
                children: [
                  CupertinoListTile(
                    title: Text(_entry.title.isEmpty ? l10n.personProfileNotSet : _entry.title),
                    trailing: const Icon(CupertinoIcons.chevron_forward, size: 18, color: CupertinoColors.systemGrey2),
                    onTap: _pickTitle,
                  ),
                  CupertinoListTile(
                    title: Text(l10n.personHistoryStartLabel),
                    trailing: Text(
                      _entry.startDate == null ? l10n.personProfileNotSet : DateFormat.yMMM().format(_entry.startDate!),
                      style: const TextStyle(color: CupertinoColors.systemGrey),
                    ),
                    onTap: _pickStartDate,
                  ),
                  CupertinoListTile(
                    title: Text(l10n.personHistoryEndLabel),
                    trailing: Text(
                      _entry.endDate == null ? l10n.personHistoryPresentLabel : DateFormat.yMMM().format(_entry.endDate!),
                      style: const TextStyle(color: CupertinoColors.systemGrey),
                    ),
                    onTap: _pickEndDate,
                  ),
                ],
              ),
              const SizedBox(height: 20),
              CupertinoFormSection.insetGrouped(
                margin: const EdgeInsets.symmetric(horizontal: 16),
                backgroundColor: const Color(0xFF1C1C1E),
                decoration: const BoxDecoration(color: Color(0xFF2C2C2E), borderRadius: BorderRadius.all(Radius.circular(10))),
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
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      l10n.personHistoryCustomFieldsHeader,
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                    ),
                    CupertinoButton(padding: EdgeInsets.zero, onPressed: _addCustomField, child: const Icon(CupertinoIcons.add_circled)),
                  ],
                ),
              ),
              if (_fieldControllers.isNotEmpty)
                CupertinoListSection.insetGrouped(
                  margin: const EdgeInsets.symmetric(horizontal: 16),
                  backgroundColor: const Color(0xFF1C1C1E),
                  decoration: const BoxDecoration(color: Color(0xFF2C2C2E), borderRadius: BorderRadius.all(Radius.circular(10))),
                  children: [
                    for (var i = 0; i < _fieldControllers.length; i++)
                      CupertinoListTile(
                        title: CupertinoTextField.borderless(
                          controller: _fieldControllers[i].label,
                          placeholder: l10n.personHistoryFieldLabelPlaceholder,
                          onChanged: (_) => _persistCustomFields(),
                        ),
                        subtitle: CupertinoTextField.borderless(
                          controller: _fieldControllers[i].value,
                          placeholder: l10n.personHistoryFieldValuePlaceholder,
                          onChanged: (_) => _persistCustomFields(),
                        ),
                        trailing: CupertinoButton(
                          padding: EdgeInsets.zero,
                          onPressed: () => _removeCustomField(i),
                          child: const Icon(CupertinoIcons.xmark_circle, color: CupertinoColors.systemGrey),
                        ),
                      ),
                  ],
                ),
              const SizedBox(height: 32),
              Center(
                child: CupertinoButton(
                  onPressed: _confirmDelete,
                  child: Text(l10n.personHistoryDeleteButton, style: const TextStyle(color: CupertinoColors.systemRed)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
