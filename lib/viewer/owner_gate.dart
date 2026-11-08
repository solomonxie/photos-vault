import 'package:flutter/cupertino.dart';

import '../l10n/app_localizations.dart';
import '../photos/person.dart';
import '../photos/person_owner.dart';
import '../photos/person_store.dart';
import '../storage/asset_record_store.dart';
import 'person_picker_sheet.dart';

/// Who is me, picked from everyone (or typed as someone new) and saved.
/// The one picker for Settings' Me row and for the first Hidden opened.
/// Null when dismissed; the choice already made stands.
Future<Person?> pickOwner(
  BuildContext context, {
  required AssetRecordStore store,
  required PersonStore people,
}) async {
  final l10n = AppLocalizations.of(context)!;
  final owner = PersonOwner(store);
  final current = await owner.id();
  final candidates = [
    for (final p in await people.listAll())
      if (!p.locked && !p.ignored) p,
  ];
  if (!context.mounted) return null;
  final picked = await showPersonPickerSheet(
    context: context,
    candidates: candidates,
    personStore: people,
    title: l10n.ownerPickTitle,
    ownerId: current,
  );
  if (picked == null) return null;
  await owner.set(picked.id);
  return picked;
}

/// The owner's id, asking who that is first when nobody is set yet, or
/// the one set has since been deleted. Null when the picker is dismissed.
Future<String?> ensureOwner(
  BuildContext context, {
  required AssetRecordStore store,
  required PersonStore people,
}) async {
  final id = await PersonOwner(store).id();
  if (id != null && await people.getById(id) != null) return id;
  if (!context.mounted) return null;
  return (await pickOwner(context, store: store, people: people))?.id;
}
