import 'dart:io';
import 'dart:typed_data';

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

  test('conversations move First met back; Last seen is worked out', () async {
    final store = newStore();
    final people = FakePersonStore();
    final mia = await people.create(name: 'Mia');
    DateTime? fixed(List<PersonEvent> e, PersonEventType t) =>
        e.where((x) => x.type == t).single.at;

    await people.markMet(mia.id, DateTime(2009, 8, 17, 22, 3));
    await store.insert(mia.id, [_m(1, 'a'), _m(4, 'b')]);
    expect(await applyConversationSpans(people, store: store), isTrue);
    var events = await people.eventsFor(mia.id);
    expect(
      fixed(events, PersonEventType.firstMet),
      DateTime(2009, 8, 17, 22, 1),
    );
    expect(events.where((e) => e.isLastSeen), isEmpty);
    expect(await store.latestFor(mia.id), DateTime(2009, 8, 17, 22, 4));

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
    expect(await store.latestFor(mia.id), DateTime(2009, 8, 17, 22, 9));
    expect(
      (await store.latestByPerson())[mia.id],
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

  test(
    'a thumbnail arriving later is added to a message already here',
    () async {
      final store = newStore();
      final plain = _m(1, 'pic');
      await store.insert('p1', [plain]);
      final withThumb = ConversationMessage(
        chat: plain.chat,
        source: plain.source,
        at: plain.at,
        fromMe: plain.fromMe,
        sender: plain.sender,
        text: plain.text,
        kind: 'image',
        hash: plain.hash,
        thumb: Uint8List.fromList([1, 2, 3]),
      );
      expect(await store.insert('p1', [withThumb]), 0);
      final page = await store.page('p1');
      expect(page.single.thumb, [1, 2, 3]);
    },
  );

  test('thumb is base64, with or without a data: prefix', () {
    final export = readConversationLines(
      '{"person": "A", "at": "2020-01-01T00:00:00", "thumb": "AQID"}\n'
      '{"person": "A", "at": "2020-01-01T00:00:01", "thumb": "data:image/jpeg;base64,AQID"}\n'
      '{"person": "A", "at": "2020-01-01T00:00:02", "thumb": "%%%"}\n',
    );
    final thumbs = export.people.single.messages.map((m) => m.thumb).toList();
    expect(thumbs[0], [1, 2, 3]);
    expect(thumbs[1], [1, 2, 3]);
    expect(thumbs[2], isNull);
  });

  test(
    'a v3 database (thumbnails as files) upgrades and keeps its messages',
    () async {
      final dir = await Directory.systemTemp.createTemp('conv');
      addTearDown(() => dir.delete(recursive: true));
      final path = '${dir.path}/c.db';
      final v3 = await databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 3,
          onCreate: (db, _) async {
            await db.execute(
              'CREATE TABLE span_pending (person_id TEXT PRIMARY KEY)',
            );
            await db.execute(
              'CREATE TABLE message (person_id TEXT NOT NULL, chat TEXT NOT NULL, '
              'source TEXT NOT NULL, at INTEGER NOT NULL, from_me INTEGER NOT NULL, '
              'sender TEXT NOT NULL, text TEXT NOT NULL, kind TEXT NOT NULL, '
              "hash TEXT PRIMARY KEY, media TEXT NOT NULL DEFAULT '')",
            );
          },
        ),
      );
      final m = _m(3, 'kept');
      await v3.insert('message', {
        'person_id': 'a',
        'chat': m.chat,
        'source': m.source,
        'at': m.at.millisecondsSinceEpoch,
        'from_me': m.fromMe ? 1 : 0,
        'sender': m.sender,
        'text': m.text,
        'kind': m.kind,
        'hash': m.hash,
      });
      await v3.close();
      final store = ConversationStore(
        databaseFactory: databaseFactoryFfi,
        path: path,
      );
      addTearDown(store.close);
      final page = await store.page('a');
      expect(page.single.text, 'kept');
      expect(page.single.thumb, isNull);
    },
  );
}
