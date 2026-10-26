import 'package:flutter/cupertino.dart';

import '../l10n/app_localizations.dart';
import '../photos/merge_suggestions.dart';
import '../photos/person.dart';
import '../photos/profile_transfer.dart';
import 'search_picker_sheet.dart';

/// Who an import row might be: people with its name, or failing that a
/// similar one — one name inside the other ("Mia" and "Mia Chen"), or
/// sounding or spelt nearly alike ("Katherine", "晓明" for "Xiao Ming").
/// Closest first.
List<Person> importCandidates(String name, List<Person> people) {
  final key = name.trim().toLowerCase();
  final same = [
    for (final p in people)
      if (p.name.trim().toLowerCase() == key) p,
  ];
  if (same.isNotEmpty) return same;
  // Closest first: the name nearest in length to this one.
  int gap(Person p) => (p.name.trim().length - key.length).abs();
  final inside = [
    for (final p in people)
      if (MergeSuggestion.alike(p.name, name)) p,
  ];
  final order = {for (final (i, p) in inside.indexed) p.id: i};
  inside.sort(
    (a, b) => gap(a) != gap(b)
        ? gap(a).compareTo(gap(b))
        : order[a.id]!.compareTo(order[b.id]!),
  );
  final ids = {for (final p in inside) p.id};
  return [
    ...inside,
    for (final p in MergeSuggestion.soundingLike(name, people))
      if (!ids.contains(p.id)) p,
  ];
}

/// What was decided for a row: merge into someone, a new person, or a
/// new name to look up again.
sealed class ImportNameChoice {
  const ImportNameChoice();
}

class ImportMerge extends ImportNameChoice {
  const ImportMerge(this.personId);
  final String personId;
}

class ImportAsNew extends ImportNameChoice {
  const ImportAsNew();
}

class ImportRename extends ImportNameChoice {
  const ImportRename(this.name);
  final String name;
}

/// Merge into one of [candidates], add as new (when [allowNew]), or type
/// another name. Null if dismissed.
Future<ImportNameChoice?> chooseImportName(
  BuildContext context, {
  required String name,
  required List<Person> candidates,
  bool allowNew = true,
  List<Person> everyone = const [],
}) async {
  final l10n = AppLocalizations.of(context)!;
  final same = candidates.any(
    (p) => p.name.trim().toLowerCase() == name.trim().toLowerCase(),
  );
  final choice = await showCupertinoModalPopup<Object>(
    context: context,
    builder: (sheet) => CupertinoActionSheet(
      title: Text(
        candidates.isEmpty
            ? name
            : same
            ? l10n.profileCsvSameNameTitle(name)
            : l10n.profileCsvSimilarTitle(name),
      ),
      message: candidates.isEmpty ? null : Text(l10n.profileCsvSimilarBody),
      actions: [
        for (final (i, person) in candidates.indexed)
          CupertinoActionSheetAction(
            key: ValueKey('importMergeInto-$i'),
            onPressed: () => Navigator.of(sheet).pop(ImportMerge(person.id)),
            child: Text(l10n.profileCsvMergeInto(person.name)),
          ),
        if (allowNew)
          CupertinoActionSheetAction(
            key: const ValueKey('importAsNew'),
            onPressed: () => Navigator.of(sheet).pop(const ImportAsNew()),
            child: Text(l10n.importAddNamed(name)),
          ),
        CupertinoActionSheetAction(
          key: const ValueKey('importRename'),
          onPressed: () => Navigator.of(sheet).pop('rename'),
          child: Text(l10n.importRename),
        ),
      ],
      cancelButton: CupertinoActionSheetAction(
        onPressed: () => Navigator.of(sheet).pop(),
        child: Text(l10n.actionCancel),
      ),
    ),
  );
  if (choice is ImportNameChoice) return choice;
  if (choice != 'rename' || !context.mounted) return null;
  if (everyone.isNotEmpty) {
    return _searchEveryone(context, name, everyone, allowNew: allowNew);
  }
  final controller = TextEditingController(text: name);
  final renamed = await showCupertinoDialog<String>(
    context: context,
    builder: (dialog) => CupertinoAlertDialog(
      title: Text(l10n.importRenameTitle),
      content: Padding(
        padding: const EdgeInsets.only(top: 8),
        child: CupertinoTextField(
          key: const ValueKey('importRenameField'),
          controller: controller,
          autofocus: true,
          onSubmitted: (v) => Navigator.of(dialog).pop(v),
        ),
      ),
      actions: [
        CupertinoDialogAction(
          onPressed: () => Navigator.of(dialog).pop(),
          child: Text(l10n.actionCancel),
        ),
        CupertinoDialogAction(
          key: const ValueKey('importRenameSave'),
          isDefaultAction: true,
          onPressed: () => Navigator.of(dialog).pop(controller.text),
          child: Text(l10n.actionOk),
        ),
      ],
    ),
  );
  controller.dispose();
  final trimmed = renamed?.trim() ?? '';
  if (trimmed.isEmpty || trimmed == name) return null;
  return ImportRename(trimmed);
}

/// A row's decision as the writer takes it.
PersonTarget? targetOf(ImportNameChoice? choice) => switch (choice) {
  ImportMerge(:final personId) => PersonTarget(personId),
  ImportAsNew() => const PersonTarget.newPerson(),
  _ => null,
};

/// "Change Name…" as a search over everyone in People: pick one to merge
/// into, or — where new people may be made — type a name nobody has.
Future<ImportNameChoice?> _searchEveryone(
  BuildContext context,
  String name,
  List<Person> everyone, {
  required bool allowNew,
}) async {
  final l10n = AppLocalizations.of(context)!;
  final sorted = [...everyone]
    ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  bool taken(String q) =>
      sorted.any((p) => p.name.trim().toLowerCase() == q.trim().toLowerCase());
  final picked = await showSearchPickerSheetOf<Person>(
    context: context,
    title: l10n.importRenameTitle,
    options: sorted,
    labelOf: (p) => p.name,
    createLabel: allowNew
        ? (q) => q.trim().isEmpty || taken(q)
              ? null
              : l10n.personPickerNewNamed(q.trim())
        : null,
    // Not made here: the import makes them, under this name.
    onCreate: allowNew
        ? (q) async => Person(
            id: '',
            name: q.trim(),
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          )
        : null,
    emptyHint: l10n.importRenameHint,
  );
  if (picked == null) return null;
  if (picked.id.isEmpty) {
    return picked.name == name ? null : ImportRename(picked.name);
  }
  return ImportMerge(picked.id);
}
