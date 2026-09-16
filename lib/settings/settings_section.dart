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

const settingsFooterStyle = TextStyle(fontSize: 12, color: settingsSecondary);

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

/// A row whose whole job is picking one of a few options, each with its own
/// one-sentence pro/con — too much text for a menu, so it stays a list.
class SettingsChoiceRow extends StatelessWidget {
  const SettingsChoiceRow({
    super.key,
    required this.title,
    required this.description,
    required this.selected,
    required this.onTap,
  });

  final String title;
  final String description;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: settingsPagePadding,
          vertical: 10,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: settingsRowTitleStyle),
                  const SizedBox(height: 2),
                  Text(description, style: settingsHintStyle),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Icon(
              CupertinoIcons.checkmark_alt,
              size: 18,
              color: selected ? settingsAccent : const Color(0x00000000),
            ),
          ],
        ),
      ),
    );
  }
}

/// Accent text control for a heading row — the one place a section is
/// allowed a control, and a text link rather than a filled button.
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
