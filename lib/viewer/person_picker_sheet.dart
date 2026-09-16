import 'package:flutter/cupertino.dart';

import '../l10n/app_localizations.dart';
import '../photos/person.dart';
import '../photos/person_store.dart';
import 'search_picker_sheet.dart';

/// Searchable person drop-down — search [candidates] by name, or create one
/// on the spot (no photo required). Returns the chosen/created [Person], or
/// `null` if dismissed.
///
/// Typing a name and tapping the create row *is* the creation: the name is
/// already typed, so asking for it again in a dialog was one extra screen
/// and two extra taps to confirm something the user had just said. The
/// prompt only survives for the case it's actually needed — tapping create
/// with nothing typed.
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
    createLabel: (query) => query.trim().isEmpty
        ? l10n.personProfileNewPersonOption
        : l10n.personPickerNewNamed(query.trim()),
    onCreate: (query) => query.trim().isEmpty
        ? _promptForName(context, personStore)
        : personStore.create(name: query.trim()),
  );
}

/// Only for "New Person…" tapped with an empty search field — there's no
/// name to work from, so this is the one place one has to be asked for.
Future<Person?> _promptForName(BuildContext context, PersonStore store) async {
  final l10n = AppLocalizations.of(context)!;
  final nameController = TextEditingController();
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
