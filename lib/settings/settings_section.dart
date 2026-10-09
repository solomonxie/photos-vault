/// Shared look for the app's settings-style pages: a bold section heading
/// carrying at most one right-aligned accent control, a small hint under
/// it, rows drawn straight on the page separated by inset hairlines, and a
/// one-line stats footer.
///
/// Deliberately card-less — rows sit on the page background instead of in
/// an inset-grouped card, matching the cloud section of the sibling
/// bring-your-own-podcasts app. See `docs/design/UIUX.md`.
library;

import 'package:flutter/cupertino.dart';

const settingsPageBackground = Color(0xFF1C1C1E);
const settingsAccent = Color(0xFF0A84FF);
const settingsSecondary = Color(0x99EBEBF5);
const settingsTertiary = Color(0x4DEBEBF5);
const settingsSeparator = Color(0xA6545458);

/// The fill behind a pill-shaped control, or a form field — one step
/// lighter than the page.
const settingsControlFill = Color(0xFF2C2C2E);

/// iOS dark-mode red. Only ever a field's own error, never a heading.
const settingsError = Color(0xFFFF453A);

const settingsHeadingStyle = TextStyle(
  fontSize: 20,
  fontWeight: FontWeight.w700,
  color: CupertinoColors.white,
);

/// Secondary sections (the settings under the bucket list) — uppercased by
/// the caller's text, not a transform, so translations opt out by casing.
const settingsSubheadingStyle = TextStyle(
  fontSize: 12,
  fontWeight: FontWeight.w600,
  letterSpacing: 0.5,
  color: settingsSecondary,
);

const settingsHintStyle = TextStyle(
  fontSize: 11,
  height: 1.35,
  color: settingsSecondary,
);

const settingsRowTitleStyle = TextStyle(
  fontSize: 15,
  fontWeight: FontWeight.w600,
  color: CupertinoColors.white,
);

const settingsRowSubtitleStyle = TextStyle(
  fontSize: 11,
  color: settingsSecondary,
);

const settingsRowDetailStyle = TextStyle(
  fontSize: 12,
  color: settingsSecondary,
);

/// The right-hand side of a row that carries a value rather than a switch
/// — same size as the title, muted, iOS-style.
const settingsRowValueStyle = TextStyle(fontSize: 15, color: settingsSecondary);

const settingsFooterStyle = TextStyle(fontSize: 12, color: settingsSecondary);

/// Above a form field — smaller than a row title, because a column of five
/// of them at row weight reads as five headings.
const settingsFieldLabelStyle = TextStyle(
  fontSize: 13,
  fontWeight: FontWeight.w600,
  color: CupertinoColors.white,
);

const settingsErrorStyle = TextStyle(
  fontSize: 11,
  height: 1.35,
  color: settingsError,
);

/// Horizontal page margin, and the left inset of a row hairline so it
/// starts under the row's title rather than under its icon.
const settingsPagePadding = 16.0;
const settingsRowIndent = 56.0;

class SettingsSection extends StatelessWidget {
  const SettingsSection({
    super.key,
    required this.heading,
    this.primary = true,
    this.action,
    this.hint,
    this.children = const [],
    this.footer,
  });

  final String heading;

  /// `true` for the page's main section (20pt bold), `false` for the
  /// secondary settings below it (12pt uppercase).
  final bool primary;

  /// The single right-aligned control on the heading row — an accent text
  /// button or an icon button, never more than one.
  final Widget? action;

  final String? hint;
  final List<Widget> children;

  /// One compact line under the list. Never its own row or section.
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: settingsPagePadding),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  heading,
                  style: primary
                      ? settingsHeadingStyle
                      : settingsSubheadingStyle,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              ?action,
            ],
          ),
        ),
        if (hint != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              settingsPagePadding,
              4,
              settingsPagePadding,
              0,
            ),
            child: Text(hint!, style: settingsHintStyle),
          ),
        if (children.isNotEmpty) const SizedBox(height: 8),
        ...children,
        if (footer != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              settingsPagePadding,
              8,
              settingsPagePadding,
              0,
            ),
            child: footer!,
          ),
      ],
    );
  }
}

/// Between sections: a full-width hairline plus generous breathing room,
/// which is what separates groups here instead of a card edge.
class SettingsSectionDivider extends StatelessWidget {
  const SettingsSectionDivider({super.key});

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.fromLTRB(
        settingsPagePadding,
        24,
        settingsPagePadding,
        24,
      ),
      child: SettingsHairline(),
    );
  }
}

class SettingsHairline extends StatelessWidget {
  const SettingsHairline({super.key, this.indent = 0});

  /// Inset from the left so the line starts under the row's text.
  final double indent;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(left: indent),
      child: Container(height: 0.5, color: settingsSeparator),
    );
  }
}

/// The 44pt rounded-square glyph that leads a container row (a bucket, a
/// folder) — an accent gradient rather than a flat fill, which reads as
/// depth at this size.
class SettingsIconTile extends StatelessWidget {
  const SettingsIconTile({
    super.key,
    required this.icon,
    this.color = settingsAccent,
  });

  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        borderRadius: const BorderRadius.all(Radius.circular(6)),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            color,
            Color.alphaBlend(color.withAlpha(0xCC), settingsPageBackground),
          ],
        ),
      ),
      child: Icon(icon, color: CupertinoColors.white, size: 20),
    );
  }
}

class SettingsRow extends StatelessWidget {
  const SettingsRow({
    super.key,
    this.leading,
    required this.title,
    this.subtitle,
    this.detail,
    this.trailing,
    this.onTap,
  });

  final Widget? leading;
  final String title;

  /// Smaller muted line under the title — what tells near-duplicate rows
  /// apart (two connections to the same bucket, different prefixes).
  final String? subtitle;

  /// A second muted line under [subtitle], for a row's own stats.
  final String? detail;

  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final row = Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: settingsPagePadding,
        vertical: 8,
      ),
      child: Row(
        children: [
          if (leading != null) ...[leading!, const SizedBox(width: 12)],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: settingsRowTitleStyle,
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: settingsRowSubtitleStyle,
                  ),
                ],
                if (detail != null) ...[
                  const SizedBox(height: 2),
                  Text(detail!, style: settingsRowDetailStyle),
                ],
              ],
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 8), trailing!],
        ],
      ),
    );
    if (onTap == null) return row;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: row,
    );
  }
}

/// An action with a face: icon, label, and a filled pill around both.
///
/// The bare accent-coloured words this page used elsewhere are fine inside
/// a row of text, and wrong for the two things you actually come here to
/// press — "sync now" and "how often". A pill says where to put your thumb.
class SettingsPillButton extends StatelessWidget {
  const SettingsPillButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    final color = enabled ? settingsAccent : settingsTertiary;
    return CupertinoButton(
      // Tight enough to read as a control on this page rather than a
      // call to action: the pill is there to say "press here", and at
      // full button size it was saying it much louder than the page's
      // own rows.
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      minimumSize: const Size(0, 34),
      borderRadius: BorderRadius.circular(17),
      color: settingsControlFill,
      onPressed: onPressed,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 6),
          Text(label, style: TextStyle(fontSize: 13, color: color)),
        ],
      ),
    );
  }
}

/// A number you nudge and watch, in the shape of the pills beside it:
/// `[ − 1 at a time + ]`. A menu would be wrong for it — the value is a
/// dial, not a choice from a list.
class SettingsStepper extends StatelessWidget {
  const SettingsStepper({
    super.key,
    required this.label,
    required this.onDecrease,
    required this.onIncrease,
    this.decreaseSemanticLabel,
    this.increaseSemanticLabel,
  });

  final String label;
  final VoidCallback? onDecrease;
  final VoidCallback? onIncrease;
  final String? decreaseSemanticLabel;
  final String? increaseSemanticLabel;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 34,
      decoration: BoxDecoration(
        color: settingsControlFill,
        borderRadius: BorderRadius.circular(17),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _StepperButton(
            icon: CupertinoIcons.minus,
            onPressed: onDecrease,
            semanticLabel: decreaseSemanticLabel,
          ),
          Text(
            label,
            style: const TextStyle(fontSize: 13, color: settingsSecondary),
          ),
          _StepperButton(
            icon: CupertinoIcons.plus,
            onPressed: onIncrease,
            semanticLabel: increaseSemanticLabel,
          ),
        ],
      ),
    );
  }
}

class _StepperButton extends StatelessWidget {
  const _StepperButton({
    required this.icon,
    required this.onPressed,
    this.semanticLabel,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    return CupertinoButton(
      padding: EdgeInsets.zero,
      minimumSize: const Size(38, 34),
      borderRadius: BorderRadius.zero,
      onPressed: onPressed,
      child: Icon(
        icon,
        size: 15,
        semanticLabel: semanticLabel,
        color: onPressed == null ? settingsTertiary : settingsAccent,
      ),
    );
  }
}

class SettingsAccentButton extends StatelessWidget {
  const SettingsAccentButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.showChevron = false,
  });

  final String label;
  final VoidCallback? onPressed;

  /// Marks the label as opening a menu of values (`Manual ▾`).
  final bool showChevron;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return CupertinoButton(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      minimumSize: Size.zero,
      onPressed: onPressed,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 15,
              color: enabled ? settingsAccent : settingsTertiary,
            ),
          ),
          if (showChevron) ...[
            const SizedBox(width: 2),
            Icon(
              CupertinoIcons.chevron_down,
              size: 12,
              color: enabled ? settingsAccent : settingsTertiary,
            ),
          ],
        ],
      ),
    );
  }
}

/// The muted one-line summary that sits under a list — stats, or a
/// tappable status line. In-progress state rides inline on it rather than
/// taking a row of its own.
class SettingsFooterLine extends StatelessWidget {
  const SettingsFooterLine({
    super.key,
    required this.text,
    this.busy = false,
    this.busyText,
    this.onTap,
  });

  final String text;
  final bool busy;
  final String? busyText;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final line = Row(
      children: [
        Flexible(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: settingsFooterStyle,
          ),
        ),
        if (busy) ...[
          const SizedBox(width: 6),
          const CupertinoActivityIndicator(radius: 6),
          if (busyText != null) ...[
            const SizedBox(width: 4),
            Text(busyText!, style: settingsFooterStyle),
          ],
        ],
        if (onTap != null) ...[
          const SizedBox(width: 4),
          const Icon(
            CupertinoIcons.chevron_forward,
            size: 11,
            color: settingsSecondary,
          ),
        ],
      ],
    );
    if (onTap == null) return line;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: line,
    );
  }
}

/// A labelled input on a settings-style page: label above, filled rounded
/// box under it, and one muted line below for a hint or an error.
///
/// Bare underlined fields are nearly invisible on this background — the
/// fill is what makes a field read as somewhere to type. Same box as the
/// Add AI Key sheet, so every form in the app has one field shape.
class SettingsField extends StatelessWidget {
  const SettingsField({
    super.key,
    required this.label,
    required this.controller,
    this.fieldKey,
    this.placeholder,
    this.helper,
    this.errorText,
    this.enabled = true,
    this.obscure = false,
    this.suffix,
    this.monospace = false,
    this.minLines,
    this.maxLines = 1,
    this.autofocus = false,
    this.onChanged,
  });

  final String label;
  final TextEditingController controller;

  /// On the field itself rather than this widget, so a test types into the
  /// input and not its label.
  final Key? fieldKey;

  final String? placeholder;

  /// The muted line under the field. Replaced by [errorText] when set.
  final String? helper;
  final String? errorText;

  final bool enabled;
  final bool obscure;
  final Widget? suffix;
  final bool monospace;
  final int? minLines;
  final int? maxLines;
  final bool autofocus;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    return _FieldFrame(
      label: label,
      helper: helper,
      errorText: errorText,
      child: CupertinoTextField(
        key: fieldKey,
        controller: controller,
        enabled: enabled,
        obscureText: obscure,
        autofocus: autofocus,
        minLines: minLines,
        maxLines: maxLines,
        placeholder: placeholder,
        // Credential fields: smart punctuation silently corrupts a pasted
        // key into a signature error that looks like wrong credentials.
        autocorrect: false,
        enableSuggestions: false,
        smartDashesType: SmartDashesType.disabled,
        smartQuotesType: SmartQuotesType.disabled,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        style: TextStyle(
          fontSize: 15,
          color: enabled ? CupertinoColors.white : settingsSecondary,
          fontFamily: monospace ? 'monospace' : null,
        ),
        placeholderStyle: const TextStyle(
          fontSize: 15,
          color: settingsTertiary,
        ),
        decoration: BoxDecoration(
          color: settingsControlFill,
          borderRadius: BorderRadius.circular(10),
        ),
        suffix: suffix,
        onChanged: onChanged,
      ),
    );
  }
}

/// A field whose value is chosen rather than typed — same box, a chevron
/// where the caret would be, and a sheet on tap.
class SettingsPickerField extends StatelessWidget {
  const SettingsPickerField({
    super.key,
    required this.label,
    required this.value,
    required this.placeholder,
    required this.onTap,
    this.fieldKey,
    this.helper,
    this.errorText,
  });

  final String label;
  final String value;
  final String placeholder;
  final VoidCallback? onTap;

  /// On the box rather than this widget, so a tap lands on the control and
  /// not its label.
  final Key? fieldKey;

  final String? helper;
  final String? errorText;

  @override
  Widget build(BuildContext context) {
    final empty = value.isEmpty;
    return _FieldFrame(
      label: label,
      helper: helper,
      errorText: errorText,
      child: GestureDetector(
        key: fieldKey,
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: settingsControlFill,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  empty ? placeholder : value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 15,
                    color: empty ? settingsTertiary : CupertinoColors.white,
                  ),
                ),
              ),
              const Icon(
                CupertinoIcons.chevron_down,
                size: 14,
                color: settingsSecondary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A field whose value is one of a handful — laid out as the choices
/// themselves rather than a row that opens a sheet.
///
/// A sheet hides the question behind a tap: you have to know the row is a
/// control before you can find out what it offers. With three or four
/// options, showing them is both the label and the answer.
class SettingsChoiceField extends StatelessWidget {
  const SettingsChoiceField({
    super.key,
    required this.label,
    required this.options,
    required this.selected,
    required this.onSelected,
    this.helper,
  });

  final String label;
  final List<String> options;
  final int selected;

  /// `null` disables the whole group — mid-save, not a missing option.
  final ValueChanged<int>? onSelected;

  final String? helper;

  @override
  Widget build(BuildContext context) {
    return _FieldFrame(
      label: label,
      helper: helper,
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (var i = 0; i < options.length; i++)
            _ChoiceChip(
              label: options[i],
              selected: i == selected,
              onTap: onSelected == null ? null : () => onSelected!(i),
            ),
        ],
      ),
    );
  }
}

class _ChoiceChip extends StatelessWidget {
  const _ChoiceChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? settingsAccent : settingsControlFill,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 15,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            color: onTap == null ? settingsTertiary : CupertinoColors.white,
          ),
        ),
      ),
    );
  }
}

class _FieldFrame extends StatelessWidget {
  const _FieldFrame({
    required this.label,
    required this.child,
    this.helper,
    this.errorText,
  });

  final String label;
  final Widget child;
  final String? helper;
  final String? errorText;

  @override
  Widget build(BuildContext context) {
    final note = errorText ?? helper;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        settingsPagePadding,
        0,
        settingsPagePadding,
        12,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: settingsFieldLabelStyle),
          const SizedBox(height: 6),
          child,
          if (note != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                note,
                style: errorText != null
                    ? settingsErrorStyle
                    : settingsHintStyle,
              ),
            ),
        ],
      ),
    );
  }
}

/// The line that says why a save didn't happen — the provider's own words,
/// under the fields they point at rather than in an alert over them.
class SettingsErrorLine extends StatelessWidget {
  const SettingsErrorLine({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        settingsPagePadding,
        4,
        settingsPagePadding,
        4,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 1),
            child: Icon(
              CupertinoIcons.exclamationmark_circle,
              size: 14,
              color: settingsError,
            ),
          ),
          const SizedBox(width: 6),
          Expanded(child: Text(message, style: settingsErrorStyle)),
        ],
      ),
    );
  }
}

// ----------------------------------------------------------- grouped lists

/// Small uppercase heading over an inset group, with an optional ⓘ that
/// opens the explanation the page doesn't have room to carry inline.
class SettingsGroupHeading extends StatelessWidget {
  const SettingsGroupHeading({super.key, required this.title, this.onInfo});

  final String title;
  final VoidCallback? onInfo;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      settingsPagePadding + 16,
      0,
      settingsPagePadding,
      6,
    ),
    child: Row(
      children: [
        Text(title.toUpperCase(), style: settingsSubheadingStyle),
        if (onInfo != null)
          CupertinoButton(
            padding: const EdgeInsets.only(left: 6),
            minimumSize: Size.zero,
            onPressed: onInfo,
            child: const Icon(
              CupertinoIcons.info_circle,
              size: 15,
              color: settingsSecondary,
            ),
          ),
      ],
    ),
  );
}

/// An inset rounded card of rows with hairlines between them.
class SettingsGroup extends StatelessWidget {
  const SettingsGroup({super.key, required this.children, this.footer});

  final List<Widget> children;

  /// One muted line under the card.
  final String? footer;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: settingsPagePadding),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: ColoredBox(
            color: settingsControlFill,
            child: Column(
              children: [
                for (var i = 0; i < children.length; i++) ...[
                  if (i > 0)
                    const SettingsHairline(indent: settingsPagePadding),
                  children[i],
                ],
              ],
            ),
          ),
        ),
      ),
      if (footer != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(
            settingsPagePadding + 16,
            8,
            settingsPagePadding + 16,
            0,
          ),
          child: Text(footer!, style: settingsFooterStyle),
        ),
    ],
  );
}

/// `title … value ›` — one row of a [SettingsGroup].
class SettingsGroupRow extends StatelessWidget {
  const SettingsGroupRow({
    super.key,
    required this.title,
    this.subtitle,
    this.value,
    this.leading,
    this.trailing,
    this.chevron = false,
    this.accent = false,
    this.onTap,
  });

  final String title;
  final String? subtitle;

  /// The current answer, muted, right-aligned before the chevron.
  final String? value;
  final Widget? leading;

  /// Replaces the value and chevron — a switch, a spinner.
  final Widget? trailing;
  final bool chevron;

  /// An action row ("Add a Bucket"): the title is accent-coloured.
  final bool accent;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final row = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 48),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: settingsPagePadding,
          vertical: 8,
        ),
        child: Row(
          children: [
            if (leading != null) ...[leading!, const SizedBox(width: 12)],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 16,
                      color: accent ? settingsAccent : CupertinoColors.white,
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: settingsRowSubtitleStyle,
                    ),
                  ],
                ],
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: 8),
              trailing!,
            ] else ...[
              if (value != null) ...[
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    value!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: settingsRowValueStyle,
                  ),
                ),
              ],
              if (chevron) ...[
                const SizedBox(width: 6),
                const Icon(
                  CupertinoIcons.chevron_forward,
                  size: 14,
                  color: settingsTertiary,
                ),
              ],
            ],
          ],
        ),
      ),
    );
    if (onTap == null) return row;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: row,
    );
  }
}

/// The card at the top of a page that answers "is it working?" before
/// anything else: a state line, a detail line, an optional progress bar, and
/// the one primary action.
class SettingsStatusCard extends StatelessWidget {
  const SettingsStatusCard({
    super.key,
    required this.color,
    required this.title,
    this.busy = false,
    this.subtitle,
    this.progress,
    this.footnote,
    this.primaryLabel,
    this.onPrimary,
    this.linkLabel,
    this.onLink,
  });

  /// The state's colour: green done, orange needs a look, red lost.
  final Color color;
  final String title;
  final bool busy;
  final String? subtitle;

  /// 0..1; absent draws no bar.
  final double? progress;
  final String? footnote;
  final String? primaryLabel;
  final VoidCallback? onPrimary;
  final String? linkLabel;
  final VoidCallback? onLink;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: settingsPagePadding),
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: settingsControlFill,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (busy)
                  const CupertinoActivityIndicator(radius: 8)
                else
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                    ),
                    child: const SizedBox(width: 10, height: 10),
                  ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontSize: 19,
                      fontWeight: FontWeight.w700,
                      color: CupertinoColors.white,
                    ),
                  ),
                ),
              ],
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 6),
              Text(subtitle!, style: settingsRowValueStyle),
            ],
            if (progress != null) ...[
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: SizedBox(
                  height: 6,
                  child: Stack(
                    children: [
                      const Positioned.fill(
                        child: ColoredBox(color: settingsPageBackground),
                      ),
                      Positioned.fill(
                        child: FractionallySizedBox(
                          alignment: AlignmentDirectional.centerStart,
                          widthFactor: progress!.clamp(0.0, 1.0),
                          child: ColoredBox(color: color),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
            if (footnote != null) ...[
              const SizedBox(height: 8),
              Text(footnote!, style: settingsFooterStyle),
            ],
            if (primaryLabel != null || linkLabel != null) ...[
              const SizedBox(height: 14),
              Row(
                children: [
                  if (primaryLabel != null)
                    CupertinoButton(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 8,
                      ),
                      minimumSize: const Size(0, 36),
                      borderRadius: BorderRadius.circular(18),
                      color: settingsAccent,
                      disabledColor: settingsPageBackground,
                      onPressed: onPrimary,
                      child: Text(
                        primaryLabel!,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: onPrimary == null
                              ? settingsTertiary
                              : CupertinoColors.white,
                        ),
                      ),
                    ),
                  const Spacer(),
                  if (linkLabel != null)
                    CupertinoButton(
                      padding: EdgeInsets.zero,
                      minimumSize: Size.zero,
                      onPressed: onLink,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            linkLabel!,
                            style: const TextStyle(
                              fontSize: 15,
                              color: settingsAccent,
                            ),
                          ),
                          const SizedBox(width: 2),
                          const Icon(
                            CupertinoIcons.chevron_forward,
                            size: 13,
                            color: settingsAccent,
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    ),
  );
}
