import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/photos/person.dart';
import 'package:photos_vault/photos/person_store.dart';
import 'package:photos_vault/photos/work_history_file.dart';

import '../support/fake_person_store.dart';

const _file = '''
{"version": 1, "jobs": [
 {"employer": "Studio A", "start": "2015-03", "end": "present",
  "notes": "n", "fields": [{"label": "City", "value": "Beijing"}, {"label": "", "value": "x"}],
  "titles": [{"title": "Designer", "start": "2015-03"}],
  "projects": [{"name": "Brand", "tags": ["design", " "], "start": "2016"}],
  "awards": [{"title": "Best"}]},
 {"start": "2010"}
]}
''';

void main() {
  test('loose dates, ongoing ends, blank fields and nameless jobs', () {
    final file = WorkHistoryFile.parse(_file);
    final job = file.jobs.single;
    expect(job.title, 'Studio A');
    expect(job.startDate, DateTime(2015, 3));
    expect(job.endDate, isNull);
    expect(job.customFields.single.label, 'City');
    expect(job.titles.single.title, 'Designer');
    expect(job.projects.single.tags, ['design']);
    expect(job.projects.single.startDate, DateTime(2016));
    expect(job.awards.single.title, 'Best');
    expect(parseLooseDate('2012-03-15'), DateTime(2012, 3, 15));
    expect(parseLooseDate('present'), isNull);
  });

  test(
    'a re-import replaces the same employer and start year in place',
    () async {
      final store = FakePersonStore();
      final person = await store.create(name: 'Me');
      final file = WorkHistoryFile.parse(_file);
      expect(
        await importWorkHistory(
          store,
          person.id,
          file,
          scope: PersonScope.open,
        ),
        (1, 0),
      );
      expect(
        await importWorkHistory(
          store,
          person.id,
          file,
          scope: PersonScope.open,
        ),
        (0, 1),
      );
      final jobs = await store.historyFor(person.id, HistoryCategory.job);
      expect(jobs, hasLength(1));
      expect(jobs.single.personId, person.id);
    },
  );
}
