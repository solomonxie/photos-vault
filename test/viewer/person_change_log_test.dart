import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/l10n/app_localizations.dart';
import 'package:photos_vault/photos/person_store.dart';
import 'package:photos_vault/viewer/life_imports.dart';
import 'package:photos_vault/viewer/person_change_log_screen.dart';

import '../support/fake_person_store.dart';

void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));

  List<String> imported(Map<String, Object?> after) {
    final (title, lines) = describeChange(
      l10n,
      PersonChange(
        at: DateTime(2026),
        kind: 'imported',
        after: jsonEncode(after),
      ),
      1,
      const {},
    );
    return [title, ...lines];
  }

  test('each import kind reads as a line of its own', () {
    expect(
      imported({
        'source': 'chats',
        'count': 12,
        'sources': ['qq', 'wechat'],
      }),
      ['Messages imported', '12 messages · QQ, WeChat'],
    );
    expect(imported({'source': 'words', 'count': 1}), [
      'Writings imported',
      '1 writing',
    ]);
    expect(imported({'source': 'jobs', 'added': 2, 'replaced': 1}), [
      'Jobs imported',
      '2 jobs added, 1 updated.',
    ]);
    expect(imported({'source': 'profile'}), ['Profile imported']);
    expect(imported({'source': 'people'}), ['Imported from a people zip']);
  });

  test('a jobs import lands in the change log', () async {
    final dir = await Directory.systemTemp.createTemp('jobs');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/jobs.json')
      ..writeAsStringSync(
        '{"version": 1, "jobs": [{"employer": "Studio A", "start": "2015"}]}',
      );
    final store = FakePersonStore();
    final me = await store.create(name: 'Me');
    final plan = await readWorkHistoryPlan(file.path, l10n, store);
    await plan.run(me.id, (_) {});
    final logged = (await store.changesOf(me.id)).first;
    expect(logged.kind, 'imported');
    expect(jsonDecode(logged.after!), {
      'source': 'jobs',
      'added': 1,
      'replaced': 0,
    });
  });
}
