import 'package:flutter/cupertino.dart';

import '../l10n/app_localizations.dart';
import '../photos/person.dart';

/// User-defined label/value pairs — a "+" next to the header adds a blank
/// row; each row renders like any other form field (not a bold list title),
/// with its own delete button. Shared by the profile's top-level custom
/// fields and each Education/Job entry's own. Calls [onChanged] with the
/// full field list on every edit.
class CustomFieldsEditor extends StatefulWidget {
  const CustomFieldsEditor({
    super.key,
    required this.initialFields,
    required this.onChanged,
  });

  final List<PersonCustomField> initialFields;
  final ValueChanged<List<PersonCustomField>> onChanged;

  @override
  State<CustomFieldsEditor> createState() => _CustomFieldsEditorState();
}

class _CustomFieldsEditorState extends State<CustomFieldsEditor> {
  late List<({TextEditingController label, TextEditingController value})>
  _rows = [
    for (final field in widget.initialFields)
      (
        label: TextEditingController(text: field.label),
        value: TextEditingController(text: field.value),
      ),
  ];

  @override
  void dispose() {
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

  void _add() {
    setState(
      () => _rows = [
        ..._rows,
        (label: TextEditingController(), value: TextEditingController()),
      ],
    );
    _emit();
  }

  void _remove(int index) {
    final removed = _rows[index];
    setState(() => _rows = [..._rows]..removeAt(index));
    removed.label.dispose();
    removed.value.dispose();
    _emit();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                l10n.customFieldsHeader,
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
              CupertinoButton(
                padding: EdgeInsets.zero,
                onPressed: _add,
                child: const Icon(CupertinoIcons.add_circled),
              ),
            ],
          ),
        ),
        if (_rows.isNotEmpty)
          CupertinoFormSection.insetGrouped(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            backgroundColor: const Color(0xFF1C1C1E),
            decoration: const BoxDecoration(
              color: Color(0xFF2C2C2E),
              borderRadius: BorderRadius.all(Radius.circular(10)),
            ),
            children: [
              for (var i = 0; i < _rows.length; i++)
                CupertinoFormRow(
                  prefix: SizedBox(
                    width: 90,
                    child: CupertinoTextField.borderless(
                      controller: _rows[i].label,
                      placeholder: l10n.customFieldsLabelPlaceholder,
                      onChanged: (_) => _emit(),
                    ),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: CupertinoTextField.borderless(
                          controller: _rows[i].value,
                          textAlign: TextAlign.end,
                          placeholder: l10n.customFieldsValuePlaceholder,
                          onChanged: (_) => _emit(),
                        ),
                      ),
                      CupertinoButton(
                        padding: EdgeInsets.zero,
                        onPressed: () => _remove(i),
                        child: const Icon(
                          CupertinoIcons.xmark_circle,
                          size: 20,
                          color: CupertinoColors.systemGrey,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
      ],
    );
  }
}
