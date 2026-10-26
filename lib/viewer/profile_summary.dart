import 'package:flutter/cupertino.dart';

import '../l10n/app_localizations.dart';
import '../photos/person.dart';
import '../photos/person_detail.dart';
import 'profile_previews.dart' show HistoryTimeline;

/// Age, the job they're in now and the place they live last — the line a
/// person page and the top of the profile both lead with. Empty parts are
/// left out, so somebody with nothing filled in gets no line at all. The
/// profile leaves out the age: its own age row sits just above.
List<String> profileFacts(
  AppLocalizations l10n, {
  required PersonDetail detail,
  required List<PersonHistoryEntry> jobs,
  required List<PersonLocation> locations,
  bool withAge = true,
}) {
  final age = ageFrom(detail.birthDate);
  final job = HistoryTimeline.ordered(jobs)
      .where((e) => e.endDate == null)
      .firstOrNull;
  final role = job?.latestTitle?.title;
  PersonLocation? place;
  for (final l in locations) {
    if (place == null || l.since.isAfter(place.since)) place = l;
  }
  return [
    if (withAge && age != null) l10n.personProfileAgeValue(age),
    if (job != null)
      role != null && job.title.isNotEmpty
          ? l10n.profileJobAt(role, job.title)
          : (role ?? job.title),
    ?place?.place,
  ];
}

class ProfileCount {
  const ProfileCount(this.key, this.icon, this.label, this.onTap);

  final Key key;
  final IconData icon;
  final String label;
  final VoidCallback onTap;
}

/// The card under the name: facts on one line, known-since and last
/// contact on the next, then counts that each jump to their section.
class ProfileSummaryCard extends StatelessWidget {
  const ProfileSummaryCard({
    super.key,
    required this.facts,
    required this.since,
    required this.counts,
  });

  final List<String> facts;

  /// "Known since 2009 · Last contact 3 Oct 2026", either part optional.
  final List<String> since;
  final List<ProfileCount> counts;

  @override
  Widget build(BuildContext context) {
    if (facts.isEmpty && since.isEmpty && counts.isEmpty) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Container(
        key: const ValueKey('profileSummary'),
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: const BoxDecoration(
          color: Color(0xFF2C2C2E),
          borderRadius: BorderRadius.all(Radius.circular(12)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (facts.isNotEmpty)
              Text(facts.join(' · '), style: const TextStyle(fontSize: 15)),
            if (since.isNotEmpty)
              Padding(
                padding: EdgeInsets.only(top: facts.isEmpty ? 0 : 4),
                child: Text(
                  since.join(' · '),
                  style: const TextStyle(
                    fontSize: 13,
                    color: CupertinoColors.systemGrey,
                  ),
                ),
              ),
            if (counts.isNotEmpty)
              Padding(
                padding: EdgeInsets.only(
                  top: facts.isEmpty && since.isEmpty ? 0 : 10,
                ),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [for (final c in counts) _chip(c)],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _chip(ProfileCount c) => GestureDetector(
    key: c.key,
    onTap: c.onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: CupertinoColors.activeBlue.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(c.icon, size: 14, color: CupertinoColors.activeBlue),
          const SizedBox(width: 5),
          Text(
            c.label,
            style: const TextStyle(
              fontSize: 13,
              color: CupertinoColors.activeBlue,
            ),
          ),
        ],
      ),
    ),
  );
}

/// The pinned row of section chips; tapping one scrolls to it.
class ProfileJumpBar extends SliverPersistentHeaderDelegate {
  ProfileJumpBar(this.items, this.onJump);

  static const height = 44.0;

  final List<(String, String)> items;
  final ValueChanged<String> onJump;

  @override
  double get minExtent => height;
  @override
  double get maxExtent => height;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlaps) =>
      Container(
        color: CupertinoColors.black,
        alignment: Alignment.centerLeft,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              for (final (id, label) in items)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: CupertinoButton(
                    key: ValueKey('profileJump:$id'),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    minimumSize: const Size(0, 30),
                    color: const Color(0xFF2C2C2E),
                    borderRadius: BorderRadius.circular(15),
                    onPressed: () => onJump(id),
                    child: Text(
                      label,
                      style: const TextStyle(
                        fontSize: 14,
                        color: CupertinoColors.white,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      );

  @override
  bool shouldRebuild(ProfileJumpBar old) =>
      old.items.length != items.length || old.onJump != onJump;
}
