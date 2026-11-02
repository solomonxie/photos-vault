import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../photos/travel.dart';
import '../photos/travel_store.dart';
import 'words_markdown.dart';

/// "4 May 2024": the day an impression is about.
String travelEntryLine(TravelEntry e) =>
    e.at == null ? '' : DateFormat.yMMMd().format(e.at!);

/// One impression, read: where, when, and what was written.
/// Edit opens [TravelEntryEditor]. Pops true if it changed.
class TravelEntryScreen extends StatefulWidget {
  const TravelEntryScreen({
    super.key,
    required this.travelStore,
    required this.entryId,
    required this.placeName,
  });

  final TravelStore travelStore;
  final String entryId;
  final String placeName;

  @override
  State<TravelEntryScreen> createState() => _TravelEntryScreenState();
}

class _TravelEntryScreenState extends State<TravelEntryScreen> {
  TravelEntry? _entry;
  bool _changed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final entry = await widget.travelStore.entry(widget.entryId);
    if (!mounted) return;
    if (entry == null) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() => _entry = entry);
  }

  Future<void> _edit() async {
    final entry = _entry;
    if (entry == null) return;
    final changed = await Navigator.of(context).push<bool>(
      CupertinoPageRoute(
        builder: (_) => TravelEntryEditor(
          travelStore: widget.travelStore,
          entry: entry,
          placeName: widget.placeName,
        ),
      ),
    );
    if (changed != true) return;
    _changed = true;
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final e = _entry;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.of(context).pop(_changed);
      },
      child: CupertinoPageScaffold(
        navigationBar: CupertinoNavigationBar(
          middle: Text(widget.placeName),
          trailing: CupertinoButton(
            key: const ValueKey('travelEntryEdit'),
            padding: EdgeInsets.zero,
            onPressed: e == null ? null : _edit,
            child: Text(l10n.travelEntryEdit),
          ),
        ),
        child: SafeArea(
          child: e == null
              ? const Center(child: CupertinoActivityIndicator())
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                  children: [
                    if (travelEntryLine(e) case final line
                        when line.isNotEmpty) ...[
                      Text(
                        line,
                        style: const TextStyle(
                          color: CupertinoColors.systemGrey,
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                    TravelMarkdown(text: e.text),
                  ],
                ),
        ),
      ),
    );
  }
}

/// Writes or edits one impression of a place: one box to write in, and
/// the day it's about. A new [entry] (from `TravelStore.newEntry`) is
/// saved on Save, not before. Pops true when something was saved or
/// deleted.
class TravelEntryEditor extends StatefulWidget {
  const TravelEntryEditor({
    super.key,
    required this.travelStore,
    required this.entry,
    required this.placeName,
    this.isNew = false,
  });

  final TravelStore travelStore;
  final TravelEntry entry;
  final String placeName;
  final bool isNew;

  @override
  State<TravelEntryEditor> createState() => _TravelEntryEditorState();
}

class _TravelEntryEditorState extends State<TravelEntryEditor> {
  late final _text = TextEditingController(text: widget.entry.text);
  late DateTime? _at = widget.entry.at;
  bool _saving = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    await widget.travelStore.saveEntry(
      widget.entry.copyWith(text: _text.text, at: () => _at),
    );
    if (mounted) Navigator.of(context).pop(true);
  }

  Future<void> _delete() async {
    final l10n = AppLocalizations.of(context)!;
    final ok = await showCupertinoDialog<bool>(
      context: context,
      builder: (dialog) => CupertinoAlertDialog(
        content: Text(l10n.travelEntryDeleteConfirm),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(dialog).pop(false),
            child: Text(l10n.actionCancel),
          ),
          CupertinoDialogAction(
            key: const ValueKey('travelEntryDeleteConfirm'),
            isDestructiveAction: true,
            onPressed: () => Navigator.of(dialog).pop(true),
            child: Text(l10n.travelEntryDelete),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await widget.travelStore.deleteEntry(widget.entry.id);
    if (mounted) Navigator.of(context).pop(true);
  }

  Future<void> _pickDate() async {
    final l10n = AppLocalizations.of(context)!;
    var picked = _at ?? DateTime.now();
    final result = await showCupertinoModalPopup<DateTime?>(
      context: context,
      builder: (sheet) => Container(
        height: 300,
        color: CupertinoColors.systemBackground.resolveFrom(sheet),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                CupertinoButton(
                  onPressed: () => Navigator.of(sheet).pop(DateTime(0)),
                  child: Text(l10n.travelEntryNoDate),
                ),
                CupertinoButton(
                  onPressed: () => Navigator.of(sheet).pop(picked),
                  child: Text(l10n.travelEntryDone),
                ),
              ],
            ),
            Expanded(
              child: CupertinoDatePicker(
                mode: CupertinoDatePickerMode.date,
                initialDateTime: picked,
                maximumDate: DateTime.now().add(const Duration(days: 365)),
                onDateTimeChanged: (d) => picked = d,
              ),
            ),
          ],
        ),
      ),
    );
    if (result == null || !mounted) return;
    setState(
      () => _at = result.year == 0
          ? null
          : DateTime(result.year, result.month, result.day),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(
          widget.isNew ? l10n.travelEntryNewImpression : widget.placeName,
        ),
        trailing: CupertinoButton(
          key: const ValueKey('travelEntrySave'),
          padding: EdgeInsets.zero,
          onPressed: _saving ? null : _save,
          child: Text(l10n.travelEntrySave),
        ),
      ),
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
          children: [
            // Where it's attached, and the day: tap the day to change it.
            CupertinoListTile(
              key: const ValueKey('travelEntryDate'),
              padding: const EdgeInsets.symmetric(horizontal: 4),
              leading: const Icon(
                CupertinoIcons.map_pin,
                color: CupertinoColors.systemRed,
              ),
              title: Text(widget.placeName),
              additionalInfo: Text(
                _at == null
                    ? l10n.travelEntryNoDate
                    : DateFormat.yMMMd().format(_at!),
              ),
              trailing: const CupertinoListTileChevron(),
              onTap: _pickDate,
            ),
            const SizedBox(height: 8),
            CupertinoTextField(
              key: const ValueKey('travelEntryText'),
              controller: _text,
              autofocus: widget.isNew,
              placeholder: l10n.travelEntryTextPlaceholder,
              minLines: 12,
              maxLines: null,
              keyboardType: TextInputType.multiline,
              padding: const EdgeInsets.all(14),
              style: const TextStyle(fontSize: 17, height: 1.4),
              decoration: BoxDecoration(
                color: CupertinoColors.secondarySystemGroupedBackground
                    .resolveFrom(context),
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            if (!widget.isNew) ...[
              const SizedBox(height: 24),
              CupertinoButton(
                key: const ValueKey('travelEntryDelete'),
                onPressed: _delete,
                child: Text(
                  l10n.travelEntryDelete,
                  style: const TextStyle(color: CupertinoColors.destructiveRed),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// An entry's Markdown, drawn like a writing under Words. Pictures in it
/// show as their alt text: an entry links library photos instead.
class TravelMarkdown extends StatefulWidget {
  const TravelMarkdown({super.key, required this.text});

  final String text;

  @override
  State<TravelMarkdown> createState() => _TravelMarkdownState();
}

class _TravelMarkdownState extends State<TravelMarkdown> {
  late List<MdBlock> _blocks = parseMarkdown(widget.text);
  final _recognizers = <TapGestureRecognizer>[];

  static const _body = TextStyle(
    fontSize: 17,
    height: 1.5,
    color: CupertinoColors.white,
  );

  @override
  void didUpdateWidget(TravelMarkdown old) {
    super.didUpdateWidget(old);
    if (old.text != widget.text) {
      _disposeRecognizers();
      _blocks = parseMarkdown(widget.text);
    }
  }

  void _disposeRecognizers() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  Widget _text(String text, TextStyle style) => Text.rich(
    TextSpan(style: style, children: inlineSpans(text, style, _recognizers)),
  );

  Widget _block(MdBlock block) => switch (block) {
    MdHeading(:final level, :final text) => _text(
      text,
      _body.copyWith(
        fontSize: level <= 1 ? 22 : (level == 2 ? 20 : 18),
        fontWeight: FontWeight.w700,
      ),
    ),
    MdParagraph(:final text, :final quote, :final bullet) =>
      quote
          ? Container(
              padding: const EdgeInsets.only(left: 12),
              decoration: const BoxDecoration(
                border: Border(
                  left: BorderSide(color: CupertinoColors.systemGrey, width: 3),
                ),
              ),
              child: _text(
                text,
                _body.copyWith(color: CupertinoColors.systemGrey),
              ),
            )
          : bullet != null
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: 24, child: Text(bullet, style: _body)),
                Expanded(child: _text(text, _body)),
              ],
            )
          : _text(text, _body),
    MdCode(:final text) => Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      color: const Color(0xFF2C2C2E),
      child: Text(
        text,
        style: const TextStyle(fontFamily: 'Menlo', fontSize: 14),
      ),
    ),
    MdRule() => Container(height: 0.5, color: CupertinoColors.systemGrey),
    MdMedia(:final path, :final alt) => Text(
      alt.isNotEmpty ? alt : path,
      style: const TextStyle(color: CupertinoColors.systemGrey),
    ),
  };

  @override
  Widget build(BuildContext context) {
    // Rebuilt spans would leak their recognizers: drop the old ones first.
    _disposeRecognizers();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final b in _blocks)
          Padding(padding: const EdgeInsets.only(bottom: 10), child: _block(b)),
      ],
    );
  }
}
