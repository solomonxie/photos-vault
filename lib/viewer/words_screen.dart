import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;

import '../l10n/app_localizations.dart';
import '../photos/person.dart';
import '../photos/words_file.dart';
import '../photos/words_store.dart';
import 'words_markdown.dart';

String writingKindLabel(AppLocalizations l10n, WritingKind kind) =>
    switch (kind) {
      WritingKind.blog => l10n.wordsKindBlog,
      WritingKind.post => l10n.wordsKindPost,
      WritingKind.essay => l10n.wordsKindEssay,
      WritingKind.fiction => l10n.wordsKindFiction,
      WritingKind.paper => l10n.wordsKindPaper,
      WritingKind.thesis => l10n.wordsKindThesis,
      WritingKind.report => l10n.wordsKindReport,
      WritingKind.email => l10n.wordsKindEmail,
      WritingKind.note => l10n.wordsKindNote,
      WritingKind.other => l10n.wordsKindOther,
    };

/// A person's writings, newest first, a page of [_pageSize] at a time.
class WordsScreen extends StatefulWidget {
  const WordsScreen({
    super.key,
    required this.person,
    required this.store,
    this.kind,
  });

  final Person person;
  final WordsStore store;
  final WritingKind? kind;

  @override
  State<WordsScreen> createState() => _WordsScreenState();
}

class _WordsScreenState extends State<WordsScreen> {
  static const _pageSize = 100;

  final List<WritingSummary> _items = [];
  final _scroll = ScrollController();
  final _query = TextEditingController();
  Timer? _debounce;
  Map<WritingKind, int> _counts = const {};
  late WritingKind? _kind = widget.kind;
  bool _loading = false;
  bool _end = false;

  /// Bumped on every new filter, so a page for an old one is dropped.
  int _generation = 0;

  final _date = DateFormat.yMMMd();

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      final pos = _scroll.position;
      if (pos.pixels > pos.maxScrollExtent - 1200) _loadMore();
    });
    widget.store.countsByKind(widget.person.id).then((c) {
      if (mounted) setState(() => _counts = c);
    });
    _loadMore();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _scroll.dispose();
    _query.dispose();
    super.dispose();
  }

  void _restart() {
    _generation++;
    _items.clear();
    _end = false;
    _loading = false;
    _loadMore();
  }

  Future<void> _loadMore() async {
    if (_loading || _end) return;
    _loading = true;
    final generation = _generation;
    final page = await widget.store.page(
      widget.person.id,
      kind: _kind,
      query: _query.text,
      offset: _items.length,
      limit: _pageSize,
    );
    if (!mounted || generation != _generation) return;
    setState(() {
      _items.addAll(page);
      _end = page.length < _pageSize;
      _loading = false;
    });
  }

  void _search(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      if (mounted) setState(_restart);
    });
  }

  Widget _filters(AppLocalizations l10n) {
    final kinds = [
      for (final k in WritingKind.values)
        if ((_counts[k] ?? 0) > 0) k,
    ];
    if (kinds.length < 2) return const SizedBox.shrink();
    Widget chip(WritingKind? kind, String label) {
      final on = _kind == kind;
      return Padding(
        padding: const EdgeInsets.only(right: 8),
        child: CupertinoButton(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          minimumSize: const Size(0, 32),
          color: on
              ? CupertinoTheme.of(context).primaryColor
              : const Color(0xFF2C2C2E),
          borderRadius: BorderRadius.circular(16),
          onPressed: () => setState(() {
            _kind = kind;
            _restart();
          }),
          child: Text(
            label,
            style: const TextStyle(fontSize: 14, color: CupertinoColors.white),
          ),
        ),
      );
    }

    final total = _counts.values.fold(0, (a, b) => a + b);
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        children: [
          chip(null, '${l10n.wordsAll} $total'),
          for (final k in kinds)
            chip(k, '${writingKindLabel(l10n, k)} ${_counts[k]}'),
        ],
      ),
    );
  }

  Widget _row(AppLocalizations l10n, WritingSummary w) {
    final meta = [
      if (w.at != null) _date.format(w.at!),
      writingKindLabel(l10n, w.kind),
      if (w.source.isNotEmpty) w.source,
    ].join(' · ');
    final title = w.title.isNotEmpty ? w.title : null;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => Navigator.of(context).push(
        CupertinoPageRoute<void>(
          builder: (_) => WritingScreen(id: w.id, store: widget.store),
        ),
      ),
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        decoration: const BoxDecoration(
          border: Border(
            bottom: BorderSide(color: Color(0x33FFFFFF), width: 0.5),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (title != null)
              Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  color: CupertinoColors.white,
                ),
              ),
            if (w.excerpt.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  w.excerpt,
                  maxLines: title == null ? 4 : 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 15,
                    color: title == null
                        ? CupertinoColors.white
                        : CupertinoColors.systemGrey,
                  ),
                ),
              ),
            const SizedBox(height: 4),
            Row(
              children: [
                Flexible(
                  child: Text(
                    meta,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      color: CupertinoColors.systemGrey,
                    ),
                  ),
                ),
                if (w.hasMedia) ...[
                  const SizedBox(width: 6),
                  const Icon(
                    CupertinoIcons.photo,
                    size: 13,
                    color: CupertinoColors.systemGrey,
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(l10n.wordsTitle(widget.person.name)),
      ),
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: CupertinoSearchTextField(
                key: const ValueKey('wordsSearch'),
                autocorrect: false,
                controller: _query,
                placeholder: l10n.wordsSearch,
                onChanged: _search,
              ),
            ),
            _filters(l10n),
            Expanded(
              child: _items.isEmpty && _end
                  ? Center(
                      child: Text(
                        l10n.wordsNoResults,
                        style: const TextStyle(
                          color: CupertinoColors.systemGrey,
                        ),
                      ),
                    )
                  : CupertinoScrollbar(
                      controller: _scroll,
                      child: ListView.builder(
                        controller: _scroll,
                        itemCount: _items.length,
                        itemBuilder: (_, i) => _row(l10n, _items[i]),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One writing, read in full: its Markdown with pictures and videos.
class WritingScreen extends StatefulWidget {
  const WritingScreen({
    super.key,
    required this.id,
    required this.store,
    this.mediaRoot,
  });

  final String id;
  final WordsStore store;

  /// Overridable for tests; the app's words folder otherwise.
  final String? mediaRoot;

  @override
  State<WritingScreen> createState() => _WritingScreenState();
}

class _WritingScreenState extends State<WritingScreen> {
  Writing? _writing;
  List<MdBlock> _blocks = const [];
  String _root = '';
  final _recognizers = <TapGestureRecognizer>[];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final writing = await widget.store.get(widget.id);
    final root = widget.mediaRoot ?? await wordsMediaRoot();
    if (!mounted || writing == null) return;
    setState(() {
      _writing = writing;
      _blocks = parseMarkdown(writing.text);
      _root = root;
    });
  }

  @override
  void dispose() {
    for (final r in _recognizers) {
      r.dispose();
    }
    super.dispose();
  }

  static const _body = TextStyle(
    fontSize: 17,
    height: 1.55,
    color: CupertinoColors.white,
  );

  /// Built once per block: a link's recognizer lives until the page closes.
  final _spans = <(String, TextStyle), List<InlineSpan>>{};

  Widget _text(String text, TextStyle style) => Text.rich(
    TextSpan(
      style: style,
      children: _spans.putIfAbsent((
        text,
        style,
      ), () => inlineSpans(text, style, _recognizers)),
    ),
  );

  Widget _block(MdBlock block) => switch (block) {
    MdHeading(:final level, :final text) => Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 4),
      child: _text(
        text,
        _body.copyWith(
          fontSize: level <= 1 ? 24 : (level == 2 ? 21 : 18),
          fontWeight: FontWeight.w700,
          height: 1.3,
        ),
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
        style: const TextStyle(
          fontFamily: 'Menlo',
          fontSize: 14,
          color: CupertinoColors.white,
        ),
      ),
    ),
    MdRule() => Container(height: 0.5, color: CupertinoColors.systemGrey),
    MdMedia(:final path, :final alt, :final isVideo) =>
      path.startsWith('http')
          ? Text(
              alt.isNotEmpty ? alt : path,
              style: const TextStyle(color: CupertinoColors.systemGrey),
            )
          : isVideo
          ? WordsVideo(file: File(p.join(_root, path)), alt: alt)
          : WordsImage(file: File(p.join(_root, path)), alt: alt),
  };

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final w = _writing;
    return CupertinoPageScaffold(
      navigationBar: const CupertinoNavigationBar(),
      child: SafeArea(
        child: w == null
            ? const Center(child: CupertinoActivityIndicator())
            : ListView.builder(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
                itemCount: _blocks.length + 1,
                itemBuilder: (_, i) {
                  if (i == 0) {
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (w.title.isNotEmpty)
                            Text(
                              w.title,
                              style: const TextStyle(
                                fontSize: 26,
                                fontWeight: FontWeight.w700,
                                color: CupertinoColors.white,
                              ),
                            ),
                          const SizedBox(height: 6),
                          Text(
                            [
                              if (w.at != null)
                                DateFormat.yMMMMd().format(w.at!),
                              writingKindLabel(l10n, w.kind),
                              if (w.source.isNotEmpty) w.source,
                            ].join(' · '),
                            style: const TextStyle(
                              fontSize: 13,
                              color: CupertinoColors.systemGrey,
                            ),
                          ),
                        ],
                      ),
                    );
                  }
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 14),
                    child: _block(_blocks[i - 1]),
                  );
                },
              ),
      ),
    );
  }
}
