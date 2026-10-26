import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'person.dart';
import 'person_store.dart';

/// A work-history file made on the Mac: jobs for the profile's Job
/// section.
///
/// ```json
/// {"version": 1, "jobs": [{"employer": "…", "start": "2012-03",
///   "end": "2013-05", "notes": "…", "fields": [{"label": "City", "value": "…"}],
///   "titles": [{"title": "…", "description": "…", "start": "…", "end": "…"}],
///   "projects": [{"name": "…", "description": "…", "tags": ["…"], …}],
///   "awards": [{"title": "…", …}]}]}
/// ```
/// Dates are `yyyy`, `yyyy-mm` or `yyyy-mm-dd`; an `end` of `null` or
/// `"present"` is ongoing.
class WorkHistoryFile {
  const WorkHistoryFile(this.jobs);

  /// With an empty `personId`: [importWorkHistory] gives them one.
  final List<PersonHistoryEntry> jobs;

  int get titles => jobs.fold(0, (n, j) => n + j.titles.length);
  int get projects => jobs.fold(0, (n, j) => n + j.projects.length);

  (DateTime?, DateTime?) get span {
    DateTime? lo, hi;
    for (final j in jobs) {
      final s = j.startDate;
      final e = j.endDate ?? j.startDate;
      if (s != null && (lo == null || s.isBefore(lo))) lo = s;
      if (e != null && (hi == null || e.isAfter(hi))) hi = e;
    }
    return (lo, hi);
  }

  static WorkHistoryFile parse(String text) {
    final root = jsonDecode(text);
    final list = root is Map ? root['jobs'] : root;
    if (list is! List) throw const FormatException('no "jobs" list');
    return WorkHistoryFile([
      for (final (i, j) in list.indexed)
        if (j is Map && _s(j['employer']).isNotEmpty) _job(j, i),
    ]);
  }

  static PersonHistoryEntry _job(Map j, int i) {
    final employer = _s(j['employer']);
    final start = parseLooseDate(j['start']);
    String sub(String kind, int n) => '${_id(employer, start)}-$kind$n';
    return PersonHistoryEntry(
      id: _id(employer, start),
      personId: '',
      category: HistoryCategory.job,
      title: employer,
      startDate: start,
      endDate: parseLooseDate(j['end']),
      notes: _s(j['notes']),
      customFields: [
        for (final f in _list(j['fields']))
          if (_s(f['label']).isNotEmpty && _s(f['value']).isNotEmpty)
            PersonCustomField(label: _s(f['label']), value: _s(f['value'])),
      ],
      titles: [
        for (final (n, t) in _list(j['titles']).indexed)
          _entry(sub('t', n), t, 'title'),
      ],
      projects: [
        for (final (n, p) in _list(j['projects']).indexed)
          CareerProject(
            id: sub('p', n),
            name: _s(p['name']),
            description: _s(p['description']),
            tags: [
              for (final t in p['tags'] is List ? p['tags'] as List : const [])
                if (t is String && t.trim().isNotEmpty) t.trim(),
            ],
            startDate: parseLooseDate(p['start']),
            endDate: parseLooseDate(p['end']),
          ),
      ],
      awards: [
        for (final (n, a) in _list(j['awards']).indexed)
          _entry(sub('a', n), a, 'title'),
      ],
    );
  }

  static TimelineEntry _entry(String id, Map m, String key) => TimelineEntry(
    id: id,
    title: _s(m[key]),
    description: _s(m['description']),
    startDate: parseLooseDate(m['start']),
    endDate: parseLooseDate(m['end']),
  );

  static String _id(String employer, DateTime? start) =>
      'job-${sha1.convert(utf8.encode('${employer.trim().toLowerCase()}|${start?.year ?? ''}')).toString().substring(0, 16)}';

  static String _s(Object? v) => v is String ? v.trim() : '';

  static List<Map> _list(Object? v) => [
    if (v is List)
      for (final x in v)
        if (x is Map) x,
  ];
}

/// `2012`, `2012-03`, `2012-03-15`; anything else (`present`, null) null.
DateTime? parseLooseDate(Object? v) {
  if (v is! String) return null;
  final m = RegExp(r'^(\d{4})(?:-(\d{1,2}))?(?:-(\d{1,2}))?')
      .firstMatch(v.trim());
  if (m == null) return null;
  return DateTime(
    int.parse(m[1]!),
    int.parse(m[2] ?? '1'),
    int.parse(m[3] ?? '1'),
  );
}

/// Writes [file]'s jobs onto [personId]. A job already there under the same
/// employer and start year is replaced in place, keeping its id; the rest
/// are added. Nothing is deleted. Returns (added, replaced).
Future<(int, int)> importWorkHistory(
  PersonStore store,
  String personId,
  WorkHistoryFile file, {
  required PersonScope scope,
}) async {
  final existing = await store.historyFor(
    personId,
    HistoryCategory.job,
    passcodeHash: scope.passcodeHash,
    keys: scope.keys,
  );
  String key(PersonHistoryEntry e) =>
      '${e.title.trim().toLowerCase()}|${e.startDate?.year ?? ''}';
  final byKey = {for (final e in existing) key(e): e};
  var added = 0, replaced = 0;
  for (final job in file.jobs) {
    final same = byKey[key(job)];
    same == null ? added++ : replaced++;
    await store.addHistoryEntry(
      PersonHistoryEntry(
        id: same?.id ?? job.id,
        personId: personId,
        category: HistoryCategory.job,
        title: job.title,
        startDate: job.startDate,
        endDate: job.endDate,
        notes: job.notes,
        customFields: job.customFields,
        titles: job.titles,
        projects: job.projects,
        awards: job.awards,
      ),
      scope: scope,
    );
  }
  return (added, replaced);
}
