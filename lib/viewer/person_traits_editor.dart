import 'package:flutter/cupertino.dart';

import '../l10n/app_localizations.dart';
import '../photos/person_detail.dart';

/// The named rows at the top of More details — hair, eyes, height and the
/// rest, always shown and each empty until filled in.
///
/// They are listed rather than hidden on purpose. A section that shows
/// nothing until you have already put something in it never gets used,
/// because nothing tells you what it is for; the labels are the prompt.
///
/// Menus where the answers are a settled list, typing where they are not.
/// The stored value is the English key, localised for display only, so
/// switching language does not rewrite anybody's profile.
class PersonTraitsEditor extends StatelessWidget {
  const PersonTraitsEditor({
    super.key,
    required this.traits,
    required this.onChanged,
    required this.background,
    required this.decoration,
  });

  final Map<String, String> traits;
  final ValueChanged<Map<String, String>> onChanged;
  final Color background;
  final BoxDecoration decoration;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return CupertinoListSection.insetGrouped(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      backgroundColor: background,
      decoration: decoration,
      children: [
        for (final trait in personTraits)
          _row(context, l10n, trait, traits[trait.key] ?? ''),
      ],
    );
  }

  Widget _row(
    BuildContext context,
    AppLocalizations l10n,
    PersonTrait trait,
    String value,
  ) {
    final label = traitLabel(l10n, trait.key);
    return CupertinoListTile(
      key: traitRowKey(trait.key),
      title: Text(label),
      trailing: Text(
        value.isEmpty
            ? l10n.personProfileNotSet
            : traitValueLabel(l10n, trait.key, value),
        style: TextStyle(
          color: value.isEmpty
              ? CupertinoColors.systemGrey
              : CupertinoColors.white,
        ),
      ),
      onTap: () => trait.isMenu
          ? _pickFromMenu(context, l10n, trait, value, label)
          : _typeIt(context, l10n, trait, value, label),
    );
  }

  Future<void> _pickFromMenu(
    BuildContext context,
    AppLocalizations l10n,
    PersonTrait trait,
    String value,
    String label,
  ) async {
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
    if (picked != null) _write(trait.key, picked.value ?? '');
  }

  Future<void> _typeIt(
    BuildContext context,
    AppLocalizations l10n,
    PersonTrait trait,
    String value,
    String label,
  ) async {
    final controller = TextEditingController(text: value);
    final saved = await showCupertinoDialog<String>(
      context: context,
      builder: (dialogContext) => CupertinoAlertDialog(
        title: Text(label),
        content: Padding(
          padding: const EdgeInsets.only(top: 12),
          child: CupertinoTextField(
            controller: controller,
            autofocus: true,
            placeholder: traitPlaceholder(l10n, trait.key),
          ),
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l10n.actionCancel),
          ),
          CupertinoDialogAction(
            onPressed: () =>
                Navigator.of(dialogContext).pop(controller.text.trim()),
            child: Text(l10n.settingsSaveButton),
          ),
        ],
      ),
    );
    controller.dispose();
    if (saved != null) _write(trait.key, saved);
  }

  /// Blank clears the row rather than storing an empty string, so a profile
  /// carries only what somebody actually wrote.
  void _write(String key, String value) {
    final next = {...traits};
    if (value.isEmpty) {
      next.remove(key);
    } else {
      next[key] = value;
    }
    onChanged(next);
  }
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
