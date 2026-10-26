import 'package:flutter/cupertino.dart';

import '../l10n/app_localizations.dart';
import '../photos/person_detail.dart';
import 'profile_chip.dart';
import 'profile_section.dart';

/// Impressions of somebody, not an assessment of them.
///
/// Three scales and a set of tags, all optional and none scored. The
/// scales are the ones a reader already has words for; the tags carry what
/// a personality model would otherwise name, without naming it.
class ProfileImpression extends StatelessWidget {
  const ProfileImpression({
    super.key,
    required this.impression,
    required this.onChanged,
  });

  final PersonImpression impression;
  final ValueChanged<PersonImpression> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      children: [
        CupertinoListSection.insetGrouped(
          margin: const EdgeInsets.symmetric(horizontal: 16),
          backgroundColor: profileCardBackground,
          decoration: profileCardDecoration,
          children: [
            _row(
              context,
              l10n,
              label: l10n.impressionOverallLabel,
              value: impression.overall,
              name: (level) => _overallLabel(l10n, level),
              onPicked: (level) =>
                  onChanged(impression.copyWith(overall: () => level)),
            ),
            _row(
              context,
              l10n,
              label: l10n.impressionSocialLabel,
              value: impression.socialEnergy,
              name: (level) => _socialLabel(l10n, level),
              onPicked: (level) =>
                  onChanged(impression.copyWith(socialEnergy: () => level)),
            ),
            _row(
              context,
              l10n,
              label: l10n.impressionIntroversionLabel,
              value: impression.introversion,
              name: (level) => _introversionLabel(l10n, level),
              onPicked: (level) =>
                  onChanged(impression.copyWith(introversion: () => level)),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              l10n.impressionTagsLabel,
              style: const TextStyle(
                fontSize: 13,
                color: CupertinoColors.systemGrey,
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final tag in _tagsOnOffer(impression)) _tagChip(l10n, tag),
              ProfileChip(
                key: const ValueKey('impression-tag-add'),
                label: l10n.impressionTagAddTitle,
                selected: false,
                leading: CupertinoIcons.add,
                onTap: () => _addTag(context, l10n),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _row(
    BuildContext context,
    AppLocalizations l10n, {
    required String label,
    required ImpressionLevel? value,
    required String Function(ImpressionLevel) name,
    required ValueChanged<ImpressionLevel?> onPicked,
  }) => CupertinoListTile(
    title: Text(label),
    trailing: Text(
      value == null ? l10n.impressionNotSet : name(value),
      style: TextStyle(
        color: value == null
            ? CupertinoColors.systemGrey
            : CupertinoColors.white,
      ),
    ),
    onTap: () async {
      final picked = await showCupertinoModalPopup<({ImpressionLevel? level})>(
        context: context,
        builder: (sheetContext) => CupertinoActionSheet(
          title: Text(label),
          actions: [
            for (final level in ImpressionLevel.values)
              CupertinoActionSheetAction(
                onPressed: () => Navigator.of(sheetContext).pop((level: level)),
                child: Text(name(level)),
              ),
            // Clearing has to be possible: an impression recorded by accident
            // is worse than none, and this is somebody's view of a person.
            if (value != null)
              CupertinoActionSheetAction(
                isDestructiveAction: true,
                onPressed: () => Navigator.of(sheetContext).pop((level: null)),
                child: Text(l10n.impressionNotSet),
              ),
          ],
          cancelButton: CupertinoActionSheetAction(
            onPressed: () => Navigator.of(sheetContext).pop(),
            child: Text(l10n.actionCancel),
          ),
        ),
      );
      if (picked != null) onPicked(picked.level);
    },
  );

  /// The twelve built in, plus anything typed for this person. A tag added by
  /// hand keeps showing after it is switched off — otherwise switching it off
  /// would be the same as deleting it.
  static List<String> _tagsOnOffer(PersonImpression impression) => [
    ...impressionTags,
    for (final tag in impression.tags)
      if (!impressionTags.contains(tag)) tag,
  ];

  Future<void> _addTag(BuildContext context, AppLocalizations l10n) async {
    final typed = await showProfileTextPrompt(
      context,
      title: l10n.impressionTagAddTitle,
      placeholder: l10n.impressionTagAddPlaceholder,
    );
    final tag = typed?.toLowerCase();
    if (tag == null || tag.isEmpty || impression.tags.contains(tag)) return;
    onChanged(impression.copyWith(tags: [...impression.tags, tag]));
  }

  Widget _tagChip(AppLocalizations l10n, String tag) => ProfileChip(
    label: _tagLabel(l10n, tag),
    selected: impression.tags.contains(tag),
    onTap: () => onChanged(
      impression.copyWith(
        tags: impression.tags.contains(tag)
            ? [
                for (final t in impression.tags)
                  if (t != tag) t,
              ]
            : [...impression.tags, tag],
      ),
    ),
  );

  static String _overallLabel(AppLocalizations l10n, ImpressionLevel level) =>
      switch (level) {
        ImpressionLevel.veryLow => l10n.impressionOverallVeryLow,
        ImpressionLevel.low => l10n.impressionOverallLow,
        ImpressionLevel.middle => l10n.impressionOverallMiddle,
        ImpressionLevel.high => l10n.impressionOverallHigh,
        ImpressionLevel.veryHigh => l10n.impressionOverallVeryHigh,
      };

  static String _socialLabel(AppLocalizations l10n, ImpressionLevel level) =>
      switch (level) {
        ImpressionLevel.veryLow => l10n.impressionSocialVeryLow,
        ImpressionLevel.low => l10n.impressionSocialLow,
        ImpressionLevel.middle => l10n.impressionSocialMiddle,
        ImpressionLevel.high => l10n.impressionSocialHigh,
        ImpressionLevel.veryHigh => l10n.impressionSocialVeryHigh,
      };

  static String _introversionLabel(
    AppLocalizations l10n,
    ImpressionLevel level,
  ) => switch (level) {
    ImpressionLevel.veryLow => l10n.impressionIntroversionVeryLow,
    ImpressionLevel.low => l10n.impressionIntroversionLow,
    ImpressionLevel.middle => l10n.impressionIntroversionMiddle,
    ImpressionLevel.high => l10n.impressionIntroversionHigh,
    ImpressionLevel.veryHigh => l10n.impressionIntroversionVeryHigh,
  };

  static String _tagLabel(AppLocalizations l10n, String tag) => switch (tag) {
    'curious' => l10n.impressionTagCurious,
    'organised' => l10n.impressionTagOrganised,
    'spontaneous' => l10n.impressionTagSpontaneous,
    'empathetic' => l10n.impressionTagEmpathetic,
    'blunt' => l10n.impressionTagBlunt,
    'patient' => l10n.impressionTagPatient,
    'competitive' => l10n.impressionTagCompetitive,
    'generous' => l10n.impressionTagGenerous,
    'private' => l10n.impressionTagPrivate,
    'funny' => l10n.impressionTagFunny,
    'steady' => l10n.impressionTagSteady,
    'intense' => l10n.impressionTagIntense,
    // Typed by hand: shown as typed. The old catch-all named the last
    // built-in tag, so every custom one displayed as "intense".
    _ => tag,
  };
}
