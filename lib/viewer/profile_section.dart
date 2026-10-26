import 'package:flutter/cupertino.dart';

import '../l10n/app_localizations.dart';

/// A section's own "+", findable by name rather than by counting — the
/// sections have been reordered several times, and every positional lookup
/// silently pointed at the wrong one.
Key profileSectionAddKey(String title) => ValueKey('section-add:$title');

/// The one compact row a section shows before anything is in it.
Key profileSectionPromptKey(String title) => ValueKey('section-prompt:$title');

/// The header itself: tapping it folds the section.
Key profileSectionHeaderKey(String title) => ValueKey('section-header:$title');

Key profileSectionEditKey(String title) => ValueKey('section-edit:$title');

/// Folded sections, by id, for the rest of the session: folding Events on
/// one profile folds it on the next one too.
final profileFolded = <String>{};

const profileCardBackground = Color(0xFF1C1C1E);
const profileCardDecoration = BoxDecoration(
  color: Color(0xFF2C2C2E),
  borderRadius: BorderRadius.all(Radius.circular(10)),
);

/// Title, count, then Edit and "+" on the right. The whole line folds.
class ProfileSectionHeader extends StatelessWidget {
  const ProfileSectionHeader({
    super.key,
    required this.title,
    this.count,
    this.folded = false,
    this.onToggle,
    this.onAdd,
    this.addKey,
    this.editing = false,
    this.onEdit,
  });

  final String title;
  final int? count;
  final bool folded;
  final VoidCallback? onToggle;
  final VoidCallback? onAdd;

  /// Instead of [profileSectionAddKey], for a "+" that tests already find
  /// by another name.
  final Key? addKey;
  final bool editing;
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return GestureDetector(
      key: profileSectionHeaderKey(title),
      behavior: HitTestBehavior.opaque,
      onTap: onToggle,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 8, 6),
        // Title, count and chevron share one Expanded, so Edit and "+" sit
        // at the right edge: a Flexible beside a Spacer splits the slack.
        child: Row(
          children: [
            Expanded(
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 17,
                      ),
                    ),
                  ),
                  if (count case final n? when n > 0)
                    Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: Text(
                        '$n',
                        style: const TextStyle(
                          fontSize: 15,
                          color: CupertinoColors.systemGrey,
                        ),
                      ),
                    ),
                  if (onToggle != null)
                    Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: Icon(
                        folded
                            ? CupertinoIcons.chevron_forward
                            : CupertinoIcons.chevron_down,
                        size: 14,
                        color: CupertinoColors.systemGrey,
                      ),
                    ),
                ],
              ),
            ),
            if (onEdit != null && !folded)
              CupertinoButton(
                key: profileSectionEditKey(title),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 32),
                onPressed: onEdit,
                child: Text(
                  editing ? l10n.actionDone : l10n.profileEdit,
                  style: const TextStyle(fontSize: 15),
                ),
              ),
            if (onAdd != null)
              CupertinoButton(
                key: addKey ?? profileSectionAddKey(title),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 32),
                onPressed: onAdd,
                child: const Icon(CupertinoIcons.add_circled),
              ),
          ],
        ),
      ),
    );
  }
}

/// An empty section, folded to one line: "+ Add Education", and what it
/// would hold underneath in grey.
class ProfileEmptyRow extends StatelessWidget {
  const ProfileEmptyRow({
    super.key,
    required this.title,
    required this.hint,
    this.onTap,
  });

  final String title;
  final String hint;

  /// Absent where nothing can be added here (imports come from elsewhere).
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return GestureDetector(
      key: profileSectionPromptKey(title),
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
        child: Row(
          children: [
            Icon(
              onTap == null ? CupertinoIcons.tray : CupertinoIcons.add_circled,
              key: onTap == null ? null : profileSectionAddKey(title),
              size: 20,
              color: onTap == null
                  ? CupertinoColors.systemGrey
                  : CupertinoColors.activeBlue,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    onTap == null ? title : l10n.profileAddSection(title),
                    style: TextStyle(
                      fontSize: 15,
                      color: onTap == null
                          ? CupertinoColors.systemGrey
                          : CupertinoColors.activeBlue,
                    ),
                  ),
                  Text(
                    hint,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      color: CupertinoColors.systemGrey2,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Rows in an inset card, the same card every section uses.
class ProfileCard extends StatelessWidget {
  const ProfileCard({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => CupertinoListSection.insetGrouped(
    margin: const EdgeInsets.symmetric(horizontal: 16),
    backgroundColor: profileCardBackground,
    decoration: profileCardDecoration,
    children: children,
  );
}

/// A row that goes by swiping left, or by its red "−" while the section is
/// being edited. The caller drops it from its list at once (a dismissed row
/// must leave the tree) and offers Undo.
class ProfileDeletableRow extends StatelessWidget {
  const ProfileDeletableRow({
    required super.key,
    required this.editing,
    required this.onDelete,
    required this.child,
  });

  final bool editing;
  final VoidCallback onDelete;
  final Widget child;

  @override
  Widget build(BuildContext context) => Dismissible(
    key: key!,
    direction: DismissDirection.endToStart,
    onDismissed: (_) => onDelete(),
    background: Container(
      color: CupertinoColors.systemRed,
      alignment: AlignmentDirectional.centerEnd,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: const Icon(CupertinoIcons.delete, color: CupertinoColors.white),
    ),
    child: editing
        ? Row(
            children: [
              CupertinoButton(
                padding: const EdgeInsetsDirectional.only(start: 12),
                minimumSize: const Size(32, 32),
                onPressed: onDelete,
                child: const Icon(
                  CupertinoIcons.minus_circle_fill,
                  color: CupertinoColors.systemRed,
                  size: 22,
                ),
              ),
              Expanded(child: child),
            ],
          )
        : child,
  );
}
