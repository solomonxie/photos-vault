import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../photos/album_suggestions.dart';
import '../settings/settings_section.dart';
import '../storage/album_store.dart';
import '../storage/asset_record_store.dart';
import 'asset_grid.dart';
import 'asset_group_screen.dart';

/// Busy days in no album, each one tap from an album or the Archive. What
/// is done or waved off drops out.
class AlbumSuggestionsScreen extends StatefulWidget {
  const AlbumSuggestionsScreen({
    super.key,
    required this.suggestions,
    required this.assetRecordStore,
    required this.albumStore,
  });

  final List<AlbumSuggestion> suggestions;
  final AssetRecordStore assetRecordStore;
  final AlbumStore albumStore;

  @override
  State<AlbumSuggestionsScreen> createState() => _AlbumSuggestionsScreenState();
}

class _AlbumSuggestionsScreenState extends State<AlbumSuggestionsScreen> {
  late List<AlbumSuggestion> _left = widget.suggestions;

  void _drop(AlbumSuggestion s) {
    setState(
      () => _left = [
        for (final x in _left)
          if (x.key != s.key) x,
      ],
    );
    if (_left.isEmpty) Navigator.of(context).pop();
  }

  static String dateRange(BuildContext context, AlbumSuggestion s) {
    final locale = Localizations.localeOf(context).toLanguageTag();
    final day = DateFormat.yMMMd(locale);
    return s.days == 1
        ? day.format(s.first)
        : '${day.format(s.first)} – ${day.format(s.last)}';
  }

  Future<void> _createAlbum(AlbumSuggestion s) async {
    final l10n = AppLocalizations.of(context)!;
    final range = dateRange(context, s);
    final controller = TextEditingController(
      text: s.place == null ? range : '${s.place}, $range',
    );
    final name = await showCupertinoDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => CupertinoAlertDialog(
          title: Text(l10n.albumsNewTitle),
          content: Padding(
            padding: const EdgeInsets.only(top: 12),
            child: CupertinoTextField(
              controller: controller,
              autofocus: true,
              placeholder: l10n.albumsNewNamePlaceholder,
              onChanged: (_) => setState(() {}),
            ),
          ),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(l10n.actionCancel),
            ),
            CupertinoDialogAction(
              isDefaultAction: true,
              onPressed: controller.text.trim().isEmpty
                  ? null
                  : () => Navigator.of(context).pop(controller.text.trim()),
              child: Text(l10n.actionAdd),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    if (name == null || name.isEmpty) return;
    final album = await widget.albumStore.upsert(
      id: widget.albumStore.newId(),
      name: name,
    );
    await widget.albumStore.addAssets(
      album.id,
      s.records.map((r) => r.localId),
    );
    if (mounted) _drop(s);
  }

  Future<void> _archive(AlbumSuggestion s) async {
    await widget.assetRecordStore.setArchived(
      s.records.map((r) => r.localId),
      true,
    );
    if (mounted) _drop(s);
  }

  Future<void> _dismiss(AlbumSuggestion s) async {
    final store = widget.assetRecordStore;
    final raw = await store.getAppState(AlbumSuggestions.dismissedKey);
    final keys = raw == null
        ? <String>{}
        : (jsonDecode(raw) as List<dynamic>).cast<String>().toSet();
    keys.add(s.key);
    await store.setAppState(
      AlbumSuggestions.dismissedKey,
      jsonEncode(keys.toList()),
    );
    if (mounted) _drop(s);
  }

  void _review(AlbumSuggestion s) => Navigator.of(context).push(
    CupertinoPageRoute<void>(
      builder: (_) => AssetGroupScreen(
        title: dateRange(context, s),
        records: s.records,
        assetRecordStore: widget.assetRecordStore,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return CupertinoPageScaffold(
      backgroundColor: settingsPageBackground,
      navigationBar: CupertinoNavigationBar(
        backgroundColor: settingsPageBackground,
        middle: Text(l10n.albumSuggestionsTitle),
      ),
      child: SafeArea(
        child: ListView.separated(
          padding: const EdgeInsets.fromLTRB(
            settingsPagePadding,
            12,
            settingsPagePadding,
            32,
          ),
          itemCount: _left.length,
          separatorBuilder: (_, _) => const SizedBox(height: 12),
          itemBuilder: (context, i) => _SuggestionCard(
            key: ValueKey('album-suggestion-${_left[i].key}'),
            suggestion: _left[i],
            title: dateRange(context, _left[i]),
            onReview: () => _review(_left[i]),
            onCreate: () => _createAlbum(_left[i]),
            onArchive: () => _archive(_left[i]),
            onDismiss: () => _dismiss(_left[i]),
          ),
        ),
      ),
    );
  }
}

class _SuggestionCard extends StatelessWidget {
  const _SuggestionCard({
    super.key,
    required this.suggestion,
    required this.title,
    required this.onReview,
    required this.onCreate,
    required this.onArchive,
    required this.onDismiss,
  });

  final AlbumSuggestion suggestion;
  final String title;
  final VoidCallback onReview;
  final VoidCallback onCreate;
  final VoidCallback onArchive;
  final VoidCallback onDismiss;

  static const _shown = 5;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final s = suggestion;
    final decode = (64 * MediaQuery.devicePixelRatioOf(context)).round();
    final step = s.records.length <= _shown ? 1 : s.records.length ~/ _shown;
    final sample = [
      for (var i = 0; i < s.records.length && i ~/ step < _shown; i += step)
        s.records[i],
    ];
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
      decoration: BoxDecoration(
        color: settingsControlFill,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(title, style: settingsRowTitleStyle)),
              CupertinoButton(
                padding: EdgeInsets.zero,
                minimumSize: const Size(30, 30),
                onPressed: onDismiss,
                child: Icon(
                  CupertinoIcons.xmark,
                  size: 16,
                  color: CupertinoColors.systemGrey,
                  semanticLabel: l10n.albumSuggestionDismiss,
                ),
              ),
            ],
          ),
          Text(
            [
              ?s.place,
              l10n.albumSuggestionCount(s.records.length, s.days),
            ].join(' · '),
            style: settingsHintStyle,
          ),
          const SizedBox(height: 10),
          GestureDetector(
            onTap: onReview,
            child: Row(
              children: [
                for (final r in sample)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: SizedBox.square(
                        dimension: 56,
                        child: assetImage(
                          r,
                          fileDecodeSize: decode,
                          placeholder: () => const ColoredBox(
                            color: CupertinoColors.systemGrey5,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Row(
            children: [
              CupertinoButton(
                key: ValueKey('album-suggestion-create-${s.key}'),
                padding: const EdgeInsets.only(right: 16),
                onPressed: onCreate,
                child: Text(
                  l10n.albumSuggestionCreate,
                  style: const TextStyle(fontSize: 15, color: settingsAccent),
                ),
              ),
              CupertinoButton(
                key: ValueKey('album-suggestion-archive-${s.key}'),
                padding: EdgeInsets.zero,
                onPressed: onArchive,
                child: Text(
                  l10n.archiveAction,
                  style: const TextStyle(fontSize: 15, color: settingsAccent),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
