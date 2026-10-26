import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

/// What a piece of writing is. Unknown kinds in a file read as [other].
enum WritingKind {
  blog,
  post,
  essay,
  fiction,
  paper,
  thesis,
  report,
  email,
  note,
  other;

  static WritingKind of(Object? name) =>
      values.where((k) => k.name == name).firstOrNull ?? other;
}

/// One piece someone wrote. [text] is Markdown; media it shows are
/// `![](media/…)` paths, relative to the words media folder.
class Writing {
  const Writing({
    required this.id,
    required this.kind,
    required this.title,
    required this.text,
    this.at,
    this.source = '',
    this.origin = '',
  });

  /// Stable across re-imports: a re-import replaces, never duplicates.
  final String id;
  final WritingKind kind;
  final String title;
  final String text;

  /// Local wall-clock time; null when nothing says when it was written.
  final DateTime? at;

  /// Where it was published or kept: weibo, sina blog, word, email…
  final String source;

  /// The file it came from on the Mac.
  final String origin;
}

/// A [Writing] as a list shows it: no full text.
class WritingSummary {
  const WritingSummary({
    required this.id,
    required this.kind,
    required this.title,
    required this.excerpt,
    required this.chars,
    required this.hasMedia,
    this.at,
    this.source = '',
  });

  final String id;
  final WritingKind kind;
  final String title;
  final String excerpt;
  final int chars;
  final bool hasMedia;
  final DateTime? at;
  final String source;
}

class WordsExport {
  const WordsExport(this.writings, this.skipped, this.mediaFiles);

  final List<Writing> writings;

  /// Lines that were not a writing: bad JSON, no id, no text.
  final int skipped;
  final int mediaFiles;

  Map<WritingKind, int> get counts {
    final counts = <WritingKind, int>{};
    for (final w in writings) {
      counts[w.kind] = (counts[w.kind] ?? 0) + 1;
    }
    return counts;
  }
}

const wordsListName = 'words.jsonl';
const wordsMediaPrefix = 'media/';

final _mediaRef = RegExp(r'!\[[^\]]*\]\(([^)\s]+)\)');

/// `![…](…)` and Markdown marks out of [text], for a list row.
String plainExcerpt(String text, {int max = 160}) {
  final plain = text
      .replaceAll(_mediaRef, '')
      .replaceAll(RegExp(r'\[([^\]]*)\]\([^)]*\)'), r'$1')
      .replaceAll(RegExp(r'^[#>\-*\s]+', multiLine: true), '')
      .replaceAll(RegExp(r'[*_`]'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return plain.length <= max ? plain : '${plain.substring(0, max)}…';
}

bool hasMediaRef(String text) => _mediaRef.hasMatch(text);

/// The list of a `.zip` (its `words.jsonl`) or a bare `.jsonl`, off the UI
/// isolate: a lifetime of writing is tens of megabytes of text.
Future<WordsExport> readWordsFile(String path) =>
    Isolate.run(() => readWordsFileHere(path));

Future<WordsExport> readWordsFileHere(String path) async {
  if (p.extension(path).toLowerCase() != '.zip') {
    return readWordsLines(await File(path).readAsString());
  }
  final input = InputFileStream(path);
  try {
    final archive = ZipDecoder().decodeStream(input);
    var media = 0;
    String? list;
    for (final entry in archive.files) {
      if (!entry.isFile) continue;
      final name = _entryName(entry.name);
      if (name == wordsListName) {
        list = utf8.decode(entry.readBytes() ?? const [], allowMalformed: true);
      } else if (name.startsWith(wordsMediaPrefix)) {
        media++;
      }
    }
    if (list == null) return const WordsExport([], 0, 0);
    final read = readWordsLines(list);
    return WordsExport(read.writings, read.skipped, media);
  } finally {
    await input.close();
  }
}

/// Copies the zip's `media/…` into [root], keeping the relative paths the
/// Markdown points at. Returns how many files were written.
Future<int> extractWordsMedia(String zipPath, String root) =>
    Isolate.run(() => extractWordsMediaHere(zipPath, root));

Future<int> extractWordsMediaHere(String zipPath, String root) async {
  if (p.extension(zipPath).toLowerCase() != '.zip') return 0;
  final input = InputFileStream(zipPath);
  var written = 0;
  try {
    final archive = ZipDecoder().decodeStream(input);
    for (final entry in archive.files) {
      if (!entry.isFile) continue;
      final name = _entryName(entry.name);
      if (!name.startsWith(wordsMediaPrefix) || name.contains('..')) continue;
      final target = File(p.join(root, name));
      await target.parent.create(recursive: true);
      final out = OutputFileStream(target.path);
      try {
        entry.writeContent(out);
      } finally {
        await out.close();
      }
      written++;
    }
  } finally {
    await input.close();
  }
  return written;
}

/// The name inside the zip, minus a top folder the zip was made from.
String _entryName(String name) {
  final parts = p.posix.split(name);
  final at = parts.indexWhere(
    (s) => s == wordsListName || s == wordsMediaPrefix.replaceAll('/', ''),
  );
  return at <= 0 ? name : p.posix.joinAll(parts.sublist(at));
}

WordsExport readWordsLines(String text) {
  final writings = <Writing>[];
  var skipped = 0;
  for (final line in LineSplitter.split(text)) {
    if (line.trim().isEmpty) continue;
    final w = _parse(line);
    if (w == null) {
      skipped++;
    } else {
      writings.add(w);
    }
  }
  return WordsExport(writings, skipped, 0);
}

Writing? _parse(String line) {
  final Object? row;
  try {
    row = jsonDecode(line);
  } on FormatException {
    return null;
  }
  if (row is! Map) return null;
  final id = row['id'];
  final text = row['text'];
  if (id is! String || id.isEmpty || text is! String) return null;
  final title = row['title'];
  final at = row['at'];
  return Writing(
    id: id,
    kind: WritingKind.of(row['kind']),
    title: title is String ? title.trim() : '',
    text: text,
    at: at is String ? DateTime.tryParse(at) : null,
    source: row['source'] is String ? row['source'] as String : '',
    origin: row['origin'] is String ? row['origin'] as String : '',
  );
}
