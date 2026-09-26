import 'package:flutter/cupertino.dart';

import '../l10n/app_localizations.dart';
import '../photos/person.dart';

/// The one chip shape the profile uses — personality tags, and the fields
/// More details is offering. Shared so the two rows of chips on one page do
/// not drift apart.
class ProfileChip extends StatelessWidget {
  const ProfileChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.onLongPress,
    this.leading,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final IconData? leading;

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    onLongPress: onLongPress,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: selected ? CupertinoColors.systemBlue : const Color(0xFF2C2C2E),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (leading != null) ...[
            Icon(
              leading,
              size: 13,
              color: selected
                  ? CupertinoColors.white
                  : CupertinoColors.systemGrey,
            ),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: 13,
              color: selected
                  ? CupertinoColors.white
                  : CupertinoColors.systemGrey,
            ),
          ),
        ],
      ),
    ),
  );
}

/// One short answer, typed. Returns `null` when dismissed, and the trimmed
/// text otherwise — including empty, which callers read as "clear this".
Future<String?> showProfileTextPrompt(
  BuildContext context, {
  required String title,
  required String placeholder,
  String initial = '',
}) async {
  final l10n = AppLocalizations.of(context)!;
  final controller = TextEditingController(text: initial);
  final saved = await showCupertinoDialog<String>(
    context: context,
    builder: (dialogContext) => CupertinoAlertDialog(
      title: Text(title),
      content: Padding(
        padding: const EdgeInsets.only(top: 12),
        child: CupertinoTextField(
          controller: controller,
          autofocus: true,
          placeholder: placeholder,
          onSubmitted: (value) => Navigator.of(dialogContext).pop(value.trim()),
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
  return saved;
}

String groupKindLabel(AppLocalizations l10n, GroupKind kind) => switch (kind) {
  GroupKind.family => l10n.groupKindFamily,
  GroupKind.company => l10n.groupKindCompany,
  GroupKind.school => l10n.groupKindSchool,
  GroupKind.circle => l10n.groupKindCircle,
};
