import 'package:flutter/cupertino.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../photos/conversation_store.dart';
import '../photos/person.dart';
import '../photos/person_store.dart';
import '../settings/settings_section.dart';
import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import 'asset_group_screen.dart';
import 'person_event_sheet.dart' show eventTypeLabel;

/// One thing on a person's timeline: an event, a start or end, a move, a
/// month of photos or of messages.
class TimelineEntry {
  const TimelineEntry({
    required this.at,
    required this.icon,
    required this.title,
    this.detail = '',
    this.photos = const [],
    this.month = false,
  });

  final DateTime at;
  final IconData icon;
  final String title;
  final String detail;

  /// A month of photos opens onto them.
  final List<AssetRecord> photos;

  /// A month's worth, dated by the month alone.
  final bool month;
}

/// Everything dated about somebody, newest first, under year headings:
/// events, schools and jobs, moves, and a line a month for photos and for
/// messages rather than one per photo or message.
class PersonTimelineScreen extends StatefulWidget {
  const PersonTimelineScreen({
    super.key,
    required this.person,
    required this.personStore,
    required this.assetRecordStore,
    this.conversationStore,
  });

  final Person person;
  final PersonStore personStore;
  final AssetRecordStore assetRecordStore;

  /// Null opens the app's own.
  final ConversationStore? conversationStore;

  @override
  State<PersonTimelineScreen> createState() => _PersonTimelineScreenState();
}

class _PersonTimelineScreenState extends State<PersonTimelineScreen> {
  List<TimelineEntry>? _entries;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_entries == null) _load(AppLocalizations.of(context)!);
  }

  Future<void> _load(AppLocalizations l10n) async {
    final id = widget.person.id;
    final store = widget.personStore;
    final out = <TimelineEntry>[];

    for (final e in await store.eventsFor(id)) {
      if (e.at case final at?) {
        out.add(
          TimelineEntry(
            at: at,
            icon: CupertinoIcons.calendar,
            title: eventTypeLabel(l10n, e.type),
            detail: e.notes,
          ),
        );
      }
    }
    for (final category in HistoryCategory.values) {
      final label = category == HistoryCategory.education
          ? l10n.personProfileEducationLabel
          : l10n.personProfileJobLabel;
      final icon = category == HistoryCategory.education
          ? CupertinoIcons.book
          : CupertinoIcons.briefcase;
      for (final h in await store.historyFor(id, category)) {
        if (h.startDate case final at?) {
          out.add(
            TimelineEntry(
              at: at,
              icon: icon,
              title: l10n.timelineStarted(h.title),
              detail: label,
            ),
          );
        }
        if (h.endDate case final at?) {
          out.add(
            TimelineEntry(
              at: at,
              icon: icon,
              title: l10n.timelineLeft(h.title),
              detail: label,
            ),
          );
        }
      }
    }
    for (final loc in await store.locationsFor(id)) {
      out.add(
        TimelineEntry(
          at: loc.since,
          icon: CupertinoIcons.location,
          title: loc.place,
          detail: loc.kind == LocationKind.origin
              ? l10n.personProfileLocationOrigin
              : l10n.personProfileLocationRelocation,
        ),
      );
    }

    final visible = await widget.assetRecordStore.getVisibleByLocalIds(
      await store.localIdsIn(id),
    );
    final byMonth = <(int, int), List<AssetRecord>>{};
    for (final r in visible.values) {
      byMonth
          .putIfAbsent((r.createdAt.year, r.createdAt.month), () => [])
          .add(r);
    }
    for (final MapEntry(key: (y, m), value: photos) in byMonth.entries) {
      photos.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      out.add(
        TimelineEntry(
          at: DateTime(y, m),
          icon: CupertinoIcons.photo,
          title: l10n.mergeMovesPhotos(photos.length),
          photos: photos,
          month: true,
        ),
      );
    }

    try {
      final months = await (widget.conversationStore ?? ConversationStore())
          .monthsOf(id);
      for (final MapEntry(key: (y, m), value: n) in months.entries) {
        out.add(
          TimelineEntry(
            at: DateTime(y, m),
            icon: CupertinoIcons.chat_bubble_2,
            title: l10n.mergeMovesMessages(n),
            month: true,
          ),
        );
      }
    } catch (_) {
      // No conversations database: no messages to place.
    }

    out.sort((a, b) => b.at.compareTo(a.at));
    if (mounted) setState(() => _entries = out);
  }

  Future<void> _openPhotos(TimelineEntry e) => Navigator.of(context).push(
    CupertinoPageRoute<void>(
      builder: (_) => AssetGroupScreen(
        title: DateFormat.yMMMM().format(e.at),
        records: e.photos,
        assetRecordStore: widget.assetRecordStore,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final entries = _entries;
    return CupertinoPageScaffold(
      backgroundColor: settingsPageBackground,
      navigationBar: CupertinoNavigationBar(
        backgroundColor: settingsPageBackground,
        middle: Text(l10n.timelineTitle),
      ),
      child: SafeArea(
        child: entries == null
            ? const Center(child: CupertinoActivityIndicator())
            : entries.isEmpty
            ? Center(child: Text(l10n.timelineEmpty, style: settingsHintStyle))
            : ListView.builder(
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: entries.length,
                itemBuilder: (context, i) {
                  final e = entries[i];
                  final newYear = i == 0 || entries[i - 1].at.year != e.at.year;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (newYear)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                          child: Text(
                            '${e.at.year}',
                            style: settingsRowTitleStyle,
                          ),
                        ),
                      CupertinoListTile(
                        key: ValueKey('timeline-$i'),
                        backgroundColor: settingsPageBackground,
                        leading: Icon(
                          e.icon,
                          color: CupertinoColors.systemGrey,
                        ),
                        title: Text(e.title),
                        subtitle: Text(
                          [
                            (e.month ? DateFormat.yMMMM() : DateFormat.yMMMd())
                                .format(e.at),
                            if (e.detail.isNotEmpty) e.detail,
                          ].join(' · '),
                          maxLines: 2,
                        ),
                        trailing: e.photos.isEmpty
                            ? null
                            : const CupertinoListTileChevron(),
                        onTap: e.photos.isEmpty ? null : () => _openPhotos(e),
                      ),
                    ],
                  );
                },
              ),
      ),
    );
  }
}
