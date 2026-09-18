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
