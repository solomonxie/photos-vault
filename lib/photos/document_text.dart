import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';

/// Why a document could not be read, so the screen can say something useful
/// rather than "unsupported".
enum DocumentProblem {
  /// A format with no reader here — `.doc`, `.pages`, `.rtf`.
  unsupportedFormat,

  /// A PDF that opened and had no text in it, which means it is a scan.
  scannedPdf,

  /// Opened, read, and empty.
  empty,
}

class DocumentResult {
  const DocumentResult.text(this.text) : problem = null;
  const DocumentResult.problem(this.problem) : text = null;

  final String? text;
  final DocumentProblem? problem;
}

/// Plain text out of a picked document.
///
/// Three readers, none of which adds a byte to the app. Text decodes directly;
/// `.docx` is a zip this app can already open, because `archive` is what the
/// backup snapshots use; and a PDF goes to PDFKit, which is part of iOS.
///
/// The pure-Dart PDF packages are two to three megabytes against a budget with
/// half a megabyte spare, so the platform channel is not a shortcut — it is
/// the only version of this that fits.
class DocumentReader {
  DocumentReader({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName);

  static const channelName = 'byo.photos/document';

  final MethodChannel _channel;

  /// [path] is needed for a PDF only: PDFKit opens a URL, and handing it bytes
  /// would mean writing them back out to be read again.
  Future<DocumentResult> read({
    required String name,
    required List<int> bytes,
    String? path,
  }) async {
    final lower = name.toLowerCase();
    if (lower.endsWith('.docx')) return _wrap(docxText(bytes));
    if (lower.endsWith('.pdf')) {
      if (path == null) {
        return const DocumentResult.problem(DocumentProblem.unsupportedFormat);
      }
      final text = await _pdfText(path);
      if (text == null) {
        return const DocumentResult.problem(DocumentProblem.unsupportedFormat);
      }
      // Opened fine and had nothing in it: a photographed or scanned page.
      // Worth its own message, because "unsupported" would send somebody off
      // to convert a file that is already the right format.
      if (text.trim().isEmpty) {
        return const DocumentResult.problem(DocumentProblem.scannedPdf);
      }
      return _wrap(text);
    }
    // Anything else, if it decodes. A `.md`, a `.csv`, a note — all text, and
    // none of them worth a list of extensions to allow.
    return _wrap(plainText(bytes));
  }

  static DocumentResult _wrap(String? text) => text == null
      ? const DocumentResult.problem(DocumentProblem.unsupportedFormat)
      : text.trim().isEmpty
      ? const DocumentResult.problem(DocumentProblem.empty)
      : DocumentResult.text(text);

  Future<String?> _pdfText(String path) async {
    try {
      return await _channel.invokeMethod<String>('pdfText', {'path': path});
    } catch (_) {
      // No channel: not iOS, or a test.
      return null;
    }
  }
}

/// `null` for bytes that are not text at all.
String? plainText(List<int> bytes) {
  try {
    return utf8.decode(bytes, allowMalformed: false);
  } catch (_) {
    return null;
  }
}

/// Text out of a `.docx`, which is a zip with the document in
/// `word/document.xml`.
///
/// Word splits one sentence across several `<w:t>` runs whenever formatting
/// changes mid-line, so the runs inside a paragraph are joined with nothing
/// between them — inserting spaces would break words that were never apart.
/// Paragraphs (`</w:p>`) become newlines, which is the only structure worth
/// keeping for something about to be read by a model.
///
/// `.doc`, the pre-2007 binary format, is a different and much nastier problem
/// and is not attempted.
String? docxText(List<int> bytes) {
  try {
    final archive = ZipDecoder().decodeBytes(bytes);
    final entry = archive.files
        .where((f) => f.isFile && f.name == 'word/document.xml')
        .firstOrNull;
    if (entry == null) return null;
    final xml = utf8.decode(entry.content as List<int>, allowMalformed: true);

    final paragraphs = <String>[];
    for (final block in xml.split('</w:p>')) {
      final runs = RegExp(
        r'<w:t\b[^>]*>(.*?)</w:t>',
        dotAll: true,
      ).allMatches(block);
      final line = runs.map((m) => _unescape(m.group(1) ?? '')).join();
      if (line.trim().isNotEmpty) paragraphs.add(line.trim());
    }
    return paragraphs.isEmpty ? null : paragraphs.join('\n');
  } catch (_) {
    // Not a zip, or not a Word document.
    return null;
  }
}

String _unescape(String value) => value
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&apos;', "'")
    // Last, or an escaped ampersand in the source becomes the start of
    // another entity.
    .replaceAll('&amp;', '&');
