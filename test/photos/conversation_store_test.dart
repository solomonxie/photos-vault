import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/photos/conversation_file.dart';
import 'package:photos_vault/photos/conversation_store.dart';
import 'package:photos_vault/photos/person_detail.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../support/fake_person_store.dart';

ConversationMessage _m(int minute, String text, {String chat = 'qq:1'}) {
  final at = DateTime(2009, 8, 17, 22, minute);
  return ConversationMessage(
    chat: chat,
    source: chat.split(':').first,
    at: at,
    fromMe: minute.isEven,
    sender: 'x',
    text: text,
    kind: 'text',
    hash: ConversationMessage.hashOf(chat, at, minute.isEven, text),
  );
}

void main() {
  setUpAll(sqfliteFfiInit);

  ConversationStore newStore() {
    final store = ConversationStore(
      databaseFactory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    addTearDown(store.close);
    return store;
  }

  test('re-importing the same messages adds none', () async {
    final store = newStore();
    final messages = [for (var i = 0; i < 2500; i++) _m(i % 60, 'm$i')];
    var progress = <int>[];
    expect(await store.insert('a', messages, onProgress: progress.add), 2500);
    expect(progress, [1000, 2000, 2500]);
    progress = [];
    expect(await store.insert('a', messages), 0);
    expect(await store.countsByPerson(), {'a': 2500});
  });

  test('pages run newest first and lose nothing at a boundary', () async {
    final store = newStore();
    // Several in one minute, so a page edge falls inside equal times.
    await store.insert('a', [for (var i = 0; i < 25; i++) _m(i ~/ 4, 't$i')]);
    final seen = <String>[];
    ConversationMessage? before;
    while (true) {
      final page = await store.page('a', before: before, limit: 7);
      if (page.isEmpty) break;
      seen.addAll(page.map((m) => m.hash));
      before = page.last;
    }
    expect(seen.length, 25);
    expect(seen.toSet().length, 25);
    final first = await store.page('a', limit: 1);
    expect(first.single.at, DateTime(2009, 8, 17, 22, 6));
  });

  test(
    'search finds text, newest first, with LIKE characters literal',
    () async {
      final store = newStore();
      await store.insert('a', [
        _m(1, '在么 小波波'),
        _m(2, '100% sure'),
        _m(3, '在吗'),
      ]);
      expect((await store.search('a', '在')).map((m) => m.text), [
        '在吗',
        '在么 小波波',
      ]);
      expect((await store.search('a', '%')).map((m) => m.text), ['100% sure']);
      expect(await store.search('b', '在'), isEmpty);
    },
  );

  test('merge moves conversations; delete forgets them', () async {
    final store = newStore();
    await store.insert('gone', [_m(1, 'a'), _m(2, 'b', chat: 'sms:1')]);
    await store.insert('keep', [_m(3, 'c')]);
    await store.movePerson('gone', 'keep');
    expect(await store.countsByPerson(), {'keep': 3});
    expect((await store.chatsOf('keep')).length, 2);
    await store.forgetPerson('keep');
    expect(await store.countFor('keep'), 0);
  });

  test('conversations move First met back and Last seen up', () async {
    final store = newStore();
    final people = FakePersonStore();
    final mia = await people.create(name: 'Mia');
    DateTime? fixed(List<PersonEvent> e, PersonEventType t) =>
        e.where((x) => x.type == t).single.at;

    await people.markMet(mia.id, DateTime(2009, 8, 17, 22, 3));
    await people.markSeen(mia.id, DateTime(2009, 8, 17, 22, 5));
    await store.insert(mia.id, [_m(1, 'a'), _m(4, 'b')]);
    expect(await applyConversationSpans(people, store: store), isTrue);
    var events = await people.eventsFor(mia.id);
    expect(
      fixed(events, PersonEventType.firstMet),
      DateTime(2009, 8, 17, 22, 1),
    );
    expect(
      fixed(events, PersonEventType.lastSeen),
      DateTime(2009, 8, 17, 22, 5),
      reason: 'a photo later than the chat stays',
    );

    expect(await applyConversationSpans(people, store: store), isFalse);
    await store.insert(mia.id, [_m(1, 'a')]);
    expect(
      await applyConversationSpans(people, store: store),
      isFalse,
      reason: 'nothing new, nothing flagged',
    );

    final other = await people.create(name: 'M');
    await store.insert(other.id, [_m(9, 'c')]);
    await store.movePerson(other.id, mia.id);
    await people.remove(other.id);
    expect(await applyConversationSpans(people, store: store), isTrue);
    events = await people.eventsFor(mia.id);
    expect(
      fixed(events, PersonEventType.lastSeen),
      DateTime(2009, 8, 17, 22, 9),
    );
  });

  test('an older database flags everyone once', () async {
    final dir = await Directory.systemTemp.createTemp('conv');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/c.db';
    final v1 = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, _) => db.execute(
          'CREATE TABLE message (person_id TEXT NOT NULL, chat TEXT NOT NULL, '
          'source TEXT NOT NULL, at INTEGER NOT NULL, from_me INTEGER NOT NULL, '
          'sender TEXT NOT NULL, text TEXT NOT NULL, kind TEXT NOT NULL, '
          'hash TEXT PRIMARY KEY)',
        ),
      ),
    );
    await v1.insert('message', {
      'person_id': 'a',
      'chat': 'qq:1',
      'source': 'qq',
      'at': DateTime(2009).millisecondsSinceEpoch,
      'from_me': 0,
      'sender': 'x',
      'text': 't',
      'kind': 'text',
      'hash': 'h',
    });
    await v1.close();
    final store = ConversationStore(
      databaseFactory: databaseFactoryFfi,
      path: path,
    );
    addTearDown(store.close);
    expect(await store.pendingSpans(), {'a': (DateTime(2009), DateTime(2009))});
  });
}
