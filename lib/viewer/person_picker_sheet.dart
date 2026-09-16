import 'package:flutter/cupertino.dart';

import '../l10n/app_localizations.dart';
import '../photos/person.dart';
import '../photos/person_store.dart';
import 'search_picker_sheet.dart';

/// Searchable person drop-down — search [candidates] by name, or
/// "New Person…" to create one on the spot (no photo required). Returns the
/// chosen/created [Person], or `null` if dismissed.
Future<Person?> showPersonPickerSheet({
  required BuildContext context,
  required List<Person> candidates,
  required PersonStore personStore,
  String? title,
}) {
  final l10n = AppLocalizations.of(context)!;
  return showSearchPickerSheetOf<Person>(
    context: context,
    title: title ?? l10n.relationshipPickerTitle,
    options: candidates,
    labelOf: (p) => p.name,
    createLabel: (_) => l10n.personProfileNewPersonOption,
    onCreate: (query) => _createPerson(context, personStore, query),
  );
}

Future<Person?> _createPerson(
  BuildContext context,
  PersonStore store,
  String query,
) async {
  final l10n = AppLocalizations.of(context)!;
  final nameController = TextEditingController(text: query);
  final name = await showCupertinoDialog<String>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => CupertinoAlertDialog(
        title: Text(l10n.peopleNamePromptTitle),
        content: Padding(
          padding: const EdgeInsets.only(top: 12),
          child: CupertinoTextField(
            controller: nameController,
            autofocus: true,
            onChanged: (_) => setState(() {}),
          ),
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l10n.actionCancel),
          ),
          CupertinoDialogAction(
            onPressed: nameController.text.trim().isEmpty
                ? null
                : () => Navigator.of(context).pop(nameController.text.trim()),
            child: Text(l10n.actionAdd),
          ),
        ],
      ),
    ),
  );
  nameController.dispose();
  if (name == null || name.isEmpty) return null;
  return store.create(name: name);
}
