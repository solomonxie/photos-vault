import 'package:flutter/cupertino.dart';

import '../l10n/app_localizations.dart';
import '../photos/person_detail.dart';
import 'profile_chip.dart';

/// More details: the fields somebody has filled in, and chips offering the
/// ones they have not.
///
/// Eight named rows sitting there empty was eight rows of "Not set" on every
/// profile — the section became mostly blanks, which is worse than the blank
/// section it replaced. As chips they cost one line until used: tap one and it
/// becomes a row, clear the row and it goes back to being a chip.
///
/// Menus where the answers are a settled list, typing where they are not. The
/// stored value is the English key, localised for display only, so switching
/// language does not rewrite anybody's profile.
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
    final filled = [
      for (final trait in personTraits)
        if ((traits[trait.key] ?? '').isNotEmpty) trait,
    ];
    final offered = [
      for (final trait in personTraits)
        if ((traits[trait.key] ?? '').isEmpty) trait,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (filled.isNotEmpty)
          CupertinoListSection.insetGrouped(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            backgroundColor: background,
            decoration: decoration,
            children: [
              for (final trait in filled)
                _row(context, l10n, trait, traits[trait.key]!),
            ],
          ),
        if (offered.isNotEmpty)
          Padding(
            padding: EdgeInsets.fromLTRB(16, filled.isEmpty ? 0 : 10, 16, 0),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final trait in offered)
                  ProfileChip(
                    key: traitChipKey(trait.key),
                    label: traitLabel(l10n, trait.key),
                    selected: false,
                    onTap: () => _edit(context, l10n, trait, ''),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _row(
    BuildContext context,
    AppLocalizations l10n,
    PersonTrait trait,
    String value,
  ) => CupertinoListTile(
    key: traitRowKey(trait.key),
    title: Text(traitLabel(l10n, trait.key)),
    trailing: Text(
      traitValueLabel(l10n, trait.key, value),
      style: const TextStyle(color: CupertinoColors.white),
    ),
    onTap: () => _edit(context, l10n, trait, value),
  );

  Future<void> _edit(
    BuildContext context,
    AppLocalizations l10n,
    PersonTrait trait,
    String value,
  ) => trait.isMenu
      ? _pickFromMenu(context, l10n, trait, value)
      : _typeIt(context, l10n, trait, value);

  Future<void> _pickFromMenu(
    BuildContext context,
    AppLocalizations l10n,
    PersonTrait trait,
    String value,
  ) async {
    final label = traitLabel(l10n, trait.key);
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
  ) async {
    final saved = await showProfileTextPrompt(
      context,
      title: traitLabel(l10n, trait.key),
      placeholder: traitPlaceholder(l10n, trait.key),
      initial: value,
    );
    if (saved != null) _write(trait.key, saved);
  }

  /// Blank clears the row rather than storing an empty string, so a profile
  /// carries only what somebody actually wrote — and the field goes back to
  /// being one of the chips on offer.
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
Key traitChipKey(String key) => ValueKey('trait-chip:$key');

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
