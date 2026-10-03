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
  });

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
    if (left > selectAllLimit) return const SizedBox.shrink();
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
