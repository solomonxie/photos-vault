import 'package:flutter/cupertino.dart';

import '../l10n/app_localizations.dart';
import '../photos/face_identity.dart';
import '../photos/person.dart';
import '../photos/person_store.dart';
import '../storage/asset_record_store.dart';
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
  );
}

/// Answers the "who's this?" a face card asks: pick somebody already known
/// or type a name to make them, then link [face]'s photo to them.
///
/// The face that was tapped becomes their picture, not the photo it came
/// out of — a group shot would otherwise give everyone in it the same
/// avatar, and whoever stood centre-frame would become the face of all of
/// them. Only when they haven't got one already, same as linking any photo.
///
/// Returns whoever was picked, or `null` if the sheet was dismissed.
/// [identity] and [assetRecordStore], where given, also remember what this
/// face looks like — which is the whole of how the *next* photo of them
/// gets guessed. Optional: the link is made either way, and a missed
/// descriptor costs a future suggestion, not this answer.
Future<Person?> nameFace({
  required BuildContext context,
  required PersonStore personStore,
  required UnnamedFace face,
  FaceIdentityService? identity,
  AssetRecordStore? assetRecordStore,
}) async {
  final l10n = AppLocalizations.of(context)!;
  final tagged = (await personStore.peopleFor(face.localId))
      .map((p) => p.id)
      .toSet();
  final candidates = (await personStore.listAll())
      .where((p) => !tagged.contains(p.id))
      .toList();
  if (!context.mounted) return null;
  final picked = await showPersonPickerSheet(
    context: context,
    candidates: candidates,
    personStore: personStore,
    title: l10n.peopleUnnamedFace,
  );
  if (picked == null) return null;
  await personStore.addAssets(picked.id, [face.localId]);
  final latest = await personStore.getById(picked.id);
  if (latest != null && latest.avatarFace == null) {
    await personStore.update(
      latest.copyWith(avatarLocalId: face.localId, avatarFace: () => face.face),
    );
  }
  return picked;
}
