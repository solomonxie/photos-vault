import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/viewer/words_markdown.dart';

void main() {
  test('blocks: headings, paragraphs, lists, quotes, code, rules, media', () {
    final blocks = parseMarkdown(
      '# Title\n'
      'line one\nline two\n\n'
      '- item\n'
      '2. second\n'
      '> quoted\n> more\n\n'
      '```\ncode\n```\n'
      '---\n'
      'before ![a](media/x/1.jpg) after\n'
      '![v](media/x/clip.mov)\n',
    );
    expect(blocks[0], isA<MdHeading>());
    expect((blocks[1] as MdParagraph).text, 'line one\nline two');
    expect((blocks[2] as MdParagraph).bullet, '•');
    expect((blocks[3] as MdParagraph).bullet, '2.');
    expect((blocks[4] as MdParagraph).quote, isTrue);
    expect((blocks[4] as MdParagraph).text, 'quoted\nmore');
    expect((blocks[5] as MdCode).text, 'code');
    expect(blocks[6], isA<MdRule>());
    expect((blocks[7] as MdParagraph).text, 'before');
    expect((blocks[8] as MdMedia).path, 'media/x/1.jpg');
    expect((blocks[8] as MdMedia).isVideo, isFalse);
    expect((blocks[9] as MdParagraph).text, 'after');
    expect((blocks[10] as MdMedia).isVideo, isTrue);
  });
}
