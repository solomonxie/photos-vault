import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart' show MissingPluginException;
import 'package:path/path.dart' as p;

import 'chat_voice.dart';

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
    this.thumb,
    this.voice,
    this.voiceMs,
  });

  final String chat;

  /// qq, wechat, sms, imessage, whatsapp, messenger or instagram.
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

  /// A small JPEG of the picture, video or file it carried, if the export
  /// had one: a few kilobytes, kept in the database with the message.
  final Uint8List? thumb;

  /// The voice clip's file name under `chats/voice` (see `chat_voice.dart`),
  /// and its length; null when the export carried no audio.
  final String? voice;
  final int? voiceMs;

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

  /// Whether any message is a voice message, or a picture.
  bool hasVoice = false;
  bool hasImages = false;

  void _add(ConversationMessage m) {
    messages.add(m);
    if (m.kind == 'voice') hasVoice = true;
    if (m.kind == 'image') hasImages = true;
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
/// isolate: an export runs to tens of megabytes. Voice clips are written
/// to [stageDir] as they're read, never held: they run to a hundred.
Future<ConversationExport> readConversationFiles(
  List<String> paths, {
  String? stageDir,
}) async {
  String? stage = stageDir;
  try {
    stage ??= (await chatVoice.staging()).path;
  } on MissingPluginException {
    // No path_provider (a test): clips are dropped.
  }
  return Isolate.run(() async {
    if (stage != null) {
      final dir = Directory(stage);
      if (dir.existsSync()) dir.deleteSync(recursive: true);
      dir.createSync(recursive: true);
    }
    return readConversationFilesHere(paths, stageDir: stage);
  });
}

/// [readConversationFiles] on the calling isolate.
Future<ConversationExport> readConversationFilesHere(
  List<String> paths, {
  String? stageDir,
}) async {
  final reader = _Reader(stageDir);
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
ConversationExport readConversationLines(String text, {String? stageDir}) {
  final reader = _Reader(stageDir);
  LineSplitter.split(text).forEach(reader.line);
  return reader.done();
}

class _Reader {
  _Reader(this._stageDir);

  /// Where clips go; null drops them.
  final String? _stageDir;
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
    // A day's grace for time zones; anything later is a bad stamp.
    if (at == null || at.isAfter(DateTime.now().add(const Duration(days: 1)))) {
      return null;
    }
    final chat = _string(row['chat']);
    final fromMe = row['from_me'] == true;
    final text = _string(row['text']);
    final source = _string(row['source']);
    final kind = _string(row['kind']);
    final hash = ConversationMessage.hashOf(chat, at, fromMe, text);
    final stage = _stageDir;
    final clip = stage == null ? null : _bytes(row['voice']);
    String? voice;
    if (stage != null && clip != null) {
      voice = ChatVoice.fileNameOf(hash);
      // Off the UI isolate: this whole reader runs in [Isolate.run].
      File(p.join(stage, voice)).writeAsBytesSync(clip);
    }
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
        hash: hash,
        thumb: _bytes(row['thumb']),
        voice: voice,
        voiceMs: voice == null || row['voice_ms'] is! int
            ? null
            : row['voice_ms'] as int,
      ),
    );
  }

  static String _string(Object? v) => v is String ? v : '';

  /// Base64, with or without a `data:` prefix; anything else is none.
  static Uint8List? _bytes(Object? v) {
    if (v is! String || v.isEmpty) return null;
    try {
      return base64Decode(v.substring(v.indexOf(',') + 1));
    } on FormatException {
      return null;
    }
  }

  ConversationExport done() => ConversationExport(
    _byName.values.toList()..sort((a, b) {
      final byCount = b.messages.length.compareTo(a.messages.length);
      return byCount != 0 ? byCount : a.name.compareTo(b.name);
    }),
    _skipped,
  );
}
