import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/photos/conversation_file.dart';
import 'package:photos_vault/photos/import_log_backfill.dart';
import 'package:photos_vault/photos/person_store.dart';
import 'package:photos_vault/photos/words_file.dart';
import 'package:photos_vault/photos/words_store.dart';
import 'package:photos_vault/photos/work_history_file.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../support/fake_asset_record_store.dart';
import '../support/fake_conversation_store.dart';

ConversationMessage _m(String source, int minute) {
  final at = DateTime(2020, 1, 1, 10, minute);
  return ConversationMessage(
    chat: '$source:1',
    source: source,
    at: at,
    fromMe: false,
    sender: 'x',
    text: 't$minute',
    kind: 'text',
    hash: ConversationMessage.hashOf('$source:1', at, false, 't$minute'),
  );
}

void main() {
  setUpAll(sqfliteFfiInit);

  test(
    'once: chats by source, writings and jobs; logged ones skipped',
    () async {
      final dir = await Directory.systemTemp.createTemp('backfill');
      addTearDown(() => dir.delete(recursive: true));
      final people = PersonStore(
        databaseFactory: databaseFactoryFfi,
        path: inMemoryDatabasePath,
      );
      final chats = FakeConversationStore();
      final words = WordsStore(
        databaseFactory: databaseFactoryFfi,
        path: '${dir.path}/words.db',
      );
      addTearDown(() async {
        await people.close();
        await words.close();
      });
      final settings = FakeAssetRecordStore();
      final mia = await people.create(name: 'Mia');
      final zoe = await people.create(name: 'Zoe');
      await chats.insert(mia.id, [_m('wechat', 1), _m('qq', 2), _m('qq', 3)]);
      await chats.insert(zoe.id, [_m('sms', 4)]);
      await chats.insert('gone', [_m('sms', 5)]);
      await words.insert(mia.id, [
        const Writing(id: 'w1', kind: WritingKind.post, title: '', text: 'x'),
      ]);
      await importWorkHistory(
        people,
        mia.id,
        WorkHistoryFile.parse(
          '{"jobs": [{"employer": "A", "start": "2015"}, {"employer": "B"}]}',
        ),
        scope: PersonScope.open,
      );
      // Zoe's chats were already logged by the import itself.
      await people.logImports({
        zoe.id: {'source': 'chats', 'count': 1},
      });

      Future<int> run() => backfillImportLog(
        people: people,
        settings: settings,
        chats: chats,
        words: words,
      );
      expect(await run(), 3);
      expect(await run(), 0, reason: 'once');

      Map<String, Object?> line(List<PersonChange> c, String source) => c
          .where((x) => x.kind == 'imported')
          .map((x) => jsonDecode(x.after!) as Map<String, Object?>)
          .firstWhere((j) => j['source'] == source);
      final logged = await people.changesOf(mia.id);
      expect(line(logged, 'chats'), {
        'source': 'chats',
        'count': 3,
        'sources': ['qq', 'wechat'],
      });
      expect(line(logged, 'words'), {'source': 'words', 'count': 1});
      expect(line(logged, 'jobs'), {
        'source': 'jobs',
        'added': 2,
        'replaced': 0,
      });
      expect([
        for (final c in await people.changesOf(zoe.id))
          if (c.kind == 'imported') c,
      ], hasLength(1));
    },
  );
}
