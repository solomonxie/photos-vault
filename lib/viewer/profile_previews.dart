import 'package:flutter/cupertino.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../photos/person.dart';
import '../photos/travel.dart';
import 'profile_section.dart';
import 'route_screen.dart' show routeDates;

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

/// Routes, then diary entries and impressions, they're linked to.
class TravelsPreview extends StatelessWidget {
  const TravelsPreview({
    super.key,
    required this.routes,
    required this.entries,
    required this.places,
    required this.onOpenRoute,
    required this.onOpenEntry,
  });

  final List<TravelRoute> routes;
  final List<TravelEntry> entries;
  final Map<String, Place> places;
  final ValueChanged<TravelRoute> onOpenRoute;
  final ValueChanged<TravelEntry> onOpenEntry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    const chevron = Icon(
      CupertinoIcons.chevron_forward,
      size: 18,
      color: CupertinoColors.systemGrey2,
    );
    return ProfileCard(
      children: [
        for (final r in routes)
          CupertinoListTile(
            key: ValueKey('travelsRoute-${r.id}'),
            leading: const Icon(CupertinoIcons.map),
            title: Text(r.title.isEmpty ? l10n.routeUntitled : r.title),
            subtitle: routeDates(r).isEmpty ? null : Text(routeDates(r)),
            trailing: chevron,
            onTap: () => onOpenRoute(r),
          ),
        for (final e in entries)
          CupertinoListTile(
            key: ValueKey('travelsEntry-${e.id}'),
            leading: Icon(
              e.kind == EntryKind.impression
                  ? CupertinoIcons.star
                  : CupertinoIcons.book,
            ),
            title: Text(
              e.title.isNotEmpty ? e.title : places[e.placeId]?.name ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              [
                e.kind == EntryKind.impression
                    ? l10n.travelsImpression
                    : l10n.travelsDiary,
                if (e.title.isNotEmpty && places[e.placeId] != null)
                  places[e.placeId]!.name,
                if (e.at != null) DateFormat.yMMMd().format(e.at!),
              ].join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: chevron,
            onTap: () => onOpenEntry(e),
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
