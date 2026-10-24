import 'package:flutter/cupertino.dart';

import '../l10n/app_localizations.dart';

/// Most a Select All tap takes: a batch edit or delete over the whole
/// library at once is a tap nobody meant.
const selectAllLimit = 100;

/// [selected] plus the next [selectAllLimit] of [newestFirst] not already
/// in it. Lazy: stops reading once the batch is full, so a tap costs a
/// hundred records, not the library.
Set<K> selectNextBatch<K>(Iterable<K> newestFirst, Set<K> selected) {
  final next = {...selected};
  var added = 0;
  for (final key in newestFirst) {
    if (added == selectAllLimit) break;
    if (next.add(key)) added++;
  }
  return next;
}

/// Select All for a select mode, [selectAllLimit] at a time. Each tap adds
/// the next batch; with everything chosen it turns into Deselect All.
class SelectAllButton extends StatelessWidget {
  const SelectAllButton({
    super.key,
    required this.total,
    required this.selectedCount,
    required this.onSelectNext,
    required this.onDeselectAll,
    this.unlimited = false,
  });

  /// Everything in one tap, for a set that is bounded and whose actions
  /// delete nothing — one person's photos.
  final bool unlimited;

  final int total;
  final int selectedCount;
  final VoidCallback onSelectNext;
  final VoidCallback onDeselectAll;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final left = total - selectedCount;
    // No "Select 100": only a whole library that fits one batch can be
    // selected from here; a bigger one is picked by sweeping.
    if (!unlimited && left > selectAllLimit) return const SizedBox.shrink();
    return CupertinoButton(
      key: const ValueKey('selectAllButton'),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      minimumSize: Size.zero,
      onPressed: total == 0
          ? null
          : left <= 0
          ? onDeselectAll
          : onSelectNext,
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
