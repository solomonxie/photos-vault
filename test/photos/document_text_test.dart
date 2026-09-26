import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/photos/document_text.dart';

/// A .docx is a zip with the document in `word/document.xml`.
List<int> _docx(String documentXml, {String entry = 'word/document.xml'}) {
  final archive = Archive()..addFile(ArchiveFile.string(entry, documentXml));
  return ZipEncoder().encodeBytes(archive);
}

const _twoParagraphs = '''
<?xml version="1.0"?>
<w:document xmlns:w="x"><w:body>
<w:p><w:r><w:t>Mia Chen</w:t></w:r></w:p>
<w:p><w:r><w:t>Engineer at </w:t></w:r><w:r><w:t>Acme Ltd</w:t></w:r></w:p>
</w:body></w:document>
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('docx', () {
    test('paragraphs become lines', () {
      expect(docxText(_docx(_twoParagraphs)), 'Mia Chen\nEngineer at Acme Ltd');
    });

    test('runs inside a paragraph join with nothing between them', () {
      // Word splits a sentence at every formatting change. Putting a space
      // between runs would break words that were never apart.
      final text = docxText(
        _docx(
          '<w:p><w:r><w:t>Engin</w:t></w:r><w:r><w:t>eer</w:t></w:r></w:p>',
        ),
      );

      expect(text, 'Engineer');
    });

    test('entities come back as themselves', () {
      final text = docxText(
        _docx('<w:p><w:r><w:t>Smith &amp; Jones &lt;x&gt;</w:t></w:r></w:p>'),
      );

      expect(text, 'Smith & Jones <x>');
    });

    test('an attributed run is still a run', () {
      final text = docxText(
        _docx('<w:p><w:r><w:t xml:space="preserve">kept </w:t></w:r></w:p>'),
      );

      expect(text, 'kept');
    });

    test('a zip that is not a Word file is nothing, not a crash', () {
      expect(docxText(_docx('<w:p/>', entry: 'other.xml')), isNull);
      expect(docxText(utf8.encode('not a zip at all')), isNull);
      expect(docxText(const []), isNull);
    });
  });

  group('dispatch', () {
    test('plain text is read as it is', () async {
      final read = await DocumentReader().read(
        name: 'cv.txt',
        bytes: utf8.encode('Mia worked at Acme.'),
      );

      expect(read.text, 'Mia worked at Acme.');
    });

    test('a .md is text too, without a list of allowed extensions', () async {
      final read = await DocumentReader().read(
        name: 'notes.md',
        bytes: utf8.encode('# Mia'),
      );

      expect(read.text, '# Mia');
    });

    test('a .docx goes through the zip reader', () async {
      final read = await DocumentReader().read(
        name: 'cv.docx',
        bytes: _docx(_twoParagraphs),
      );

      expect(read.text, contains('Acme Ltd'));
    });

    test('an empty file is empty rather than unsupported', () async {
      final read = await DocumentReader().read(
        name: 'cv.txt',
        bytes: utf8.encode('   '),
      );

      expect(read.problem, DocumentProblem.empty);
    });

    test('a format with no reader says so', () async {
      final read = await DocumentReader().read(
        name: 'cv.rtf',
        bytes: [0x7B, 0x5C, 0x72, 0x74, 0x66, 0x80, 0xFF],
      );

      expect(read.problem, DocumentProblem.unsupportedFormat);
    });
  });

  group('pdf', () {
    late List<MethodCall> calls;

    setUp(() => calls = []);

    DocumentReader readerReturning(String? text) {
      const channel = MethodChannel(DocumentReader.channelName);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return text;
          });
      return DocumentReader(channel: channel);
    }

    test('the text PDFKit found is the text', () async {
      final read = await readerReturning('Mia Chen\nEngineer')
          .read(name: 'cv.pdf', bytes: const [], path: '/tmp/cv.pdf');

      expect(read.text, contains('Engineer'));
      expect(calls.single.method, 'pdfText');
      expect(calls.single.arguments, {'path': '/tmp/cv.pdf'});
    });

    test('a PDF with no text in it is a scan, and says so', () async {
      // Opens fine, has nothing in it. "Unsupported" would send somebody off
      // to convert a file that is already the right format.
      final read = await readerReturning('  ')
          .read(name: 'cv.pdf', bytes: const [], path: '/tmp/cv.pdf');

      expect(read.problem, DocumentProblem.scannedPdf);
    });

    test('a PDF PDFKit will not open is unsupported', () async {
      final read = await readerReturning(null)
          .read(name: 'cv.pdf', bytes: const [], path: '/tmp/cv.pdf');

      expect(read.problem, DocumentProblem.unsupportedFormat);
    });

    test('no path means no call, since PDFKit opens a URL', () async {
      final read = await readerReturning('x')
          .read(name: 'cv.pdf', bytes: const []);

      expect(read.problem, DocumentProblem.unsupportedFormat);
      expect(calls, isEmpty);
    });
  });
}
