import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// One line of a chat export: a message to or from one person.
class ConversationMessage {
  const ConversationMessage({
    required this.chat,
    required this.source,
    required this.at,
    required this.fromMe,
    required this.sender,
    required this.text,
    required this.kind,
    required this.hash,
  });

  final String chat;

  /// qq, wechat, sms or whatsapp.
  final String source;

  /// Local wall-clock time, as the export wrote it.
  final DateTime at;
  final bool fromMe;
  final String sender;
  final String text;

  /// text, image, voice, file, system or other.
  final String kind;

  /// What makes a message the same one again on a re-import.
  final String hash;

  static String hashOf(String chat, DateTime at, bool fromMe, String text) =>
      sha256
          .convert(
            utf8.encode(
              '$chat|${at.toIso8601String()}|${fromMe ? 1 : 0}|$text',
            ),
          )
          .toString();
}

/// Everything one name in the export said and was told.
class ConversationPerson {
  ConversationPerson(this.name);

  final String name;
  final List<ConversationMessage> messages = [];
  DateTime? first;
  DateTime? last;

  void _add(ConversationMessage m) {
    messages.add(m);
    if (first == null || m.at.isBefore(first!)) first = m.at;
    if (last == null || m.at.isAfter(last!)) last = m.at;
  }
}

class ConversationExport {
  const ConversationExport(this.people, this.skipped);

  /// By name, most messages first.
  final List<ConversationPerson> people;

  /// Lines that were not a message: bad JSON, no person, no time.
  final int skipped;
}

/// Reads `.jsonl` files, and `.jsonl` files inside `.zip`s, off the UI
/// isolate: an export runs to tens of megabytes.
Future<ConversationExport> readConversationFiles(List<String> paths) =>
    Isolate.run(() => readConversationFilesHere(paths));

/// [readConversationFiles] on the calling isolate.
Future<ConversationExport> readConversationFilesHere(List<String> paths) async {
  final reader = _Reader();
  for (final path in paths) {
    if (p.extension(path).toLowerCase() == '.zip') {
      final input = InputFileStream(path);
      try {
        final archive = ZipDecoder().decodeStream(input);
        for (final entry in archive.files) {
          final parts = p.split(entry.name);
          if (!entry.isFile ||
              parts.contains('__MACOSX') ||
              parts.last.startsWith('.') ||
              p.extension(entry.name).toLowerCase() != '.jsonl') {
            continue;
          }
          final bytes = entry.readBytes();
          if (bytes == null) continue;
          LineSplitter.split(utf8.decode(bytes, allowMalformed: true))
              .forEach(reader.line);
        }
      } finally {
        await input.close();
      }
    } else {
      await File(path)
          .openRead()
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .forEach(reader.line);
    }
  }
  return reader.done();
}

/// [ConversationExport] of in-memory text, for tests.
ConversationExport readConversationLines(String text) {
  final reader = _Reader();
  LineSplitter.split(text).forEach(reader.line);
  return reader.done();
}

class _Reader {
  final _byName = <String, ConversationPerson>{};
  var _skipped = 0;

  void line(String line) {
    if (line.trim().isEmpty) return;
    final message = _parse(line);
    if (message == null) {
      _skipped++;
      return;
    }
    final (name, m) = message;
    // "alice" is "Alice", as matching to people here already is.
    _byName
        .putIfAbsent(name.toLowerCase(), () => ConversationPerson(name))
        ._add(m);
  }

  (String, ConversationMessage)? _parse(String line) {
    final Object? row;
    try {
      row = jsonDecode(line);
    } on FormatException {
      return null;
    }
    if (row is! Map) return null;
    final name = row['person'];
    final atText = row['at'];
    if (name is! String || name.trim().isEmpty || atText is! String) {
      return null;
    }
    final at = DateTime.tryParse(atText);
    if (at == null) return null;
    final chat = _string(row['chat']);
    final fromMe = row['from_me'] == true;
    final text = _string(row['text']);
    final source = _string(row['source']);
    final kind = _string(row['kind']);
    return (
      name.trim(),
      ConversationMessage(
        chat: chat,
        source: source.isNotEmpty ? source : chat.split(':').first,
        at: at,
        fromMe: fromMe,
        sender: _string(row['sender']),
        text: text,
        kind: kind.isEmpty ? 'text' : kind,
        hash: ConversationMessage.hashOf(chat, at, fromMe, text),
      ),
    );
  }

  static String _string(Object? v) => v is String ? v : '';

  ConversationExport done() => ConversationExport(
    _byName.values.toList()..sort((a, b) {
      final byCount = b.messages.length.compareTo(a.messages.length);
      return byCount != 0 ? byCount : a.name.compareTo(b.name);
    }),
    _skipped,
  );
}
