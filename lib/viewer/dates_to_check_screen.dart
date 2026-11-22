import 'package:flutter/cupertino.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../photos/date_guess.dart';
import '../photos/library_metadata.dart';
import '../storage/asset_record_store.dart';
import 'asset_grid.dart';
import 'date_editor.dart';

/// Photos whose date looks wrong: those whose file name says another day,
/// each with that day one tap away, and those with no date of their own,
/// listed to be set by hand. A date set here is never questioned again.
class DatesToCheckScreen extends StatefulWidget {
  const DatesToCheckScreen({super.key, required this.store});

  final AssetRecordStore store;

  @override
  State<DatesToCheckScreen> createState() => _DatesToCheckScreenState();
}

class _DatesToCheckScreenState extends State<DatesToCheckScreen> {
  List<DateCheck>? _checks;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final checks = datesToCheck(await widget.store.listAll())
      ..sort((a, b) => a.record.createdAt.compareTo(b.record.createdAt));
    if (mounted) setState(() => _checks = checks);
  }

  Future<void> _set(Map<DateCheck, DateTime> dates) async {
    await setCreatedAtEverywhere(widget.store, {
      for (final MapEntry(key: c, value: at) in dates.entries) c.record: at,
    });
    await _load();
  }

  Future<void> _edit(DateCheck check) async {
    final l10n = AppLocalizations.of(context)!;
    final change = await showDateEditor(
      context,
      initial: check.record.createdAt,
      guesses: [
        if (check.proposed case final at?)
          (label: l10n.dateGuessFileName, date: at),
      ],
    );
    if (change == null) return;
    await _set({check: change(check.record.createdAt.toLocal())});
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final checks = _checks;
    final named = [
      for (final c in checks ?? const <DateCheck>[])
        if (c.reason == DateCheckReason.nameDisagrees) c,
    ];
    final bare = [
      for (final c in checks ?? const <DateCheck>[])
        if (c.reason == DateCheckReason.noOwnDate) c,
    ];
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(middle: Text(l10n.datesCheckTitle)),
      child: SafeArea(
        child: checks == null
            ? const Center(child: CupertinoActivityIndicator())
            : checks.isEmpty
            ? Center(
                child: Text(
                  l10n.datesNoneLeft,
                  style: const TextStyle(color: CupertinoColors.systemGrey),
                ),
              )
            : ListView(
                padding: const EdgeInsets.only(bottom: 32),
                children: [
                  if (named.isNotEmpty) ...[
                    _heading(l10n.datesNameSection, named.length),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: CupertinoButton.filled(
                        key: const ValueKey('datesUseAll'),
                        onPressed: () =>
                            _set({for (final c in named) c: c.proposed!}),
                        child: Text(l10n.datesUseAll),
                      ),
                    ),
                    const SizedBox(height: 8),
                    for (final c in named) _row(l10n, c),
                  ],
                  if (bare.isNotEmpty) ...[
                    _heading(l10n.datesNoDateSection, bare.length),
                    for (final c in bare) _row(l10n, c),
                  ],
                ],
              ),
      ),
    );
  }

  Widget _heading(String title, int count) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
    child: Text(
      '${title.toUpperCase()}  $count',
      style: const TextStyle(fontSize: 12, color: CupertinoColors.systemGrey),
    ),
  );

  Widget _row(AppLocalizations l10n, DateCheck c) {
    final day = DateFormat.yMMMd();
    final proposed = c.proposed;
    return GestureDetector(
      key: ValueKey('dateCheck:${c.record.localId}'),
      behavior: HitTestBehavior.opaque,
      onTap: () => _edit(c),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Row(
          children: [
            AssetTile(record: c.record, extent: 56, onTap: () => _edit(c)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    proposed == null
                        ? day.format(c.record.createdAt.toLocal())
                        : '${day.format(c.record.createdAt.toLocal())}'
                              '  →  ${day.format(proposed)}',
                    style: const TextStyle(
                      fontSize: 15,
                      color: CupertinoColors.white,
                    ),
                  ),
                  Text(
                    originalFileName(c.record) ?? '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      color: CupertinoColors.systemGrey,
                    ),
                  ),
                ],
              ),
            ),
            if (proposed != null)
              CupertinoButton(
                key: ValueKey('dateUse:${c.record.localId}'),
                padding: const EdgeInsets.only(left: 8),
                minimumSize: Size.zero,
                onPressed: () => _set({c: proposed}),
                child: Text(l10n.datesUse),
              ),
          ],
        ),
      ),
    );
  }
}
