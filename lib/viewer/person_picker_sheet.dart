import 'package:flutter/cupertino.dart';

import '../l10n/app_localizations.dart';
import '../photos/person.dart';
import '../photos/person_store.dart';
import 'search_picker_sheet.dart';

/// Searchable person drop-down — search [candidates] by name, or create one
/// on the spot (no photo required). Returns the chosen/created [Person], or
/// `null` if dismissed.
///
/// Typing a name *is* the creation: the name is already in the field, so
/// the create row carries it and one tap — or the keyboard's Done key —
/// makes the person. Nothing asks for it a second time; a dialog on top of
/// a name already typed was two taps to confirm something the user had just
/// said. With the field still empty there's no name to work from, so
/// there's nothing to offer yet either: the row waits until there is.
Future<Person?> showPersonPickerSheet({
  required BuildContext context,
  required List<Person> candidates,
  required PersonStore personStore,
  String? title,

  /// Whose phone this is, if it is known. They go to the top and are marked,
  /// because "who is this person to me" is the commonest link anybody draws
  /// and nobody should have to remember which name in the list is their own.
  String? ownerId,
  bool autofocus = true,
  String? initialQuery,
}) {
  final l10n = AppLocalizations.of(context)!;
  final ordered = ownerId == null
      ? candidates
      : [
          for (final p in candidates)
            if (p.id == ownerId) p,
          for (final p in candidates)
            if (p.id != ownerId) p,
        ];
  return showSearchPickerSheetOf<Person>(
    context: context,
    title: title ?? l10n.relationshipPickerTitle,
    options: ordered,
    labelOf: (p) =>
        p.id == ownerId ? '${l10n.ownerPickerMe} · ${p.name}' : p.name,
    emptyHint: l10n.personPickerTypeToCreate,
    createLabel: (query) =>
        query.isEmpty ? null : l10n.personPickerNewNamed(query),
    onCreate: (query) => personStore.create(name: query),
    autofocus: autofocus,
    initialQuery: initialQuery,
  );
}
