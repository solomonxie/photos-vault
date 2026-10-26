import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:photos_vault/photos/words_file.dart';
import 'package:photos_vault/photos/words_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Writing _w(
  String id, {
  String text = 'hello',
  int? day,
  WritingKind kind = WritingKind.post,
}) => Writing(
  id: id,
  kind: kind,
  title: '',
  text: text,
  at: day == null ? null : DateTime(2012, 1, day),
);

void main() {
  setUpAll(sqfliteFfiInit);

  WordsStore newStore() {
    final store = WordsStore(
      databaseFactory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    addTearDown(store.close);
    return store;
  }

  test('lines without an id or text are skipped and counted', () {
    final export = readWordsLines(
      '{"id": "a", "kind": "blog", "text": "x", "at": "2013-12-23"}\n'
      'not json\n'
      '{"kind": "post", "text": "no id"}\n'
      '{"id": "b", "kind": "mystery", "text": "y"}\n',
    );
    expect(export.writings.map((w) => w.id), ['a', 'b']);
    expect(export.skipped, 2);
    expect(export.writings.first.at, DateTime(2013, 12, 23));
    expect(export.writings.last.kind, WritingKind.other);
  });

  test('a zip is read and its media extracted under the same paths', () async {
    final dir = await Directory.systemTemp.createTemp('words');
    addTearDown(() => dir.delete(recursive: true));
    final zip = p.join(dir.path, 'words.zip');
    final archive = Archive()
      ..add(
        ArchiveFile.string(
          'export/words.jsonl',
          '{"id": "a", "kind": "essay", "text": "![](media/a/1.jpg)"}\n',
        ),
      )
      ..add(ArchiveFile('export/media/a/1.jpg', 3, [1, 2, 3]));
    File(zip).writeAsBytesSync(ZipEncoder().encode(archive));

    final export = await readWordsFileHere(zip);
    expect(export.writings.single.id, 'a');
    expect(export.mediaFiles, 1);

    final root = p.join(dir.path, 'root');
    expect(await extractWordsMediaHere(zip, root), 1);
    expect(File(p.join(root, 'media/a/1.jpg')).readAsBytesSync(), [1, 2, 3]);
  });

  test('re-importing replaces by id, never duplicates', () async {
    final store = newStore();
    await store.insert('p1', [_w('a'), _w('b')]);
    await store.insert('p1', [_w('a', text: 'changed')]);
    expect(await store.countFor('p1'), 2);
    expect((await store.get('a'))!.text, 'changed');
  });

  test(
    'pages are newest first, undated last, filterable and searchable',
    () async {
      final store = newStore();
      await store.insert('p1', [
        _w('old', day: 1),
        _w('new', day: 9, text: 'needle 100%'),
        _w('none'),
        _w(
          'blog',
          day: 5,
          kind: WritingKind.blog,
          text: '![](media/blog/x.jpg) words',
        ),
      ]);
      final all = await store.page('p1');
      expect(all.map((w) => w.id), ['new', 'blog', 'old', 'none']);
      expect(all[1].hasMedia, isTrue);
      expect(all[1].excerpt, 'words');
      expect(
        (await store.page('p1', kind: WritingKind.blog)).map((w) => w.id),
        ['blog'],
      );
      expect((await store.page('p1', query: '100%')).map((w) => w.id), ['new']);
      expect((await store.page('p1', query: '%')).map((w) => w.id), ['new']);
      expect(await store.countsByKind('p1'), {
        WritingKind.post: 3,
        WritingKind.blog: 1,
      });
    },
  );

  test('merge moves writings; delete forgets them and their media', () async {
    final store = newStore();
    final root = await Directory.systemTemp.createTemp('words-media');
    addTearDown(() => root.delete(recursive: true));
    final media = Directory(p.join(root.path, 'media', 'a'))
      ..createSync(recursive: true);
    await store.insert('p1', [_w('a', text: '![](media/a/1.jpg)')]);
    await store.movePerson('p1', 'p2');
    expect(await store.countFor('p1'), 0);
    expect(await store.countFor('p2'), 1);
    await store.forgetPerson('p2', mediaRoot: root.path);
    expect(await store.countFor('p2'), 0);
    expect(media.existsSync(), isFalse);
  });
}
