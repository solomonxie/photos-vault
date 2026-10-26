import 'package:flutter/cupertino.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../photos/conversation_file.dart';
import '../photos/person.dart';
import '../photos/words_file.dart';
import 'profile_section.dart';
import 'words_screen.dart' show writingKindLabel;

/// What the profile shows of someone's chats: the latest message, how many
/// from each app.
class ChatsPreviewData {
  const ChatsPreviewData({
    required this.total,
    this.last,
    this.bySource = const {},
  });

  final int total;
  final ConversationMessage? last;
  final Map<String, int> bySource;

  static const empty = ChatsPreviewData(total: 0);
}

String chatSourceLabel(String source) => switch (source) {
  'whatsapp' => 'WhatsApp',
  'imessage' => 'iMessage',
  'messenger' => 'Messenger',
  'instagram' => 'Instagram',
  'wechat' => 'WeChat',
  'qq' => 'QQ',
  'sms' => 'SMS',
  _ => source,
};

class ChatsPreview extends StatelessWidget {
  const ChatsPreview({super.key, required this.data, required this.onOpen});

  final ChatsPreviewData data;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final last = data.last;
    final sources = data.bySource.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final number = NumberFormat.decimalPattern();
    return ProfileCard(
      children: [
        GestureDetector(
          key: const ValueKey('personConversationsRow'),
          behavior: HitTestBehavior.opaque,
          onTap: onOpen,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        l10n.personConversationsRow(data.total),
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                    const SizedBox(width: 6),
                    const Icon(
                      CupertinoIcons.chevron_forward,
                      size: 18,
                      color: CupertinoColors.systemGrey2,
                    ),
                  ],
                ),
                if (last != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    last.text.isEmpty ? last.kind : last.text,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 14),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${last.fromMe ? l10n.profileChatYou : last.sender} · '
                    '${DateFormat.yMMMd().format(last.at)}',
                    style: const TextStyle(
                      fontSize: 12,
                      color: CupertinoColors.systemGrey,
                    ),
                  ),
                ],
                if (sources.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final MapEntry(:key, :value) in sources)
                        _Pill(
                          '${chatSourceLabel(key)} ${number.format(value)}',
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: CupertinoColors.systemGrey.withValues(alpha: 0.22),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Text(
      text,
      style: const TextStyle(fontSize: 12, color: CupertinoColors.systemGrey),
    ),
  );
}

/// The latest three pieces, then "All N".
class WordsPreview extends StatelessWidget {
  const WordsPreview({
    super.key,
    required this.latest,
    required this.total,
    required this.onOpen,
    required this.onOpenAll,
  });

  final List<WritingSummary> latest;
  final int total;
  final ValueChanged<WritingSummary> onOpen;
  final VoidCallback onOpenAll;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return ProfileCard(
      children: [
        for (final w in latest)
          CupertinoListTile(
            title: Text(
              w.title.isEmpty ? w.excerpt : w.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              [
                writingKindLabel(l10n, w.kind),
                if (w.at != null) DateFormat.y().format(w.at!),
                if (w.title.isNotEmpty && w.excerpt.isNotEmpty) w.excerpt,
              ].join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            onTap: () => onOpen(w),
          ),
        CupertinoListTile(
          key: const ValueKey('personWordsAll'),
          title: Text(l10n.profileWordsAll(total)),
          trailing: const Icon(
            CupertinoIcons.chevron_forward,
            size: 18,
            color: CupertinoColors.systemGrey2,
          ),
          onTap: onOpenAll,
        ),
      ],
    );
  }
}

/// Jobs or schools as a line down the left: years, a dot, then the role
/// and where. Projects stay folded under their job until tapped.
class HistoryTimeline extends StatefulWidget {
  const HistoryTimeline({
    super.key,
    required this.entries,
    required this.onOpen,
  });

  final List<PersonHistoryEntry> entries;
  final ValueChanged<PersonHistoryEntry> onOpen;

  /// Ongoing first, then newest start.
  static List<PersonHistoryEntry> ordered(List<PersonHistoryEntry> entries) {
    int key(PersonHistoryEntry e) =>
        (e.endDate ?? DateTime(9999)).millisecondsSinceEpoch;
    return [...entries]..sort((a, b) {
      final end = key(b).compareTo(key(a));
      if (end != 0) return end;
      return (b.startDate ?? DateTime(0)).compareTo(a.startDate ?? DateTime(0));
    });
  }

  @override
  State<HistoryTimeline> createState() => _HistoryTimelineState();
}

class _HistoryTimelineState extends State<HistoryTimeline> {
  final _open = <String>{};

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final entries = HistoryTimeline.ordered(widget.entries);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: profileCardDecoration,
        child: Column(
          children: [
            for (final (i, e) in entries.indexed)
              _entry(l10n, e, last: i == entries.length - 1),
          ],
        ),
      ),
    );
  }

  Widget _entry(
    AppLocalizations l10n,
    PersonHistoryEntry e, {
    required bool last,
  }) {
    final start = e.startDate == null
        ? ''
        : DateFormat.y().format(e.startDate!);
    final end = e.endDate == null
        ? l10n.personHistoryPresentLabel
        : DateFormat.y().format(e.endDate!);
    final role = e.latestTitle?.title;
    final opened = _open.contains(e.id);
    const grey = TextStyle(fontSize: 12, color: CupertinoColors.systemGrey);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => widget.onOpen(e),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: 64,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 0, 0),
                child: Text(start.isEmpty ? end : '$start\n$end', style: grey),
              ),
            ),
            SizedBox(
              width: 20,
              child: Column(
                children: [
                  const SizedBox(height: 14),
                  Container(
                    width: 9,
                    height: 9,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: e.endDate == null
                          ? CupertinoColors.activeBlue
                          : CupertinoColors.systemGrey,
                    ),
                  ),
                  if (!last)
                    Expanded(
                      child: Container(
                        width: 1.5,
                        color: CupertinoColors.systemGrey.withValues(
                          alpha: 0.4,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(6, 8, 12, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      role ??
                          (e.title.isEmpty
                              ? l10n.personProfileNotSet
                              : e.title),
                      style: const TextStyle(fontSize: 16),
                    ),
                    if (role != null && e.title.isNotEmpty)
                      Text(
                        e.title,
                        style: const TextStyle(
                          fontSize: 14,
                          color: CupertinoColors.systemGrey,
                        ),
                      ),
                    if (e.projects.isNotEmpty)
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => setState(
                          () => opened ? _open.remove(e.id) : _open.add(e.id),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            '${l10n.profileProjects(e.projects.length)} '
                            '${opened ? '▾' : '▸'}',
                            style: const TextStyle(
                              fontSize: 13,
                              color: CupertinoColors.activeBlue,
                            ),
                          ),
                        ),
                      ),
                    if (opened)
                      for (final p in e.projects)
                        Padding(
                          padding: const EdgeInsets.only(top: 4, left: 8),
                          child: Text(
                            '• ${p.name}',
                            style: const TextStyle(fontSize: 13),
                          ),
                        ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
