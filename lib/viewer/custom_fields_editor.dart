import 'package:flutter/cupertino.dart';

import '../l10n/app_localizations.dart';
import '../photos/person.dart';
import 'fold_toggle.dart';
import 'profile_section.dart';
import 'undo_toast.dart';

/// Findable by name rather than by counting, same as the profile's own
/// section headers.
const customFieldsAddKey = ValueKey('more-details-add');

/// The labels a person's fields most often have, offered when adding one.
List<String> suggestedFieldLabels(AppLocalizations l10n) => [
  l10n.profileFieldPhone,
  l10n.profileFieldEmail,
  'WeChat',
  'WhatsApp',
  'Instagram',
  l10n.profileFieldBirthday,
  l10n.profileFieldAddress,
  l10n.profileFieldNickname,
  l10n.profileFieldWebsite,
  'LinkedIn',
];

/// User-defined label/value pairs — "+" adds a row, a swipe left (or the
/// red "−" in Edit) takes one out with Undo. Shared by the profile's
/// top-level fields and each Education/Job entry's own. Calls [onChanged]
/// with the full field list on every edit.
class CustomFieldsEditor extends StatefulWidget {
  const CustomFieldsEditor({
    super.key,
    required this.initialFields,
    required this.onChanged,
    this.underHeader,
    this.showHeader = true,
    this.editing = false,
    this.suggestions = const [],
  });

  /// Sits between this section's title and its label/value pairs. The
  /// profile puts its named fields here, so they are inside the section
  /// rather than floating above its heading.
  final Widget? underHeader;

  final List<PersonCustomField> initialFields;
  final ValueChanged<List<PersonCustomField>> onChanged;

  /// Off where the page draws the header itself and calls
  /// [CustomFieldsEditorState.add] from its "+".
  final bool showHeader;

  /// From the page's Edit, when it draws the header.
  final bool editing;

  /// Offered as a sheet on "+", ones already used left out.
  final List<String> suggestions;

  @override
  State<CustomFieldsEditor> createState() => CustomFieldsEditorState();
}

class CustomFieldsEditorState extends State<CustomFieldsEditor> {
  late List<({TextEditingController label, TextEditingController value})>
  _rows = [
    for (final field in widget.initialFields)
      (
        label: TextEditingController(text: field.label),
        value: TextEditingController(text: field.value),
      ),
  ];

  bool _expanded = false;
  bool _ownEditing = false;
  int _newest = -1;
  final _undo = UndoToast();

  bool get _editing => widget.showHeader ? _ownEditing : widget.editing;

  @override
  void dispose() {
    _undo.dispose();
    for (final row in _rows) {
      row.label.dispose();
      row.value.dispose();
    }
    super.dispose();
  }

  void _emit() {
    widget.onChanged([
      for (final row in _rows)
        PersonCustomField(label: row.label.text, value: row.value.text),
    ]);
  }

  /// A label from the suggestions, or a blank one; nothing on Cancel.
  Future<void> add() async {
    var label = '';
    final used = {for (final r in _rows) r.label.text.trim().toLowerCase()};
    final offered = [
      for (final s in widget.suggestions)
        if (!used.contains(s.toLowerCase())) s,
    ];
    if (offered.isNotEmpty) {
      final l10n = AppLocalizations.of(context)!;
      final picked = await showCupertinoModalPopup<String>(
        context: context,
        builder: (sheet) => CupertinoActionSheet(
          title: Text(l10n.profileFieldPickTitle),
          actions: [
            for (final s in offered)
              CupertinoActionSheetAction(
                onPressed: () => Navigator.of(sheet).pop(s),
                child: Text(s),
              ),
            CupertinoActionSheetAction(
              key: const ValueKey('customFieldOther'),
              onPressed: () => Navigator.of(sheet).pop(''),
              child: Text(l10n.profileFieldOther),
            ),
          ],
          cancelButton: CupertinoActionSheetAction(
            onPressed: () => Navigator.of(sheet).pop(),
            child: Text(l10n.actionCancel),
          ),
        ),
      );
      if (picked == null || !mounted) return;
      label = picked;
    }
    setState(() {
      _rows = [
        ..._rows,
        (
          label: TextEditingController(text: label),
          value: TextEditingController(),
        ),
      ];
      _newest = _rows.length - 1;
      // The new row is last: open the list so it's on screen.
      _expanded = true;
    });
    _emit();
  }

  void _remove(int index) {
    final removed = _rows[index];
    setState(() {
      _rows = [..._rows]..removeAt(index);
      _newest = -1;
    });
    _emit();
    final name = removed.label.text.trim().isEmpty
        ? removed.value.text
        : removed.label.text;
    _undo.show(
      context,
      AppLocalizations.of(context)!.profileRemoved(name),
      () async {
        if (!mounted) return;
        setState(() {
          _rows = [..._rows]..insert(index.clamp(0, _rows.length), removed);
        });
        _emit();
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final folds = _rows.length > foldedCount;
    final shown = folds && !_expanded ? foldedCount : _rows.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.showHeader)
          ProfileSectionHeader(
            title: l10n.customFieldsHeader,
            onAdd: add,
            addKey: customFieldsAddKey,
            editing: _ownEditing,
            onEdit: _rows.isEmpty
                ? null
                : () => setState(() => _ownEditing = !_ownEditing),
          ),
        ?widget.underHeader,
        if (_rows.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              children: [
                for (var i = 0; i < shown; i++)
                  _row(l10n, i, last: i == shown - 1),
              ],
            ),
          ),
        if (folds)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: FoldToggle(
              total: _rows.length,
              expanded: _expanded,
              onPressed: () => setState(() => _expanded = !_expanded),
            ),
          ),
      ],
    );
  }

  Widget _row(AppLocalizations l10n, int i, {required bool last}) {
    final row = _rows[i];
    return ProfileDeletableRow(
      key: ObjectKey(row.label),
      editing: _editing,
      onDelete: () => _remove(i),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: last
            ? null
            : const BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                    color: CupertinoColors.separator,
                    width: 0.5,
                  ),
                ),
              ),
        child: Row(
          children: [
            SizedBox(
              width: 100,
              child: CupertinoTextField.borderless(
                controller: row.label,
                onTapOutside: (_) =>
                    FocusManager.instance.primaryFocus?.unfocus(),
                placeholder: l10n.customFieldsLabelPlaceholder,
                padding: EdgeInsets.zero,
                style: const TextStyle(color: CupertinoColors.systemGrey),
                onChanged: (_) => _emit(),
              ),
            ),
            Expanded(
              child: CupertinoTextField.borderless(
                controller: row.value,
                // Straight into the value of a row just added with a label.
                autofocus: i == _newest && row.label.text.isNotEmpty,
                textAlign: TextAlign.end,
                onTapOutside: (_) =>
                    FocusManager.instance.primaryFocus?.unfocus(),
                placeholder: l10n.customFieldsValuePlaceholder,
                padding: EdgeInsets.zero,
                onChanged: (_) => _emit(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
