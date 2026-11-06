import 'person.dart';

/// [personId]'s Started could move back to [suggested], when [group] —
/// shared with the owner — began.
class StartedSuggestion {
  const StartedSuggestion({
    required this.personId,
    required this.current,
    required this.suggested,
    required this.group,
  });

  final String personId;
  final DateTime? current;
  final DateTime suggested;
  final PersonGroup group;
}

/// For everyone but [ownerId]: the earliest start of a group both they and
/// the owner are in, where that's earlier than their [started] (or they have
/// none). One pass over [groups]; no owner, no suggestions.
List<StartedSuggestion> startedSuggestions({
  required String? ownerId,
  required Map<PersonGroup, List<String>> groups,
  required Map<String, DateTime> started,
}) {
  if (ownerId == null) return const [];
  final best = <String, PersonGroup>{};
  for (final MapEntry(key: group, value: members) in groups.entries) {
    final start = group.start;
    if (start == null || !members.contains(ownerId)) continue;
    for (final id in members) {
      if (id == ownerId) continue;
      final had = best[id]?.start;
      if (had == null || start.isBefore(had)) best[id] = group;
    }
  }
  return [
    for (final MapEntry(key: id, value: group) in best.entries)
      if (started[id] == null || group.start!.isBefore(started[id]!))
        StartedSuggestion(
          personId: id,
          current: started[id],
          suggested: group.start!,
          group: group,
        ),
  ];
}
