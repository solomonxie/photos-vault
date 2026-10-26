import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:photos_vault/photos/conversation_file.dart';

const _lines = '''
{"person":"刘越","source":"qq","chat":"qq:1028853620","at":"2009-08-17T22:29:47","from_me":false,"sender":"刘越","text":"在么 小波波","kind":"text"}
{"person":"Mia","source":"sms","chat":"sms:+1555","at":"2020-01-02T09:00:00","from_me":true,"sender":"me","text":"line one\\nline two","kind":"text"}
not json
{"source":"qq","at":"2009-08-17T22:29:47"}
{"person":"刘越","chat":"wechat:wx1","at":"2008-01-01T00:00:00","from_me":true,"sender":"我","text":"","kind":"image"}

{"person":"mia","source":"sms","chat":"sms:+1555","at":"bad","text":"x"}
''';

void main() {
  test('groups by name, keeps the range, counts bad lines', () {
    final export = readConversationLines(_lines);
    expect(export.people.map((p) => p.name), ['刘越', 'Mia']);
    expect(export.skipped, 3);
    final liu = export.people.first;
    expect(liu.messages.length, 2);
    expect(liu.first, DateTime(2008));
    expect(liu.last, DateTime(2009, 8, 17, 22, 29, 47));
    final image = liu.messages.last;
    expect((image.source, image.kind, image.fromMe), ('wechat', 'image', true));
    expect(export.people.last.messages.single.text, 'line one\nline two');
  });

  test('a message dated in the future is a bad line', () {
    final export = readConversationLines(
      '{"person":"Mia","chat":"sms:1","at":"2999-01-01T00:00:00","text":"x"}\n'
      '{"person":"Mia","chat":"sms:1","at":"2020-01-01T00:00:00","text":"y"}\n',
    );
    expect(export.skipped, 1);
    expect(export.people.single.messages.single.text, 'y');
  });

  test('the same message hashes the same; another differs', () {
    final a = readConversationLines(_lines).people.first.messages.first;
    final b = readConversationLines(_lines).people.first.messages.first;
    expect(a.hash, b.hash);
    expect(
      a.hash,
      isNot(readConversationLines(_lines).people.first.messages.last.hash),
    );
  });

  test('reads .jsonl files and .jsonl inside a zip', () async {
    final dir = await Directory.systemTemp.createTemp('conv-');
    addTearDown(() => dir.delete(recursive: true));
    final plain = File(p.join(dir.path, 'a.jsonl'))..writeAsStringSync(_lines);
    final archive = Archive()
      ..add(ArchiveFile.bytes('x/b.jsonl', utf8.encode(_lines)))
      ..add(ArchiveFile.bytes('__MACOSX/x/._b.jsonl', utf8.encode('junk')))
      ..add(ArchiveFile.bytes('readme.txt', utf8.encode('hi')));
    final zip = File(p.join(dir.path, 'c.zip'))
      ..writeAsBytesSync(ZipEncoder().encode(archive));
    final export = await readConversationFiles([plain.path, zip.path]);
    expect(export.people.first.messages.length, 4);
    expect(export.skipped, 6);
  });
}
