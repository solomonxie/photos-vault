import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../photos/person.dart';
import '../photos/person_store.dart';
import '../photos/travel.dart';
import '../photos/travel_store.dart';
import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import 'asset_grid.dart';
import 'asset_group_screen.dart';
import 'asset_picker_screen.dart';
import 'person_picker_sheet.dart';
import 'place_screen.dart' show photosAtOn;
import 'words_markdown.dart';

/// "4 May 2024 · ★★★★☆", the line under an entry's title.
String travelEntryLine(TravelEntry e) => [
  if (e.at != null) DateFormat.yMMMd().format(e.at!),
  if (e.rating != null) '★' * e.rating! + '☆' * (5 - e.rating!),
].join(' · ');

/// One entry, read: title, date, rating, tags, the Markdown, who and what
/// is linked. Edit opens [TravelEntryEditor]. Pops true if it changed.
class TravelEntryScreen extends StatefulWidget {
  const TravelEntryScreen({
    super.key,
    required this.travelStore,
    required this.entryId,
    required this.placeName,
    this.assetRecordStore,
    this.personStore,
  });

  final TravelStore travelStore;
  final String entryId;
  final String placeName;
  final AssetRecordStore? assetRecordStore;
  final PersonStore? personStore;

  @override
  State<TravelEntryScreen> createState() => _TravelEntryScreenState();
}

class _TravelEntryScreenState extends State<TravelEntryScreen> {
  TravelEntry? _entry;
  List<TravelLink> _links = const [];
  Map<String, String> _names = const {};
  List<AssetRecord> _photos = const [];
  bool _changed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final entry = await widget.travelStore.entry(widget.entryId);
    if (entry == null) {
      if (mounted) Navigator.of(context).pop(true);
      return;
    }
    final links =
        (await widget.travelStore.linksFor(LinkOwner.entry, [
          entry.id,
        ]))[entry.id] ??
        const [];
    final names = await _personNames(widget.personStore, links);
    final photos =
        await widget.assetRecordStore?.listOf(_assetIds(links)) ??
        const <AssetRecord>[];
    if (!mounted) return;
    setState(() {
      _entry = entry;
      _links = links;
      _names = names;
      _photos = photos;
    });
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
          assetRecordStore: widget.assetRecordStore,
          personStore: widget.personStore,
        ),
      ),
    );
    if (changed != true) return;
    _changed = true;
    await _load();
  }

  Future<void> _openPhotos() async {
    final store = widget.assetRecordStore;
    if (store == null) return;
    await Navigator.of(context).push(
      CupertinoPageRoute(
        builder: (_) => AssetGroupScreen(
          title: _entry?.title.isNotEmpty == true
              ? _entry!.title
              : widget.placeName,
          records: _photos,
          assetRecordStore: store,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final e = _entry;
    final people = [
      for (final l in _links)
        if (l.target == LinkTarget.person) _names[l.id] ?? '?',
    ];
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
                    if (_photos.isNotEmpty) ...[
                      // The photos it's about, first: what it looked like.
                      SizedBox(
                        key: const ValueKey('travelEntryPhotos'),
                        height: 200,
                        child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          itemCount: _photos.length,
                          separatorBuilder: (_, _) => const SizedBox(width: 4),
                          itemBuilder: (context, i) => ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: AssetTile(
                              record: _photos[i],
                              extent: _photos.length == 1
                                  ? MediaQuery.sizeOf(context).width - 32
                                  : 200,
                              onTap: _openPhotos,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],
                    Text(
                      e.title.isEmpty ? l10n.travelEntryUntitled : e.title,
                      style: const TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (travelEntryLine(e) case final line
                        when line.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        line,
                        style: const TextStyle(
                          color: CupertinoColors.systemGrey,
                        ),
                      ),
                    ],
                    if (e.tags.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      _Chips(labels: e.tags),
                    ],
                    const SizedBox(height: 16),
                    TravelMarkdown(text: e.text),
                    if (people.isNotEmpty) ...[
                      const SizedBox(height: 20),
                      Text(
                        l10n.travelEntryPeople,
                        style: const TextStyle(
                          color: CupertinoColors.systemGrey,
                        ),
                      ),
                      const SizedBox(height: 6),
                      _Chips(labels: people),
                    ],
                  ],
                ),
        ),
      ),
    );
  }
}

/// Writes or edits one entry at a place. A new [entry] (from
/// `TravelStore.newEntry`) is saved on Save, not before. Pops true when
/// something was saved or deleted.
class TravelEntryEditor extends StatefulWidget {
  const TravelEntryEditor({
    super.key,
    required this.travelStore,
    required this.entry,
    required this.placeName,
    this.isNew = false,
    this.assetRecordStore,
    this.personStore,
    this.initialAssetIds = const [],
  });

  final TravelStore travelStore;
  final TravelEntry entry;
  final String placeName;
  final bool isNew;
  final AssetRecordStore? assetRecordStore;
  final PersonStore? personStore;

  /// Photos linked from the start: the one "Write about this place" was
  /// tapped on.
  final List<String> initialAssetIds;

  @override
  State<TravelEntryEditor> createState() => _TravelEntryEditorState();
}

class _TravelEntryEditorState extends State<TravelEntryEditor> {
  late final _title = TextEditingController(text: widget.entry.title);
  late final _text = TextEditingController(text: widget.entry.text);
  late final _tags = TextEditingController(text: widget.entry.tags.join(', '));
  late DateTime? _at = widget.entry.at;
  late int? _rating = widget.entry.rating;
  List<TravelLink> _links = const [];
  Map<String, String> _names = const {};
  bool _saving = false;

  /// Photos taken at this place on the entry's day, offered to link.
  List<AssetRecord> _suggested = const [];
  Place? _place;

  /// Everything but the text, folded until asked for; open when editing an
  /// entry that already has any of it.
  late bool _more =
      !widget.isNew &&
          (widget.entry.title.isNotEmpty ||
              widget.entry.tags.isNotEmpty ||
              widget.entry.rating != null) ||
      widget.initialAssetIds.isNotEmpty;

  bool get _impression => widget.entry.kind == EntryKind.impression;

  @override
  void initState() {
    super.initState();
    _links = [
      for (final id in widget.initialAssetIds) TravelLink(LinkTarget.asset, id),
    ];
    if (!widget.isNew) _loadLinks();
    _suggest();
  }

  Future<void> _suggest() async {
    final store = widget.assetRecordStore;
    final day = _at;
    if (store == null || day == null) {
      if (_suggested.isNotEmpty) setState(() => _suggested = const []);
      return;
    }
    final place = _place ??= await widget.travelStore.place(
      widget.entry.placeId,
    );
    if (place == null) return;
    final found = photosAtOn(place, await store.listAll(), day);
    if (mounted) setState(() => _suggested = found);
  }

  void _toggleSuggested(AssetRecord r) => setState(() {
    final link = TravelLink(LinkTarget.asset, r.localId);
    _links = _links.contains(link)
        ? [
            for (final l in _links)
              if (l != link) l,
          ]
        : [..._links, link];
  });

  void _addAllSuggested() => setState(() {
    final have = _assetIds(_links);
    _links = [
      ..._links,
      for (final r in _suggested)
        if (!have.contains(r.localId)) TravelLink(LinkTarget.asset, r.localId),
    ];
  });

  Widget _suggestions(AppLocalizations l10n) {
    final linked = _assetIds(_links);
    final day = DateFormat.MMMd().format(_at!);
    return Column(
      key: const ValueKey('travelEntrySuggested'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                l10n.travelEntrySuggested(day),
                style: const TextStyle(
                  color: CupertinoColors.systemGrey,
                  fontSize: 13,
                ),
              ),
            ),
            if (_suggested.any((r) => !linked.contains(r.localId)))
              CupertinoButton(
                key: const ValueKey('travelEntrySuggestedAll'),
                padding: EdgeInsets.zero,
                minimumSize: const Size(0, 30),
                onPressed: _addAllSuggested,
                child: Text(
                  l10n.travelEntrySuggestedAll,
                  style: const TextStyle(fontSize: 15),
                ),
              ),
          ],
        ),
        const SizedBox(height: 4),
        SizedBox(
          height: 76,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: _suggested.length,
            separatorBuilder: (_, _) => const SizedBox(width: 4),
            itemBuilder: (context, i) {
              final r = _suggested[i];
              final on = linked.contains(r.localId);
              return Stack(
                key: ValueKey('travelEntrySuggested-${r.localId}'),
                children: [
                  AssetTile(
                    record: r,
                    extent: 76,
                    onTap: () => _toggleSuggested(r),
                  ),
                  if (on)
                    const Positioned(
                      right: 4,
                      bottom: 4,
                      child: IgnorePointer(
                        child: Icon(
                          CupertinoIcons.check_mark_circled_solid,
                          color: CupertinoColors.activeBlue,
                          size: 22,
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  Future<void> _loadLinks() async {
    final links =
        (await widget.travelStore.linksFor(LinkOwner.entry, [
          widget.entry.id,
        ]))[widget.entry.id] ??
        const [];
    final names = await _personNames(widget.personStore, links);
    if (!mounted) return;
    setState(() {
      _links = {..._links, ...links}.toList();
      _names = names;
    });
  }

  @override
  void dispose() {
    _title.dispose();
    _text.dispose();
    _tags.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final saved = await widget.travelStore.saveEntry(
      widget.entry.copyWith(
        title: _title.text.trim(),
        text: _text.text,
        at: () => _at,
        rating: () => _impression ? _rating : null,
        tags: [
          for (final t in _tags.text.split(RegExp(r'[,，]')))
            if (t.trim().isNotEmpty) t.trim(),
        ],
      ),
    );
    await widget.travelStore.setLinks(LinkOwner.entry, saved.id, _links);
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
    await _suggest();
  }

  Future<void> _addPhotos() async {
    final store = widget.assetRecordStore;
    if (store == null) return;
    final l10n = AppLocalizations.of(context)!;
    final picked = await Navigator.of(context).push<List<AssetRecord>>(
      CupertinoPageRoute(
        builder: (_) => AssetPickerScreen(
          title: l10n.travelEntryAddPhotos,
          assetRecordStore: store,
          excludeIds: _assetIds(_links),
        ),
      ),
    );
    if (picked == null || picked.isEmpty || !mounted) return;
    setState(
      () => _links = [
        ..._links,
        for (final r in picked) TravelLink(LinkTarget.asset, r.localId),
      ],
    );
  }

  void _clearPhotos() => setState(
    () => _links = [
      for (final l in _links)
        if (l.target != LinkTarget.asset) l,
    ],
  );

  Future<void> _addPerson() async {
    final store = widget.personStore;
    if (store == null) return;
    final l10n = AppLocalizations.of(context)!;
    final linked = {
      for (final l in _links)
        if (l.target == LinkTarget.person) l.id,
    };
    final everyone = await store.listAll();
    if (!mounted) return;
    final Person? person = await showPersonPickerSheet(
      context: context,
      candidates: [
        for (final p in everyone)
          if (!linked.contains(p.id)) p,
      ],
      personStore: store,
      title: l10n.travelEntryAddPerson,
    );
    if (person == null || !mounted) return;
    setState(() {
      _links = [..._links, TravelLink(LinkTarget.person, person.id)];
      _names = {..._names, person.id: person.name};
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final photos = _assetIds(_links).length;
    const grey = TextStyle(color: CupertinoColors.systemGrey);
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(
          widget.isNew
              ? (_impression
                    ? l10n.travelEntryNewImpression
                    : l10n.travelEntryNewDiary)
              : widget.placeName,
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
            CupertinoTextField(
              key: const ValueKey('travelEntryText'),
              controller: _text,
              autofocus: widget.isNew,
              placeholder: l10n.travelEntryTextPlaceholder,
              minLines: 10,
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
            if (_suggested.isNotEmpty && _at != null) ...[
              const SizedBox(height: 12),
              _suggestions(l10n),
            ],
            const SizedBox(height: 12),
            CupertinoListTile(
              key: const ValueKey('travelEntryMore'),
              padding: const EdgeInsets.symmetric(horizontal: 4),
              title: Text(
                l10n.travelEntryMore,
                style: const TextStyle(color: CupertinoColors.activeBlue),
              ),
              subtitle: _more ? null : _summary(l10n, photos),
              trailing: Icon(
                _more ? CupertinoIcons.chevron_up : CupertinoIcons.chevron_down,
                size: 16,
                color: CupertinoColors.activeBlue,
              ),
              onTap: () => setState(() => _more = !_more),
            ),
            if (_more) ..._details(l10n, photos, grey),
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

  /// What the fold holds, in one grey line, so nothing filled is hidden.
  Widget? _summary(AppLocalizations l10n, int photos) {
    final people = _links.where((l) => l.target == LinkTarget.person).length;
    final parts = [
      if (_title.text.trim().isNotEmpty) _title.text.trim(),
      if (_at != null) DateFormat.yMMMd().format(_at!),
      if (_rating != null) '★' * _rating!,
      if (_tags.text.trim().isNotEmpty) _tags.text.trim(),
      if (people > 0) l10n.travelEntryPeopleCount(people),
      if (photos > 0) l10n.travelEntryPhotosCount(photos),
    ];
    return parts.isEmpty
        ? null
        : Text(parts.join(' · '), maxLines: 1, overflow: TextOverflow.ellipsis);
  }

  List<Widget> _details(AppLocalizations l10n, int photos, TextStyle grey) => [
    const SizedBox(height: 4),
    CupertinoTextField(
      key: const ValueKey('travelEntryTitle'),
      controller: _title,
      placeholder: l10n.travelEntryTitlePlaceholder,
    ),
    const SizedBox(height: 4),
    CupertinoListTile(
      key: const ValueKey('travelEntryDate'),
      padding: EdgeInsets.zero,
      title: Text(l10n.travelEntryDate),
      additionalInfo: Text(
        _at == null ? l10n.travelEntryNoDate : DateFormat.yMMMd().format(_at!),
      ),
      trailing: const CupertinoListTileChevron(),
      onTap: _pickDate,
    ),
    if (_impression) ...[
      Row(
        children: [
          Text(l10n.travelEntryRating),
          const Spacer(),
          for (var star = 1; star <= 5; star++)
            CupertinoButton(
              key: ValueKey('travelEntryStar$star'),
              padding: const EdgeInsets.symmetric(horizontal: 2),
              minimumSize: const Size(36, 36),
              onPressed: () =>
                  setState(() => _rating = _rating == star ? null : star),
              child: Icon(
                (_rating ?? 0) >= star
                    ? CupertinoIcons.star_fill
                    : CupertinoIcons.star,
                color: CupertinoColors.systemYellow,
              ),
            ),
        ],
      ),
      const SizedBox(height: 8),
      CupertinoTextField(
        key: const ValueKey('travelEntryTags'),
        controller: _tags,
        placeholder: l10n.travelEntryTagsPlaceholder,
        prefix: Padding(
          padding: const EdgeInsets.only(left: 8),
          child: Text(l10n.travelEntryTags, style: grey),
        ),
      ),
    ],
    if (widget.personStore != null) ...[
      const SizedBox(height: 16),
      Text(l10n.travelEntryPeople, style: grey),
      const SizedBox(height: 6),
      Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final l in _links)
            if (l.target == LinkTarget.person)
              _RemovableChip(
                label: _names[l.id] ?? '?',
                onRemove: () => setState(
                  () => _links = [
                    for (final x in _links)
                      if (x != l) x,
                  ],
                ),
              ),
          CupertinoButton(
            key: const ValueKey('travelEntryAddPerson'),
            padding: const EdgeInsets.symmetric(horizontal: 8),
            minimumSize: const Size(0, 30),
            onPressed: _addPerson,
            child: Text(l10n.travelEntryAddPerson),
          ),
        ],
      ),
    ],
    if (widget.assetRecordStore != null || photos > 0) ...[
      const SizedBox(height: 8),
      CupertinoListTile(
        key: const ValueKey('travelEntryPhotosRow'),
        padding: EdgeInsets.zero,
        leading: const Icon(CupertinoIcons.photo_on_rectangle),
        title: Text(l10n.travelEntryPhotosCount(photos)),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (photos > 0)
              CupertinoButton(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 30),
                onPressed: _clearPhotos,
                child: Text(l10n.travelEntryClearPhotos),
              ),
            if (widget.assetRecordStore != null)
              CupertinoButton(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 30),
                onPressed: _addPhotos,
                child: const Icon(CupertinoIcons.add),
              ),
          ],
        ),
      ),
    ],
  ];
}

Set<String> _assetIds(List<TravelLink> links) => {
  for (final l in links)
    if (l.target == LinkTarget.asset) l.id,
};

Future<Map<String, String>> _personNames(
  PersonStore? store,
  List<TravelLink> links,
) async {
  if (store == null || !links.any((l) => l.target == LinkTarget.person)) {
    return const {};
  }
  return {for (final p in await store.listAll()) p.id: p.name};
}

class _Chips extends StatelessWidget {
  const _Chips({required this.labels});

  final List<String> labels;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 6,
    runSpacing: 6,
    children: [for (final l in labels) _Chip(label: l)],
  );
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, this.trailing});

  final String label;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(
      color: CupertinoColors.tertiarySystemFill.resolveFrom(context),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: const TextStyle(fontSize: 14)),
        ?trailing,
      ],
    ),
  );
}

class _RemovableChip extends StatelessWidget {
  const _RemovableChip({required this.label, required this.onRemove});

  final String label;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onRemove,
    child: _Chip(
      label: label,
      trailing: const Padding(
        padding: EdgeInsets.only(left: 4),
        child: Icon(
          CupertinoIcons.xmark_circle_fill,
          size: 14,
          color: CupertinoColors.systemGrey,
        ),
      ),
    ),
  );
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
