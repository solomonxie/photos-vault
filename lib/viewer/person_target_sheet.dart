import 'package:flutter/cupertino.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../photos/person.dart';
import '../photos/person_store.dart';
import '../photos/profile_transfer.dart';

/// "[name] is more than one person here — which?" Each candidate is told
/// apart by what is known of them: birthday, photo count, when added.
/// Null if dismissed.
Future<PersonTarget?> pickPersonTarget(
  BuildContext context, {
  required String name,
  required List<Person> candidates,
  required PersonStore personStore,
}) async {
  final members = await personStore.allMemberships();
  // The open set only: a birthday behind a lock stays there.
  final details = await personStore.openDetails();
  if (!context.mounted) return null;
  final l10n = AppLocalizations.of(context)!;
  final day = DateFormat.yMMMd(Localizations.localeOf(context).toLanguageTag());
  String describe(Person person) => [
    if (details[person.id]?.birthDate case final born?)
      l10n.personMatchBorn(day.format(born)),
    l10n.personMatchPhotos(members[person.id]?.length ?? 0),
    l10n.personMatchAdded(day.format(person.createdAt)),
  ].join(' · ');
  return showCupertinoModalPopup<PersonTarget>(
    context: context,
    builder: (sheet) => CupertinoActionSheet(
      title: Text(l10n.personMatchTitle(name)),
      message: Text(l10n.personMatchBody),
      actions: [
        for (final (i, person) in candidates.indexed)
          CupertinoActionSheetAction(
            key: ValueKey('personMatch-$i'),
            onPressed: () => Navigator.of(sheet).pop(PersonTarget(person.id)),
            child: Column(
              children: [
                Text(person.name),
                Text(
                  describe(person),
                  style: const TextStyle(
                    fontSize: 13,
                    color: CupertinoColors.systemGrey,
                  ),
                ),
              ],
            ),
          ),
        CupertinoActionSheetAction(
          key: const ValueKey('personMatchNew'),
          onPressed: () =>
              Navigator.of(sheet).pop(const PersonTarget.newPerson()),
          child: Text(l10n.personMatchNew),
        ),
      ],
      cancelButton: CupertinoActionSheetAction(
        onPressed: () => Navigator.of(sheet).pop(),
        child: Text(l10n.actionCancel),
      ),
    ),
  );
}

/// The line under a row's name: who it goes to.
String personTargetLabel(
  AppLocalizations l10n,
  PersonTarget? target,
  List<Person> candidates,
) {
  if (target == null) return l10n.personMatchChoose(candidates.length);
  if (target.personId == null) return l10n.personMatchNewChosen;
  final index = candidates.indexWhere((p) => p.id == target.personId);
  if (index < 0) return l10n.personMatchChoose(candidates.length);
  return l10n.personMatchChosen(index + 1, candidates.length);
}
