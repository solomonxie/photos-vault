import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../photos/conversation_file.dart';
import '../photos/conversation_store.dart';
import '../photos/person.dart';
import 'profile_previews.dart' show chatSourceLabel;

/// A person's imported chats, newest at the bottom. Pages of [_pageSize]
/// load as the list scrolls up, so 50k messages are never all in memory.
class ConversationScreen extends StatefulWidget {
  const ConversationScreen({
    super.key,
    required this.person,
    required this.store,
  });

  final Person person;
  final ConversationStore store;

  @override
  State<ConversationScreen> createState() => _ConversationScreenState();
}

class _ConversationScreenState extends State<ConversationScreen> {
  static const _pageSize = 200;

  /// Newest first: index 0 is the bottom of the reversed list.
  final List<ConversationMessage> _messages = [];
  final _scroll = ScrollController();
  final _query = TextEditingController();
  Timer? _debounce;

  bool _loading = false;
  bool _end = false;
  bool _severalChats = false;

  /// Search hits, newest first; null when not searching.
  List<ConversationMessage>? _hits;

  Widget _thumb(Uint8List bytes) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: GestureDetector(
        onTap: () => Navigator.of(context).push(
          CupertinoPageRoute<void>(
            fullscreenDialog: true,
            builder: (_) => CupertinoPageScaffold(
              backgroundColor: CupertinoColors.black,
              navigationBar: const CupertinoNavigationBar(),
              child: Center(child: Image.memory(bytes)),
            ),
          ),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Image.memory(
            bytes,
            width: 160,
            cacheWidth: (160 * dpr).round(),
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => const SizedBox.shrink(),
          ),
        ),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_maybeLoadOlder);
    _loadOlder();
    _loadChats();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _scroll.dispose();
    _query.dispose();
    super.dispose();
  }

  Future<void> _loadChats() async {
    final chats = await widget.store.chatsOf(widget.person.id);
    if (mounted && chats.length > 1) setState(() => _severalChats = true);
  }

  void _maybeLoadOlder() {
    final pos = _scroll.position;
    if (pos.pixels > pos.maxScrollExtent - 1500) _loadOlder();
  }

  Future<void> _loadOlder() async {
    if (_loading || _end) return;
    _loading = true;
    try {
      final page = await widget.store.page(
        widget.person.id,
        before: _messages.lastOrNull,
        limit: _pageSize,
      );
      if (!mounted) return;
      setState(() {
        _messages.addAll(page);
        _end = page.length < _pageSize;
      });
    } finally {
      _loading = false;
    }
  }

  void _search(String text) {
    _debounce?.cancel();
    if (text.trim().isEmpty) {
      setState(() => _hits = null);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 250), () async {
      final hits = await widget.store.search(widget.person.id, text);
      if (mounted && _query.text == text) setState(() => _hits = hits);
    });
  }

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  String _body(AppLocalizations l10n, ConversationMessage m) {
    if (m.text.isNotEmpty) return m.text;
    return switch (m.kind) {
      'image' => l10n.conversationsKindImage,
      'voice' => l10n.conversationsKindVoice,
      'file' => l10n.conversationsKindFile,
      _ => l10n.conversationsKindOther,
    };
  }

  static String _chatLabel(ConversationMessage m) {
    final source = chatSourceLabel(m.source);
    final colon = m.chat.indexOf(':');
    final id = colon < 0 ? m.chat : m.chat.substring(colon + 1);
    return id.isEmpty ? source : '$source · $id';
  }

  Widget _separator(String text) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 10),
    child: Center(
      child: Text(
        text,
        style: const TextStyle(fontSize: 12, color: CupertinoColors.systemGrey),
      ),
    ),
  );

  /// One each, not one per bubble: a format is costly to build.
  final _clock = DateFormat.jm();
  final _dated = DateFormat.yMMMd().add_jm();

  /// [dated] where there's no day separator above it: a search hit.
  Widget _bubble(
    AppLocalizations l10n,
    ConversationMessage m, {
    bool dated = false,
  }) {
    final mine = m.fromMe;
    final width = MediaQuery.sizeOf(context).width * 0.75;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(maxWidth: width),
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: mine
              ? CupertinoTheme.of(context).primaryColor
              : const Color(0xFF3A3A3C),
          borderRadius: const BorderRadius.all(Radius.circular(16)),
        ),
        // Intrinsic so the time can sit right under text narrower than it.
        child: IntrinsicWidth(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (m.thumb case final thumb?) _thumb(thumb),
              if (m.text.isNotEmpty || m.thumb == null)
                Text(
                  _body(l10n, m),
                  style: TextStyle(
                    fontSize: 16,
                    color: CupertinoColors.white,
                    fontStyle: m.text.isEmpty ? FontStyle.italic : null,
                  ),
                ),
              Text(
                (dated ? _dated : _clock).format(m.at),
                textAlign: TextAlign.end,
                style: const TextStyle(fontSize: 11, color: Color(0xB3FFFFFF)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _item(AppLocalizations l10n, int i) {
    final m = _messages[i];
    final older = i + 1 < _messages.length ? _messages[i + 1] : null;
    final newDay = older == null || !_sameDay(older.at, m.at);
    final newChat = _severalChats && (older == null || older.chat != m.chat);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (newDay && (older != null || _end))
          _separator(DateFormat.yMMMEd().format(m.at)),
        if (newChat) _separator(_chatLabel(m)),
        _bubble(l10n, m),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final hits = _hits;
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(middle: Text(widget.person.name)),
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
              child: CupertinoSearchTextField(
                autocorrect: false,
                key: const ValueKey('conversationSearch'),
                controller: _query,
                placeholder: l10n.conversationsSearch,
                onChanged: _search,
              ),
            ),
            Expanded(
              child: hits != null
                  ? hits.isEmpty
                        ? Center(
                            child: Text(
                              l10n.conversationsNoResults,
                              style: const TextStyle(
                                color: CupertinoColors.systemGrey,
                              ),
                            ),
                          )
                        : ListView.builder(
                            itemCount: hits.length,
                            itemBuilder: (_, i) => Padding(
                              padding: const EdgeInsets.symmetric(vertical: 4),
                              child: _bubble(l10n, hits[i], dated: true),
                            ),
                          )
                  : CupertinoScrollbar(
                      controller: _scroll,
                      child: ListView.builder(
                        controller: _scroll,
                        reverse: true,
                        itemCount: _messages.length,
                        itemBuilder: (_, i) => _item(l10n, i),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
