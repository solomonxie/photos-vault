import 'package:flutter/cupertino.dart';

import '../l10n/app_localizations.dart';
import '../photos/person_detail.dart';
import 'profile_chip.dart';

/// Edits one named trait: a menu where the answers are a settled list,
/// typing where they are not. The stored value is the English key,
/// localised for display only, so switching language does not rewrite
/// anybody's profile. Blank or "Not set" removes it.
Future<void> editTrait(
  BuildContext context,
  PersonTrait trait,
  Map<String, String> traits,
  ValueChanged<Map<String, String>> onChanged,
) async {
  final l10n = AppLocalizations.of(context)!;
  final label = traitLabel(l10n, trait.key);
  final value = traits[trait.key] ?? '';
  String? next;
  if (trait.isMenu) {
    final picked = await showCupertinoModalPopup<({String? value})>(
      context: context,
      builder: (sheetContext) => CupertinoActionSheet(
        title: Text(label),
        actions: [
          for (final option in trait.options)
            CupertinoActionSheetAction(
              onPressed: () => Navigator.of(sheetContext).pop((value: option)),
              child: Text(traitValueLabel(l10n, trait.key, option)),
            ),
          if (value.isNotEmpty)
            CupertinoActionSheetAction(
              isDestructiveAction: true,
              onPressed: () => Navigator.of(sheetContext).pop((value: null)),
              child: Text(l10n.personProfileNotSet),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(sheetContext).pop(),
          child: Text(l10n.actionCancel),
        ),
      ),
    );
    if (picked == null) return;
    next = picked.value ?? '';
  } else {
    next = await showProfileTextPrompt(
      context,
      title: label,
      placeholder: traitPlaceholder(l10n, trait.key),
      initial: value,
    );
    if (next == null) return;
  }
  final updated = {...traits};
  if (next.isEmpty) {
    updated.remove(trait.key);
  } else {
    updated[trait.key] = next;
  }
  onChanged(updated);
}

Key traitRowKey(String key) => ValueKey('trait:$key');

String traitLabel(AppLocalizations l10n, String key) => switch (key) {
  'hair' => l10n.traitHair,
  'eyes' => l10n.traitEyes,
  'height' => l10n.traitHeight,
  'build' => l10n.traitBuild,
  'handed' => l10n.traitHanded,
  'languages' => l10n.traitLanguages,
  'diet' => l10n.traitDiet,
  _ => l10n.traitContact,
};

String traitPlaceholder(AppLocalizations l10n, String key) => switch (key) {
  'height' => l10n.traitHeightPlaceholder,
  'languages' => l10n.traitLanguagesPlaceholder,
  'diet' => l10n.traitDietPlaceholder,
  _ => l10n.traitContactPlaceholder,
};

/// Menu values only, and per row: `grey` hair and `grey` eyes are the same
/// word in English and different ones in Chinese, so the row has to be part
/// of the lookup.
///
/// Anything typed is shown as typed — it is the user's own words, and a
/// lookup table has no business rewriting them.
String traitValueLabel(AppLocalizations l10n, String key, String value) =>
    switch ((key, value)) {
      ('hair', 'black') => l10n.traitHairBlack,
      ('hair', 'brown') => l10n.traitHairBrown,
      ('hair', 'blonde') => l10n.traitHairBlonde,
      ('hair', 'red') => l10n.traitHairRed,
      ('hair', 'grey') => l10n.traitHairGrey,
      ('hair', 'white') => l10n.traitHairWhite,
      ('hair', 'dyed') => l10n.traitHairDyed,
      ('eyes', 'brown') => l10n.traitEyesBrown,
      ('eyes', 'blue') => l10n.traitEyesBlue,
      ('eyes', 'green') => l10n.traitEyesGreen,
      ('eyes', 'hazel') => l10n.traitEyesHazel,
      ('eyes', 'grey') => l10n.traitEyesGrey,
      ('eyes', 'dark') => l10n.traitEyesDark,
      ('build', 'slight') => l10n.traitBuildSlight,
      ('build', 'average') => l10n.traitBuildAverage,
      ('build', 'solid') => l10n.traitBuildSolid,
      ('build', 'tall') => l10n.traitBuildTall,
      ('handed', 'left') => l10n.traitHandedLeft,
      ('handed', 'right') => l10n.traitHandedRight,
      _ => value,
    };
