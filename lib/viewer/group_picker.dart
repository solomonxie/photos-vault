import 'package:flutter/cupertino.dart';

import '../l10n/app_localizations.dart';
import '../photos/person.dart';
import '../photos/person_store.dart';
import 'search_picker_sheet.dart';

/// Puts [personIds] in an existing group, or a new one typed in the
/// search field. The group, or null if dismissed.
Future<PersonGroup?> addPeopleToGroup(
  BuildContext context, {
  required PersonStore personStore,
  required Iterable<PersonGroup> groups,
  required Iterable<String> personIds,
}) async {
  final l10n = AppLocalizations.of(context)!;
  final sorted = groups.toList()
    ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  final group = await showSearchPickerSheetOf<PersonGroup>(
    context: context,
    title: l10n.peopleBatchAddToGroup,
    options: sorted,
    labelOf: (g) => g.name,
    autofocus: false,
    createLabel: (query) =>
        query.trim().isEmpty ||
            sorted.any((g) => g.name.toLowerCase() == query.toLowerCase())
        ? null
        : l10n.groupPickerNewNamed(query.trim()),
    onCreate: (query) async => PersonGroup(
      id: personStore.newId(),
      name: query.trim(),
      kind: GroupKind.circle,
    ),
  );
  if (group == null) return null;
  for (final id in personIds) {
    await personStore.joinGroup(id, group, scope: PersonScope.open);
  }
  return group;
}
