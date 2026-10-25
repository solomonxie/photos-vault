import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/photos/name_sound.dart';

bool finds(String name, String query) =>
    NameSound.of(name).answers(NameSound.of(query));

void main() {
  test('Chinese names by pinyin, from any syllable, or by initials', () {
    expect(finds('王小明', 'xiaoming'), isTrue);
    expect(finds('王小明', 'xiao ming'), isTrue);
    expect(finds('王小明', 'ming'), isTrue);
    expect(finds('王小明', 'wxm'), isTrue);
    expect(finds('王小明', 'zhang'), isFalse);
  });

  test('a homophone in characters finds the other', () {
    expect(finds('小明', '晓明'), isTrue);
    expect(finds('Xiao Ming', '晓明'), isTrue);
  });

  test('Latin names by sound and with a slip', () {
    expect(finds('Catherine Lee', 'kath'), isTrue);
    expect(finds('Steven Li', 'stephen'), isTrue);
    expect(finds('Jonathan', 'jonatan'), isTrue);
    expect(finds('Michael', 'micheal'), isTrue);
    expect(finds('Tom', 'tim'), isFalse);
    expect(finds('Steven Li', 'oliver'), isFalse);
  });

  test('pinyin is not folded by Latin sound rules', () {
    expect(finds('张伟', 'sang'), isFalse);
    expect(finds('张伟', 'zhangwei'), isTrue);
  });

  test('searchByName: as typed first, then by sound or pinyin', () {
    final names = ['Katherine', 'Catherine Wu', '王小明', 'Bob'];
    expect(searchByName(names, 'cath', (n) => n), [
      'Catherine Wu',
      'Katherine',
    ]);
    expect(searchByName(names, 'bo', (n) => n), ['Bob']);
    expect(searchByName(names, 'catherine', (n) => n), [
      'Catherine Wu',
      'Katherine',
    ]);
    expect(searchByName(names, 'xiaoming', (n) => n), ['王小明']);
    expect(searchByName(names, '', (n) => n), names);
  });
}
