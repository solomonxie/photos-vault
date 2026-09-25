import 'package:flutter/cupertino.dart';

import '../l10n/app_localizations.dart';
import '../photos/person.dart';

/// Findable by name rather than by counting, same as the profile's own
/// section headers.
const customFieldsAddKey = ValueKey('more-details-add');

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
                key: customFieldsAddKey,
                padding: EdgeInsets.zero,
                onPressed: _add,
                child: const Icon(CupertinoIcons.add_circled),
              ),
            ],
          ),
        ),
        if (_rows.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              children: [
                for (var i = 0; i < _rows.length; i++)
                  Container(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    decoration: i == _rows.length - 1
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
                            controller: _rows[i].label,
                            onTapOutside: (_) =>
                                FocusManager.instance.primaryFocus?.unfocus(),
                            placeholder: l10n.customFieldsLabelPlaceholder,
                            padding: EdgeInsets.zero,
                            style: const TextStyle(
                              color: CupertinoColors.systemGrey,
                            ),
                            onChanged: (_) => _emit(),
                          ),
                        ),
                        Expanded(
                          child: CupertinoTextField.borderless(
                            controller: _rows[i].value,
                            textAlign: TextAlign.end,
                            onTapOutside: (_) =>
                                FocusManager.instance.primaryFocus?.unfocus(),
                            placeholder: l10n.customFieldsValuePlaceholder,
                            padding: EdgeInsets.zero,
                            onChanged: (_) => _emit(),
                          ),
                        ),
                        CupertinoButton(
                          padding: const EdgeInsetsDirectional.only(start: 8),
                          onPressed: () => _remove(i),
                          child: const Icon(
                            CupertinoIcons.xmark_circle,
                            size: 18,
                            color: CupertinoColors.systemGrey,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}
