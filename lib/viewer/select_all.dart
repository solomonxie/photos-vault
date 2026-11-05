import 'package:flutter/cupertino.dart';

import '../l10n/app_localizations.dart';

/// Past this many, Select All asks first: a batch edit or delete over the
/// whole library at once is a tap that should be meant.
const selectAllLimit = 100;

/// Every one of [all], added to [selected].
Set<K> selectEverything<K>(Iterable<K> all, Set<K> selected) => {
  ...selected,
  ...all,
};

/// Select All for a select mode; with everything chosen it turns into
/// Deselect All. More than [selectAllLimit] asks before selecting.
class SelectAllButton extends StatelessWidget {
  const SelectAllButton({
    super.key,
    required this.total,
    required this.selectedCount,
    required this.onSelectNext,
    required this.onDeselectAll,
  });

  final int total;
  final int selectedCount;

  /// Selects everything.
  final VoidCallback onSelectNext;
  final VoidCallback onDeselectAll;

  Future<void> _selectAll(BuildContext context) async {
    if (total <= selectAllLimit) return onSelectNext();
    final l10n = AppLocalizations.of(context)!;
    final yes = await showCupertinoDialog<bool>(
      context: context,
      builder: (dialog) => CupertinoAlertDialog(
        title: Text(l10n.selectionSelectAllConfirm(total)),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(dialog).pop(false),
            child: Text(l10n.actionCancel),
          ),
          CupertinoDialogAction(
            key: const ValueKey('selectAllConfirm'),
            isDefaultAction: true,
            onPressed: () => Navigator.of(dialog).pop(true),
            child: Text(l10n.selectionSelectAll),
          ),
        ],
      ),
    );
    if (yes == true) onSelectNext();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final left = total - selectedCount;
    return CupertinoButton(
      key: const ValueKey('selectAllButton'),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      minimumSize: Size.zero,
      onPressed: total == 0
          ? null
          : left <= 0
          ? onDeselectAll
          : () => _selectAll(context),
      child: Text(
        left <= 0 ? l10n.selectionDeselectAll : l10n.selectionSelectAll,
      ),
    );
  }
}

/// Done, in the navigation bar's trailing corner while selecting — far from
/// Select All in the other corner and from the actions along the bottom.
class SelectionDoneButton extends StatelessWidget {
  const SelectionDoneButton({super.key, required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => CupertinoButton(
    padding: const EdgeInsets.symmetric(horizontal: 8),
    minimumSize: Size.zero,
    onPressed: onPressed,
    child: Text(
      AppLocalizations.of(context)!.selectionDone,
      style: const TextStyle(fontWeight: FontWeight.w600),
    ),
  );
}
